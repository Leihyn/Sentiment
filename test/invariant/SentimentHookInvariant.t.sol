// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title SentimentHookInvariant - Invariant Testing Deep Dive
 * @author Learning invariants with Sentiment
 * @notice This test suite defines properties that must ALWAYS hold
 *
 * ╔═══════════════════════════════════════════════════════════════════╗
 * ║                  INVARIANT TESTING EXPLAINED                      ║
 * ╠═══════════════════════════════════════════════════════════════════╣
 * ║                                                                   ║
 * ║  Unit Test:      "When I call X with Y, I get Z"                  ║
 * ║  Fuzz Test:      "When I call X with random Y, I still get Z"     ║
 * ║  Invariant Test: "After calling ANYTHING, property P still holds" ║
 * ║                                                                   ║
 * ╚═══════════════════════════════════════════════════════════════════╝
 *
 * KEY CONCEPTS:
 *
 * 1. TARGET CONTRACTS
 *    - `targetContract(address)` tells Foundry which contracts to call
 *    - We target the Handler, NOT the hook directly
 *    - Handler wraps calls with proper bounds and pranks
 *
 * 2. INVARIANT FUNCTIONS
 *    - Functions prefixed with `invariant_` are checked after EVERY call
 *    - If any invariant fails, Foundry shows the exact call sequence
 *    - This finds bugs you'd never think to test manually
 *
 * 3. GHOST VARIABLES
 *    - Extra tracking in Handler that contract doesn't store
 *    - Lets us verify properties like "EMA moved in right direction"
 *
 * 4. CONFIGURATION (foundry.toml)
 *    - `runs`: How many random call sequences to try
 *    - `depth`: How many calls per sequence
 *    - `fail_on_revert`: Whether unexpected reverts fail the test
 */

import {Test, console2} from "forge-std/Test.sol";
import {SentimentFeeHook} from "../../src/SentimentFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../utils/HookMiner.sol";
import {Handler} from "./Handler.t.sol";

