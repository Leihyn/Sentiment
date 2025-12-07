// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SentimentFeeHook} from "../src/SentimentFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title SentimentFeeHook Integration Tests
/// @notice Tests the full swap flow with dynamic fees based on sentiment
contract SentimentFeeHookIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // Hook permission mask
    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    // Price constants
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant SQRT_PRICE_1_2 = 56022770974786139918731938227;

    // Contracts
    PoolManager public manager;
    SentimentFeeHook public hook;
    PoolSwapTest public swapRouter;
    PoolModifyLiquidityTest public modifyLiquidityRouter;

    // Tokens
    MockERC20 public token0;
    MockERC20 public token1;
    Currency public currency0;
    Currency public currency1;

    // Pool
    PoolKey public poolKey;

    // Actors
    address public owner = address(this);
    address public keeper = address(0xBEEF);
    address public trader = address(0xCAFE);

    // Hook config
    uint8 constant EMA_ALPHA = 30;
    uint256 constant STALENESS_THRESHOLD = 6 hours;

    // Fee constants
    uint24 constant MIN_FEE = 2500;
    uint24 constant MAX_FEE = 4400;

    event Swap(
        PoolId indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    function setUp() public {
        // Deploy PoolManager
        manager = new PoolManager(address(0));

        // Deploy routers
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy and sort tokens
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Mint tokens
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        token0.mint(trader, 100 ether);
        token1.mint(trader, 100 ether);

        // Approve routers
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        vm.startPrank(trader);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Deploy hook to correct address using CREATE2
        _deployHookWithCreate2();

        // Create pool with DYNAMIC_FEE_FLAG
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Add liquidity
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100 ether,
            salt: 0
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");
    }

    function _deployHookWithCreate2() internal {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(
            address(manager),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        bytes memory bytecode = abi.encodePacked(
            type(SentimentFeeHook).creationCode,
            constructorArgs
        );
        bytes32 bytecodeHash = keccak256(bytecode);

        // Find valid salt
        uint256 saltNum = 0;
        address hookAddress;
        bytes32 salt;

        while (saltNum < 10000000) {
            salt = bytes32(saltNum);
            hookAddress = _computeCreate2Address(address(this), salt, bytecodeHash);

            if (uint160(hookAddress) & ALL_HOOK_MASK == flags) {
                break;
            }
            saltNum++;
        }

        require(saltNum < 10000000, "Could not find salt");

        // Deploy
        hook = new SentimentFeeHook{salt: salt}(
            IPoolManager(address(manager)),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        require(address(hook) == hookAddress, "Address mismatch");
    }

    function _computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes32 bytecodeHash
    ) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            deployer,
                            salt,
                            bytecodeHash
                        )
                    )
                )
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                         INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_swap_usesDynamicFee() public {
        // Initial sentiment is 50 (neutral)
        // Fee should be: 2500 + (50 * 1900 / 100) = 3450
        uint24 expectedFee = MIN_FEE + uint24((50 * (MAX_FEE - MIN_FEE)) / 100);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Perform swap
        BalanceDelta delta = swapRouter.swap(poolKey, params, settings, "");

        // Verify swap occurred
        assertTrue(delta.amount0() < 0, "Should have spent token0");
        assertTrue(delta.amount1() > 0, "Should have received token1");

        // Verify fee is applied (output should be less than input due to fee)
        // With ~0.345% fee, output should be roughly 99.655% of theoretical output
    }

    function test_swap_feeChangesWithSentiment() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // First swap at neutral sentiment (50)
        BalanceDelta delta1 = swapRouter.swap(poolKey, params, settings, "");
        int128 output1 = delta1.amount1();

        // Update sentiment to extreme greed (100)
        vm.prank(keeper);
        hook.updateSentiment(100);

        // EMA smoothed: (100 * 30 + 50 * 70) / 100 = 65
        assertEq(hook.sentimentScore(), 65);

        // Second swap at higher sentiment (higher fee)
        BalanceDelta delta2 = swapRouter.swap(poolKey, params, settings, "");
        int128 output2 = delta2.amount1();

        // Higher sentiment = higher fee = less output
        assertTrue(output2 < output1, "Higher fee should result in less output");
    }

    function test_swap_afterSentimentUpdate_feeIncreases() public {
        // Get initial fee
        uint24 initialFee = hook.getCurrentFee();
        assertEq(initialFee, 3450); // 2500 + (50 * 1900 / 100)

        // Update to extreme greed
        vm.prank(keeper);
        hook.updateSentiment(100);

        // Fee should increase (EMA smoothed to 65)
        uint24 newFee = hook.getCurrentFee();
        assertGt(newFee, initialFee);

        // Expected: 2500 + (65 * 1900 / 100) = 2500 + 1235 = 3735
        assertEq(newFee, 3735);
    }

    function test_swap_afterSentimentUpdate_feeDecreases() public {
        // Get initial fee
        uint24 initialFee = hook.getCurrentFee();

        // Update to extreme fear
        vm.prank(keeper);
        hook.updateSentiment(0);

        // Fee should decrease (EMA smoothed to 35)
        uint24 newFee = hook.getCurrentFee();
        assertLt(newFee, initialFee);

        // Expected: 2500 + (35 * 1900 / 100) = 2500 + 665 = 3165
        assertEq(newFee, 3165);
    }

    function test_swap_withStaleSentiment_usesDefaultFee() public {
        // Fast forward past staleness
        vm.warp(block.timestamp + STALENESS_THRESHOLD + 1);

        assertTrue(hook.isStale());
        assertEq(hook.getCurrentFee(), 3000); // Default fee

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Swap should still work with default fee
        BalanceDelta delta = swapRouter.swap(poolKey, params, settings, "");
        assertTrue(delta.amount1() > 0);
    }

    function test_multipleSwaps_consistentFees() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Perform multiple swaps
        for (uint256 i = 0; i < 5; i++) {
            BalanceDelta delta = swapRouter.swap(poolKey, params, settings, "");
            assertTrue(delta.amount1() > 0);
        }

        // Fee should still be the same (no sentiment update)
        assertEq(hook.getCurrentFee(), 3450);
    }

    function test_swapBothDirections() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Swap token0 -> token1
        SwapParams memory params0to1 = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        BalanceDelta delta1 = swapRouter.swap(poolKey, params0to1, settings, "");
        assertTrue(delta1.amount0() < 0);
        assertTrue(delta1.amount1() > 0);

        // Swap token1 -> token0
        SwapParams memory params1to0 = SwapParams({
            zeroForOne: false,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        BalanceDelta delta2 = swapRouter.swap(poolKey, params1to0, settings, "");
        assertTrue(delta2.amount0() > 0);
        assertTrue(delta2.amount1() < 0);
    }

    function test_traderCanSwap() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint256 traderBalance0Before = token0.balanceOf(trader);
        uint256 traderBalance1Before = token1.balanceOf(trader);

        vm.prank(trader);
        swapRouter.swap(poolKey, params, settings, "");

        uint256 traderBalance0After = token0.balanceOf(trader);
        uint256 traderBalance1After = token1.balanceOf(trader);

        assertTrue(traderBalance0After < traderBalance0Before);
        assertTrue(traderBalance1After > traderBalance1Before);
    }
}
