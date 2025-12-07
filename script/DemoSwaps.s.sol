// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SentimentFeeHook} from "../src/SentimentFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title DemoSwaps
/// @notice Demonstrates sentiment-based fee changes with actual swaps
contract DemoSwaps is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Get deployed addresses from env
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        address token0Address = vm.envAddress("TOKEN0_ADDRESS");
        address token1Address = vm.envAddress("TOKEN1_ADDRESS");
        address swapRouterAddress = vm.envAddress("SWAP_ROUTER_ADDRESS");

        SentimentFeeHook hook = SentimentFeeHook(hookAddress);
        MockERC20 token0 = MockERC20(token0Address);
        MockERC20 token1 = MockERC20(token1Address);
        PoolSwapTest swapRouter = PoolSwapTest(swapRouterAddress);

        // Build pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0Address),
            currency1: Currency.wrap(token1Address),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        uint256 swapAmount = 1 ether;

        console2.log("=========================================");
        console2.log("  SENTIMENT FEE HOOK - SWAP DEMO");
        console2.log("=========================================");
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Get initial balances
        address deployer = vm.addr(deployerPrivateKey);
        uint256 initialToken0 = token0.balanceOf(deployer);
        uint256 initialToken1 = token1.balanceOf(deployer);

        console2.log("Initial Balances:");
        console2.log("  Token0:", initialToken0 / 1e18);
        console2.log("  Token1:", initialToken1 / 1e18);
        console2.log("");

        // ========== DEMO 1: NEUTRAL SENTIMENT ==========
        console2.log("--- SCENARIO 1: NEUTRAL MARKET (50) ---");
        hook.updateSentiment(50);
        console2.log("Sentiment set to:", hook.sentimentScore());
        console2.log("Fee (bps):", hook.getCurrentFee());

        uint256 beforeSwap1 = token1.balanceOf(deployer);
        _executeSwap(swapRouter, poolKey, swapAmount, true);
        uint256 afterSwap1 = token1.balanceOf(deployer);
        uint256 received1 = afterSwap1 - beforeSwap1;
        console2.log("Swapped 1 Token0 -> Received (wei):", received1);
        console2.log("");

        // ========== DEMO 2: FEAR SENTIMENT ==========
        console2.log("--- SCENARIO 2: FEAR MARKET (10) ---");
        // Update multiple times to overcome EMA smoothing
        hook.updateSentiment(10);
        hook.updateSentiment(10);
        hook.updateSentiment(10);
        hook.updateSentiment(10);
        hook.updateSentiment(10);
        console2.log("Sentiment set to:", hook.sentimentScore());
        console2.log("Fee (bps):", hook.getCurrentFee());
        console2.log("LOWER fee - encouraging trades!");

        uint256 beforeSwap2 = token1.balanceOf(deployer);
        _executeSwap(swapRouter, poolKey, swapAmount, true);
        uint256 afterSwap2 = token1.balanceOf(deployer);
        uint256 received2 = afterSwap2 - beforeSwap2;
        console2.log("Swapped 1 Token0 -> Received (wei):", received2);
        console2.log("More tokens than neutral (lower fee)");
        console2.log("");

        // ========== DEMO 3: GREED SENTIMENT ==========
        console2.log("--- SCENARIO 3: GREED MARKET (90) ---");
        // Update multiple times to overcome EMA smoothing
        hook.updateSentiment(90);
        hook.updateSentiment(90);
        hook.updateSentiment(90);
        hook.updateSentiment(90);
        hook.updateSentiment(90);
        hook.updateSentiment(90);
        hook.updateSentiment(90);
        console2.log("Sentiment set to:", hook.sentimentScore());
        console2.log("Fee (bps):", hook.getCurrentFee());
        console2.log("HIGHER fee - capturing FOMO!");

        uint256 beforeSwap3 = token1.balanceOf(deployer);
        _executeSwap(swapRouter, poolKey, swapAmount, true);
        uint256 afterSwap3 = token1.balanceOf(deployer);
        uint256 received3 = afterSwap3 - beforeSwap3;
        console2.log("Swapped 1 Token0 -> Received (wei):", received3);
        console2.log("Fewer tokens than neutral (higher fee)");
        console2.log("");

        vm.stopBroadcast();

        // ========== SUMMARY ==========
        console2.log("=========================================");
        console2.log("           DEMO SUMMARY");
        console2.log("=========================================");
        console2.log("");
        console2.log("Same 1 Token0 swap at different sentiments:");
        console2.log("");
        console2.log("  FEAR (low sentiment):");
        console2.log("    - Lower fees encourage trading");
        console2.log("    - Trader receives MORE tokens");
        console2.log("");
        console2.log("  GREED (high sentiment):");
        console2.log("    - Higher fees capture value from FOMO");
        console2.log("    - Trader receives FEWER tokens");
        console2.log("    - LPs earn more fees");
        console2.log("");
        console2.log("This demonstrates adaptive fee mechanism!");
        console2.log("=========================================");
    }

    function _executeSwap(
        PoolSwapTest swapRouter,
        PoolKey memory poolKey,
        uint256 amount,
        bool zeroForOne
    ) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount), // exact input
            sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, params, settings, "");
    }
}
