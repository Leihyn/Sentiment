// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Handler - The Heart of Invariant Testing
 * @author Learning invariants with Sentiment
 * @notice This contract wraps all state-changing operations with proper bounds
 *
 * ┌─────────────────────────────────────────────────────────────────┐
 * │                    HOW INVARIANT TESTING WORKS                  │
 * ├─────────────────────────────────────────────────────────────────┤
 * │  1. Foundry's fuzzer calls Handler functions randomly           │
 * │  2. Each function uses `bound()` to constrain random inputs     │
 * │  3. After each call sequence, invariant_* functions are checked │
 * │  4. If any invariant fails, Foundry reports the call sequence   │
 * └─────────────────────────────────────────────────────────────────┘
 *
 * WHY USE A HANDLER?
 * - Bounds random inputs to valid ranges (prevents revert spam)
 * - Tracks "ghost variables" for additional invariant checking
 * - Simulates realistic user behavior patterns
 * - Allows complex multi-step operations
 */

import {Test} from "forge-std/Test.sol";
import {SentimentFeeHook} from "../../src/SentimentFeeHook.sol";

contract Handler is Test {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The hook contract we're testing
    SentimentFeeHook public hook;

    /// @notice Authorized keeper address for sentiment updates
    address public keeper;

    /// @notice Owner address for admin operations
    address public hookOwner;

    /*//////////////////////////////////////////////////////////////
                        GHOST VARIABLES (KEY CONCEPT!)
    //////////////////////////////////////////////////////////////*/

    /**
     * Ghost variables track information that the contract doesn't store
     * but that we need to verify invariants. They're called "ghost" because
     * they exist only in our test, not in the actual contract.
     */

    /// @notice Number of successful sentiment updates
    uint256 public ghost_updateCount;

    /// @notice Stores the previous sentiment score before each update
    /// @dev Used to verify EMA smoothing invariant
    uint8 public ghost_previousScore;

    /// @notice Tracks if an update just occurred (for EMA checking)
    bool public ghost_justUpdated;

    /// @notice The raw score that was just submitted (for EMA verification)
    uint8 public ghost_lastRawScore;

    /// @notice Sum of all time warps (to track total time advanced)
    uint256 public ghost_totalTimeAdvanced;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(SentimentFeeHook _hook, address _keeper, address _hookOwner) {
        hook = _hook;
        keeper = _keeper;
        hookOwner = _hookOwner;
    }

    /*//////////////////////////////////////////////////////////////
                    HANDLER FUNCTIONS (FUZZED ACTIONS)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates sentiment with a bounded score
     * @param rawScore Random value that gets bounded to [0, 100]
     *
     * LEARNING NOTE: The `bound()` function is crucial!
     * Without it, most calls would revert with InvalidInput_SentimentOutOfRange
     * and we'd waste fuzzing cycles on invalid inputs.
     */
    function updateSentiment(uint256 rawScore) external {
        // Bound the random input to valid range [0, 100]
        uint8 boundedScore = uint8(bound(rawScore, 0, 100));

        // Store ghost state BEFORE the update
        ghost_previousScore = hook.sentimentScore();
        ghost_lastRawScore = boundedScore;

        // Simulate keeper calling the function
        vm.prank(keeper);
        hook.updateSentiment(boundedScore);

        // Update ghost variables AFTER successful call
        ghost_updateCount++;
        ghost_justUpdated = true;
    }

    /**
     * @notice Advances time to test staleness behavior
     * @param timeJump Random seconds to advance, bounded to reasonable range
     *
     * LEARNING NOTE: Time manipulation is crucial for testing:
     * - Staleness thresholds
     * - Time-dependent behavior
     * - Edge cases around threshold boundaries
     */
    function warpTime(uint256 timeJump) external {
        // Bound to [0, 48 hours] - covers staleness threshold (6 hours) well
        uint256 boundedJump = bound(timeJump, 0, 48 hours);

        vm.warp(block.timestamp + boundedJump);

        ghost_totalTimeAdvanced += boundedJump;
        ghost_justUpdated = false; // Reset after time passes
    }

    /**
     * @notice Simulates multiple rapid updates (stress test)
     * @param rawScore1 First sentiment update
     * @param rawScore2 Second sentiment update
     *
     * LEARNING NOTE: Multi-action handlers test complex sequences
     * that might expose bugs not visible in single operations.
     */
    function rapidUpdates(uint256 rawScore1, uint256 rawScore2) external {
        uint8 score1 = uint8(bound(rawScore1, 0, 100));
        uint8 score2 = uint8(bound(rawScore2, 0, 100));

        ghost_previousScore = hook.sentimentScore();

        vm.startPrank(keeper);
        hook.updateSentiment(score1);
        ghost_previousScore = hook.sentimentScore(); // Update for second call
        ghost_lastRawScore = score2;
        hook.updateSentiment(score2);
        vm.stopPrank();

        ghost_updateCount += 2;
        ghost_justUpdated = true;
    }

    /**
     * @notice Changes the EMA alpha (owner action)
     * @param newAlpha Random alpha value bounded to valid range
     *
     * LEARNING NOTE: Testing admin functions ensures invariants
     * hold even when configuration changes.
     */
    function setEmaAlpha(uint256 newAlpha) external {
        // Alpha should be 0-100 (it's a percentage)
        uint8 boundedAlpha = uint8(bound(newAlpha, 0, 100));

        vm.prank(hookOwner);
        hook.setEmaAlpha(boundedAlpha);

        ghost_justUpdated = false;
    }

    /**
     * @notice Adds a new keeper (owner action)
     * @param newKeeper Random address for new keeper
     */
    function addKeeper(address newKeeper) external {
        // Skip zero address and existing keeper to avoid reverts
        vm.assume(newKeeper != address(0));
        vm.assume(newKeeper != keeper);

        vm.prank(hookOwner);
        hook.setKeeperAuthorization(newKeeper, true);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Resets the "just updated" flag
     * @dev Called after invariant checks to prepare for next sequence
     */
    function resetGhostState() external {
        ghost_justUpdated = false;
    }

    /**
     * @notice Returns absolute difference between two values
     */
    function absDiff(uint256 a, uint256 b) external pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
