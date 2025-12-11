// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title SentimentFeeHook Unit Tests
 * @notice Comprehensive test suite for the Sentiment Fee Hook contract
 * @dev Tests cover: constructor validation, fee calculation, EMA smoothing,
 *      staleness detection, access control, multi-keeper support, and events
 *
 * Test Categories:
 * - Constructor Tests: Validates initialization and input validation
 * - Fee Calculation Tests: Verifies dynamic fee computation at various sentiment levels
 * - EMA Smoothing Tests: Ensures anti-manipulation smoothing works correctly
 * - Staleness Tests: Validates data freshness checks and default fee fallback
 * - Access Control Tests: Confirms proper authorization for all admin functions
 * - Multi-Keeper Tests: Tests decentralized keeper authorization system
 * - Event Tests: Verifies all events emit with correct parameters
 * - Hook Permission Tests: Confirms correct Uniswap v4 hook flags
 */

import {Test} from "forge-std/Test.sol";
import {SentimentFeeHook} from "../src/SentimentFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract SentimentFeeHookTest is Test {
    /*//////////////////////////////////////////////////////////////
                               TEST STATE
    //////////////////////////////////////////////////////////////*/

    SentimentFeeHook public hook;
    PoolManager public poolManager;

    /// @dev Test addresses with memorable values for debugging
    address public owner = address(this);
    address public keeper = address(0xBEEF);
    address public user = address(0xCAFE);

    /*//////////////////////////////////////////////////////////////
                            TEST CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice EMA smoothing factor: 30% weight to new values, 70% to historical
    uint8 constant EMA_ALPHA = 30;

    /// @notice Data considered stale after 6 hours without updates
    uint256 constant STALENESS_THRESHOLD = 6 hours;

    /// @notice Fee bounds matching contract constants (in basis points)
    uint24 constant MIN_FEE = 2500;   // 0.25% during extreme fear
    uint24 constant MAX_FEE = 4400;   // 0.44% during extreme greed
    uint24 constant DEFAULT_FEE = 3000; // 0.30% when data is stale
    uint24 constant FEE_RANGE = MAX_FEE - MIN_FEE; // 1900 bps range

    /*//////////////////////////////////////////////////////////////
                              TEST SETUP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the hook contract with a valid address for Uniswap v4
     * @dev Hook addresses must have specific bit flags set. We use CREATE2
     *      salt mining to find an address with the correct beforeSwap flag.
     */
    function setUp() public {
        // Step 1: Deploy Uniswap v4 PoolManager (required dependency)
        poolManager = new PoolManager(address(0));

        // Step 2: Mine a valid hook address with BEFORE_SWAP_FLAG set
        // Uniswap v4 derives hook permissions from the hook's address bits
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(SentimentFeeHook).creationCode,
            constructorArgs
        );

        // Step 3: Deploy hook using CREATE2 with the mined salt
        hook = new SentimentFeeHook{salt: salt}(
            IPoolManager(address(poolManager)),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        // Step 4: Verify deployment succeeded at expected address
        assertEq(address(hook), hookAddress, "Hook address mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsInitialValues() public view {
        assertEq(hook.keeper(), keeper);
        assertEq(hook.owner(), owner);
        assertEq(hook.emaAlpha(), EMA_ALPHA);
        assertEq(hook.stalenessThreshold(), STALENESS_THRESHOLD);
        assertEq(hook.sentimentScore(), 50); // Neutral starting point
    }

    function test_constructor_revertsOnZeroKeeper() public {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            address(0),
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(SentimentFeeHook).creationCode,
            constructorArgs
        );

        vm.expectRevert(SentimentFeeHook.InvalidInput_ZeroAddress.selector);
        new SentimentFeeHook{salt: salt}(
            IPoolManager(address(poolManager)),
            address(0),
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );
    }

    function test_constructor_revertsOnLowStaleness() public {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            keeper,
            EMA_ALPHA,
            30 minutes // Below 1 hour minimum
        );

        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(SentimentFeeHook).creationCode,
            constructorArgs
        );

        vm.expectRevert(SentimentFeeHook.InvalidInput_StalenessThresholdTooLow.selector);
        new SentimentFeeHook{salt: salt}(
            IPoolManager(address(poolManager)),
            keeper,
            EMA_ALPHA,
            30 minutes
        );
    }

    /*//////////////////////////////////////////////////////////////
                         FEE CALCULATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getCurrentFee_atNeutral() public view {
        // Starting sentiment is 50 (neutral)
        // fee = 2500 + (50 * 1900 / 100) = 2500 + 950 = 3450
        uint24 expectedFee = MIN_FEE + uint24((50 * FEE_RANGE) / 100);
        assertEq(hook.getCurrentFee(), expectedFee);
        assertEq(expectedFee, 3450);
    }

    function test_getCurrentFee_atExtremeFear() public {
        vm.prank(keeper);
        hook.updateSentiment(0);

        // With EMA: newScore = (0 * 30 + 50 * 70) / 100 = 35
        // fee = 2500 + (35 * 1900 / 100) = 2500 + 665 = 3165
        uint8 expectedSentiment = 35; // (0 * 30 + 50 * 70) / 100
        uint24 expectedFee = MIN_FEE + uint24((uint256(expectedSentiment) * FEE_RANGE) / 100);

        assertEq(hook.sentimentScore(), expectedSentiment);
        assertEq(hook.getCurrentFee(), expectedFee);
    }

    function test_getCurrentFee_atExtremeGreed() public {
        vm.prank(keeper);
        hook.updateSentiment(100);

        // With EMA: newScore = (100 * 30 + 50 * 70) / 100 = 65
        // fee = 2500 + (65 * 1900 / 100) = 2500 + 1235 = 3735
        uint8 expectedSentiment = 65; // (100 * 30 + 50 * 70) / 100
        uint24 expectedFee = MIN_FEE + uint24((uint256(expectedSentiment) * FEE_RANGE) / 100);

        assertEq(hook.sentimentScore(), expectedSentiment);
        assertEq(hook.getCurrentFee(), expectedFee);
    }

    function test_getCurrentFee_returnsDefaultWhenStale() public {
        // Fast forward past staleness threshold
        vm.warp(block.timestamp + STALENESS_THRESHOLD + 1);

        assertEq(hook.getCurrentFee(), DEFAULT_FEE);
        assertTrue(hook.isStale());
    }

    function testFuzz_getCurrentFee_withinBounds(uint8 sentiment) public {
        vm.assume(sentiment <= 100);

        vm.prank(keeper);
        hook.updateSentiment(sentiment);

        uint24 fee = hook.getCurrentFee();
        assertGe(fee, MIN_FEE);
        assertLe(fee, MAX_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                           EMA SMOOTHING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ema_smoothingWorks() public {
        // Starting at 50
        // Update to 100: EMA = (100 * 30 + 50 * 70) / 100 = 65
        vm.prank(keeper);
        hook.updateSentiment(100);
        assertEq(hook.sentimentScore(), 65);

        // Update to 100 again: EMA = (100 * 30 + 65 * 70) / 100 = 75
        vm.prank(keeper);
        hook.updateSentiment(100);
        assertEq(hook.sentimentScore(), 75);

        // Update to 100 again: EMA = (100 * 30 + 75 * 70) / 100 = 82
        vm.prank(keeper);
        hook.updateSentiment(100);
        assertEq(hook.sentimentScore(), 82);
    }

    function test_ema_convergesToTarget() public {
        // Repeatedly push 100, should converge towards 100
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(keeper);
            hook.updateSentiment(100);
        }

        // After many iterations, should be very close to 100
        // With alpha=30%, converges slowly: ~97 after 20 iterations
        assertGe(hook.sentimentScore(), 97);
    }

    function test_ema_resistsSuddenChanges() public {
        // Start at 50, push 0 (extreme fear)
        vm.prank(keeper);
        hook.updateSentiment(0);

        // Should not drop dramatically due to EMA
        assertGe(hook.sentimentScore(), 30); // At least 30 (35 expected)
    }

    /*//////////////////////////////////////////////////////////////
                           STALENESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_isStale_falseWhenFresh() public view {
        assertFalse(hook.isStale());
    }

    function test_isStale_trueAfterThreshold() public {
        vm.warp(block.timestamp + STALENESS_THRESHOLD + 1);
        assertTrue(hook.isStale());
    }

    function test_timeUntilStale_returnsCorrectValue() public view {
        uint256 timeLeft = hook.timeUntilStale();
        assertEq(timeLeft, STALENESS_THRESHOLD);
    }

    function test_timeUntilStale_returnsZeroWhenStale() public {
        vm.warp(block.timestamp + STALENESS_THRESHOLD + 1);
        assertEq(hook.timeUntilStale(), 0);
    }

    function test_staleness_resetsOnUpdate() public {
        // Fast forward to near staleness
        vm.warp(block.timestamp + STALENESS_THRESHOLD - 1 hours);

        // Update sentiment
        vm.prank(keeper);
        hook.updateSentiment(60);

        // Should no longer be near stale
        assertEq(hook.timeUntilStale(), STALENESS_THRESHOLD);
        assertFalse(hook.isStale());
    }

    /*//////////////////////////////////////////////////////////////
                         ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_updateSentiment_onlyKeeper() public {
        vm.prank(user);
        vm.expectRevert(SentimentFeeHook.Unauthorized_NotKeeper.selector);
        hook.updateSentiment(75);
    }

    function test_updateSentiment_revertsOnInvalidScore() public {
        vm.prank(keeper);
        vm.expectRevert(SentimentFeeHook.InvalidInput_SentimentOutOfRange.selector);
        hook.updateSentiment(101);
    }

    function test_setKeeper_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(SentimentFeeHook.Unauthorized_NotOwner.selector);
        hook.setKeeper(user);
    }

    function test_setKeeper_updatesKeeper() public {
        address newKeeper = address(0xDEAD);
        hook.setKeeper(newKeeper);
        assertEq(hook.keeper(), newKeeper);
    }

    function test_setKeeper_revertsOnZeroAddress() public {
        vm.expectRevert(SentimentFeeHook.InvalidInput_ZeroAddress.selector);
        hook.setKeeper(address(0));
    }

    function test_setStalenessThreshold_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(SentimentFeeHook.Unauthorized_NotOwner.selector);
        hook.setStalenessThreshold(12 hours);
    }

    function test_setStalenessThreshold_updates() public {
        hook.setStalenessThreshold(12 hours);
        assertEq(hook.stalenessThreshold(), 12 hours);
    }

    function test_setStalenessThreshold_revertsOnLowValue() public {
        vm.expectRevert(SentimentFeeHook.InvalidInput_StalenessThresholdTooLow.selector);
        hook.setStalenessThreshold(30 minutes);
    }

    function test_setEmaAlpha_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(SentimentFeeHook.Unauthorized_NotOwner.selector);
        hook.setEmaAlpha(50);
    }

    function test_setEmaAlpha_updates() public {
        hook.setEmaAlpha(50);
        assertEq(hook.emaAlpha(), 50);
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(SentimentFeeHook.Unauthorized_NotOwner.selector);
        hook.transferOwnership(user);
    }

    function test_transferOwnership_transfers() public {
        hook.transferOwnership(user);
        assertEq(hook.owner(), user);

        // Old owner can't call owner functions anymore
        vm.expectRevert(SentimentFeeHook.Unauthorized_NotOwner.selector);
        hook.setKeeper(address(0xDEAD));
    }

    function test_transferOwnership_revertsOnZeroAddress() public {
        vm.expectRevert(SentimentFeeHook.InvalidInput_ZeroAddress.selector);
        hook.transferOwnership(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              EVENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_updateSentiment_emitsEvent() public {
        vm.prank(keeper);
        vm.expectEmit(true, true, false, true);
        emit SentimentFeeHook.SentimentUpdated(50, 75, 57, block.timestamp);
        hook.updateSentiment(75);
    }

    function test_setKeeper_emitsEvent() public {
        address newKeeper = address(0xDEAD);
        vm.expectEmit(true, true, false, false);
        emit SentimentFeeHook.PrimaryKeeperUpdated(keeper, newKeeper);
        hook.setKeeper(newKeeper);
    }

    /*//////////////////////////////////////////////////////////////
                          MULTI-KEEPER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setKeeperAuthorization_addsKeeper() public {
        address newKeeper = makeAddr("newKeeper");

        // Initially not authorized
        assertFalse(hook.authorizedKeepers(newKeeper));

        // Authorize
        hook.setKeeperAuthorization(newKeeper, true);
        assertTrue(hook.authorizedKeepers(newKeeper));
    }

    function test_setKeeperAuthorization_removesKeeper() public {
        address newKeeper = makeAddr("newKeeper2");

        // Authorize then revoke
        hook.setKeeperAuthorization(newKeeper, true);
        assertTrue(hook.authorizedKeepers(newKeeper));

        hook.setKeeperAuthorization(newKeeper, false);
        assertFalse(hook.authorizedKeepers(newKeeper));
    }

    function test_setKeeperAuthorization_onlyOwner() public {
        address newKeeper = makeAddr("newKeeper3");
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(SentimentFeeHook.Unauthorized_NotOwner.selector);
        hook.setKeeperAuthorization(newKeeper, true);
    }

    function test_setKeeperAuthorization_revertsOnZeroAddress() public {
        vm.expectRevert(SentimentFeeHook.InvalidInput_ZeroAddress.selector);
        hook.setKeeperAuthorization(address(0), true);
    }

    function test_multiKeeper_authorizedCanUpdate() public {
        address keeper2 = makeAddr("keeper2");

        // Authorize second keeper
        hook.setKeeperAuthorization(keeper2, true);

        // Second keeper can update
        vm.prank(keeper2);
        hook.updateSentiment(80);

        // Verify update happened (with EMA smoothing: 80*0.3 + 50*0.7 = 59)
        assertEq(hook.sentimentScore(), 59);
    }

    function test_multiKeeper_unauthorizedCannotUpdate() public {
        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert(SentimentFeeHook.Unauthorized_NotKeeper.selector);
        hook.updateSentiment(80);
    }

    function test_isAuthorizedKeeper_returnsTrueForPrimaryKeeper() public view {
        assertTrue(hook.isAuthorizedKeeper(keeper));
    }

    function test_isAuthorizedKeeper_returnsTrueForAuthorizedKeeper() public {
        address keeper2 = makeAddr("keeper2ForAuth");
        hook.setKeeperAuthorization(keeper2, true);
        assertTrue(hook.isAuthorizedKeeper(keeper2));
    }

    function test_isAuthorizedKeeper_returnsFalseForUnauthorized() public {
        address unauthorized = makeAddr("unauthorized2");
        assertFalse(hook.isAuthorizedKeeper(unauthorized));
    }

    function test_setKeeper_updatesAuthorizedMapping() public {
        address newKeeper = address(0xDEAD);

        // Original keeper is authorized
        assertTrue(hook.authorizedKeepers(keeper));

        // Set new keeper
        hook.setKeeper(newKeeper);

        // Old keeper removed from mapping, new one added
        assertFalse(hook.authorizedKeepers(keeper));
        assertTrue(hook.authorizedKeepers(newKeeper));
    }

    /*//////////////////////////////////////////////////////////////
                          HOOK PERMISSIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getHookPermissions_correctFlags() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertTrue(permissions.beforeSwap);
        assertFalse(permissions.afterSwap);
        assertFalse(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
    }
}