contract SentimentHookInvariant is Test {
    /*//////////////////////////////////////////////////////////////
                            TEST STATE
    //////////////////////////////////////////////////////////////*/

    SentimentFeeHook public hook;
    Handler public handler;
    PoolManager public poolManager;

    address public owner = address(this);
    address public keeper = address(0xBEEF);

    // Fee constants (matching contract)
    uint24 constant MIN_FEE = 2500;
    uint24 constant MAX_FEE = 4400;
    uint24 constant DEFAULT_FEE = 3000;

    // Sentiment constants
    uint8 constant MAX_SENTIMENT = 100;
    uint8 constant EMA_ALPHA = 30;
    uint256 constant STALENESS_THRESHOLD = 6 hours;

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Deploy PoolManager
        poolManager = new PoolManager(address(0));

        // Mine valid hook address (Uniswap v4 requirement)
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(SentimentFeeHook).creationCode,
            constructorArgs
        );

        // Deploy hook with mined salt
        hook = new SentimentFeeHook{salt: salt}(
            IPoolManager(address(poolManager)),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        // Deploy handler (wraps hook with bounded operations)
        handler = new Handler(hook, keeper, owner);

        // ═══════════════════════════════════════════════════════════
        // CRITICAL: Tell Foundry to ONLY call the Handler
        // ═══════════════════════════════════════════════════════════
        // Without this, Foundry would call hook functions directly
        // which would fail due to access control (not keeper)
        targetContract(address(handler));

        // Exclude setup artifacts from being called
        excludeContract(address(poolManager));
        excludeContract(address(hook));
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT 1: FEE BOUNDS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fee must ALWAYS be within [MIN_FEE, MAX_FEE] or DEFAULT_FEE
     *
     * WHY THIS MATTERS:
     * - Fees outside bounds could break LP expectations
     * - Too high = users avoid the pool
     * - Too low = LPs lose money to arbitrage
     *
     * WHAT WE'RE TESTING:
     * - After any sequence of updates and time warps
     * - getCurrentFee() returns a valid fee
     */
    function invariant_feeWithinBounds() public view {
        uint24 fee = hook.getCurrentFee();

        // Fee is either in dynamic range OR the default (when stale)
        bool validDynamic = fee >= MIN_FEE && fee <= MAX_FEE;
        bool isDefault = fee == DEFAULT_FEE;

        assertTrue(
            validDynamic || isDefault,
            string.concat(
                "Fee out of bounds: ",
                vm.toString(fee),
                " (expected ",
                vm.toString(MIN_FEE),
                "-",
                vm.toString(MAX_FEE),
                " or ",
                vm.toString(DEFAULT_FEE),
                ")"
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT 2: SENTIMENT BOUNDS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sentiment score must ALWAYS be in [0, 100]
     *
     * WHY THIS MATTERS:
     * - Score > 100 would cause fee calculation overflow/unexpected values
     * - Ensures fee interpolation math works correctly
     *
     * WHAT WE'RE TESTING:
     * - EMA smoothing never produces out-of-bounds values
     * - updateSentiment never stores invalid scores
     */
    function invariant_sentimentBounded() public view {
        uint8 score = hook.sentimentScore();
        assertLe(score, MAX_SENTIMENT, "Sentiment exceeds 100");
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT 3: EMA SMOOTHING BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice EMA smoothing prevents extreme jumps per single update
     *
     * FORMULA: newEMA = (newScore * alpha + oldEMA * (100 - alpha)) / 100
     *
     * With alpha = 30:
     * - New value contributes only 30%
     * - Historical value contributes 70%
     * - Max change = 30% of the difference between old and new
     *
     * EXAMPLE:
     * - Old score: 50, New input: 100
     * - Max influence: (100 - 50) * 30 / 100 = 15
     * - New EMA should be around 50 + 15 = 65, not 100
     *
     * WHY THIS MATTERS:
     * - Prevents single malicious update from spiking fees
     * - Provides smooth fee transitions
     */
    function invariant_emaSmoothingLimitsJumps() public view {
        // Only check when we just did an update
        if (!handler.ghost_justUpdated()) return;

        uint8 previousScore = handler.ghost_previousScore();
        uint8 currentScore = hook.sentimentScore();
        uint8 emaAlpha = hook.emaAlpha();

        // Calculate maximum allowed change based on EMA formula
        // If rawScore was X and previous was P:
        // new = (X * alpha + P * (100 - alpha)) / 100
        // change = new - P = (X * alpha + P * (100 - alpha)) / 100 - P
        //        = (X * alpha + P * 100 - P * alpha - P * 100) / 100
        //        = (X - P) * alpha / 100
        //
        // So max change = |X - P| * alpha / 100

        uint8 rawScore = handler.ghost_lastRawScore();
        uint256 maxChange;
        if (rawScore > previousScore) {
            maxChange = uint256(rawScore - previousScore) * emaAlpha / 100;
        } else {
            maxChange = uint256(previousScore - rawScore) * emaAlpha / 100;
        }

        uint256 actualChange = currentScore > previousScore
            ? currentScore - previousScore
            : previousScore - currentScore;

        // Allow +1 tolerance for integer division rounding
        assertLe(
            actualChange,
            maxChange + 1,
            "EMA change exceeded maximum allowed by alpha"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT 4: EMA DIRECTIONAL CORRECTNESS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice EMA must move TOWARD the input value, never away
     *
     * If input > previous, new score must be >= previous
     * If input < previous, new score must be <= previous
     * If input == previous, new score must == previous
     *
     * WHY THIS MATTERS:
     * - Ensures EMA behaves as expected mathematically
     * - Catches sign errors or overflow bugs in smoothing
     */
    function invariant_emaMovesTowardInput() public view {
        if (!handler.ghost_justUpdated()) return;

        uint8 previousScore = handler.ghost_previousScore();
        uint8 currentScore = hook.sentimentScore();
        uint8 rawScore = handler.ghost_lastRawScore();

        if (rawScore > previousScore) {
            assertGe(
                currentScore,
                previousScore,
                "EMA moved away from input (should increase)"
            );
            assertLe(
                currentScore,
                rawScore,
                "EMA overshot input value"
            );
        } else if (rawScore < previousScore) {
            assertLe(
                currentScore,
                previousScore,
                "EMA moved away from input (should decrease)"
            );
            assertGe(
                currentScore,
                rawScore,
                "EMA undershot input value"
            );
        } else {
            // rawScore == previousScore => should stay same
            assertEq(
                currentScore,
                previousScore,
                "EMA changed when input matched current"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT 5: STALENESS LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice When stale, fee must be DEFAULT_FEE
     *
     * WHY THIS MATTERS:
     * - Stale data could be manipulated or outdated
     * - Default fee provides safe fallback
     * - Users get predictable behavior when keeper is down
     */
    function invariant_staleDataUsesDefaultFee() public view {
        if (hook.isStale()) {
            uint24 fee = hook.getCurrentFee();
            assertEq(
                fee,
                DEFAULT_FEE,
                "Stale data should use default fee"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT 6: TIME MONOTONICITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice lastUpdateTimestamp should never exceed current block.timestamp
     *
     * WHY THIS MATTERS:
     * - Future timestamps would break staleness logic
     * - Ensures time tracking is sane
     */
    function invariant_timestampNotInFuture() public view {
        assertLe(
            hook.lastUpdateTimestamp(),
            block.timestamp,
            "Last update timestamp is in the future"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT 7: FEE FORMULA CORRECTNESS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fee must match the linear interpolation formula
     *
     * FORMULA: fee = MIN_FEE + (sentiment * FEE_RANGE / 100)
     *
     * WHY THIS MATTERS:
     * - Ensures fee calculation isn't corrupted
     * - Catches arithmetic bugs
     */
    function invariant_feeMatchesFormula() public view {
        // Skip if stale (uses default fee)
        if (hook.isStale()) return;

        uint8 sentiment = hook.sentimentScore();
        uint24 expectedFee = MIN_FEE + uint24(uint256(sentiment) * (MAX_FEE - MIN_FEE) / 100);
        uint24 actualFee = hook.getCurrentFee();

        assertEq(
            actualFee,
            expectedFee,
            "Fee doesn't match expected formula"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT 8: KEEPER AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Primary keeper must always be authorized
     *
     * WHY THIS MATTERS:
     * - Primary keeper is used in authorization check
     * - If mapping gets out of sync, updates could fail
     */
    function invariant_primaryKeeperIsAuthorized() public view {
        address primary = hook.primaryKeeper();
        assertTrue(
            hook.isKeeper(primary),
            "Primary keeper not in isKeeper mapping"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT 9: EMA ALPHA BOUNDS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice EMA alpha should be <= 100 (it's a percentage)
     *
     * WHY THIS MATTERS:
     * - Alpha > 100 would cause unexpected EMA behavior
     * - Could potentially cause overflow in smoothing calc
     */
    function invariant_emaAlphaBounded() public view {
        assertLe(
            hook.emaAlpha(),
            100,
            "EMA alpha exceeds 100%"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT 10: STALENESS THRESHOLD
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Staleness threshold must be >= minimum (1 hour)
     *
     * WHY THIS MATTERS:
     * - Too short threshold = excessive default fee usage
     * - Contract enforces minimum in setter
     */
    function invariant_stalenessThresholdValid() public view {
        assertGe(
            hook.stalenessThreshold(),
            1 hours,
            "Staleness threshold below minimum"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    DEBUG HELPER: CALL SUMMARY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Logs statistics after invariant run (not an invariant itself)
     * @dev Run with -vvv to see this output
     */
    function invariant_callSummary() public view {
        console2.log("\n=== Invariant Test Summary ===");
        console2.log("Total sentiment updates:", handler.ghost_updateCount());
        console2.log("Total time advanced:", handler.ghost_totalTimeAdvanced() / 1 hours, "hours");
        console2.log("Current sentiment score:", hook.sentimentScore());
        console2.log("Current fee:", hook.getCurrentFee());
        console2.log("Is stale:", hook.isStale());
        console2.log("===============================\n");
    }
}
