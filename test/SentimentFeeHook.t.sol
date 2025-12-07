// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SentimentFeeHook} from "../src/SentimentFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract SentimentFeeHookTest is Test {
    SentimentFeeHook public hook;
    PoolManager public poolManager;

    address public owner = address(this);
    address public keeper = address(0xBEEF);
    address public user = address(0xCAFE);

    uint8 constant EMA_ALPHA = 30; // 30% weight to new values
    uint256 constant STALENESS_THRESHOLD = 6 hours;

    // Expected fee constants (from contract)
    uint24 constant MIN_FEE = 2500;
    uint24 constant MAX_FEE = 4400;
    uint24 constant DEFAULT_FEE = 3000;
    uint24 constant FEE_RANGE = MAX_FEE - MIN_FEE;

    function setUp() public {
        // Deploy PoolManager
        poolManager = new PoolManager(address(0));

        // Mine valid hook address
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

        // Deploy hook to mined address
        hook = new SentimentFeeHook{salt: salt}(
            IPoolManager(address(poolManager)),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        // Verify deployment address
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

        vm.expectRevert(SentimentFeeHook.ZeroAddress.selector);
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

        vm.expectRevert(SentimentFeeHook.StalenessThresholdTooLow.selector);
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
        vm.expectRevert(SentimentFeeHook.OnlyKeeper.selector);
        hook.updateSentiment(75);
    }

    function test_updateSentiment_revertsOnInvalidScore() public {
        vm.prank(keeper);
        vm.expectRevert(SentimentFeeHook.InvalidSentimentScore.selector);
        hook.updateSentiment(101);
    }

    function test_setKeeper_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(SentimentFeeHook.OnlyOwner.selector);
        hook.setKeeper(user);
    }

    function test_setKeeper_updatesKeeper() public {
        address newKeeper = address(0xDEAD);
        hook.setKeeper(newKeeper);
        assertEq(hook.keeper(), newKeeper);
    }

    function test_setKeeper_revertsOnZeroAddress() public {
        vm.expectRevert(SentimentFeeHook.ZeroAddress.selector);
        hook.setKeeper(address(0));
    }

    function test_setStalenessThreshold_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(SentimentFeeHook.OnlyOwner.selector);
        hook.setStalenessThreshold(12 hours);
    }

    function test_setStalenessThreshold_updates() public {
        hook.setStalenessThreshold(12 hours);
        assertEq(hook.stalenessThreshold(), 12 hours);
    }

    function test_setStalenessThreshold_revertsOnLowValue() public {
        vm.expectRevert(SentimentFeeHook.StalenessThresholdTooLow.selector);
        hook.setStalenessThreshold(30 minutes);
    }

    function test_setEmaAlpha_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(SentimentFeeHook.OnlyOwner.selector);
        hook.setEmaAlpha(50);
    }

    function test_setEmaAlpha_updates() public {
        hook.setEmaAlpha(50);
        assertEq(hook.emaAlpha(), 50);
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(SentimentFeeHook.OnlyOwner.selector);
        hook.transferOwnership(user);
    }

    function test_transferOwnership_transfers() public {
        hook.transferOwnership(user);
        assertEq(hook.owner(), user);

        // Old owner can't call owner functions anymore
        vm.expectRevert(SentimentFeeHook.OnlyOwner.selector);
        hook.setKeeper(address(0xDEAD));
    }

    function test_transferOwnership_revertsOnZeroAddress() public {
        vm.expectRevert(SentimentFeeHook.ZeroAddress.selector);
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
        emit SentimentFeeHook.KeeperUpdated(keeper, newKeeper);
        hook.setKeeper(newKeeper);
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
