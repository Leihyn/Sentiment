// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/// @title CreatePool
/// @notice Script to create a pool with the SentimentFeeHook and DYNAMIC_FEE_FLAG
contract CreatePool is Script {
    /// @notice Create a new pool with the sentiment hook
    /// @param token0 The first token (must be < token1)
    /// @param token1 The second token (must be > token0)
    /// @param hookAddress The deployed SentimentFeeHook address
    /// @param tickSpacing The tick spacing for the pool
    /// @param initialSqrtPriceX96 The initial sqrt price (use 79228162514264337593543950336 for 1:1)
    function createPool(
        address token0,
        address token1,
        address hookAddress,
        int24 tickSpacing,
        uint160 initialSqrtPriceX96
    ) public {
        require(token0 < token1, "Tokens must be sorted: token0 < token1");

        NetworkConfig config = new NetworkConfig();
        address poolManager = config.getPoolManager();

        console2.log("=== Creating Pool ===");
        console2.log("Pool Manager:", poolManager);
        console2.log("Token0:", token0);
        console2.log("Token1:", token1);
        console2.log("Hook:", hookAddress);
        console2.log("Tick Spacing:", tickSpacing);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddress)
        });

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        IPoolManager(poolManager).initialize(key, initialSqrtPriceX96);

        vm.stopBroadcast();

        console2.log("Pool created successfully!");
        console2.log("Fee flag: DYNAMIC_FEE_FLAG (0x800000)");
    }

    /// @notice Quick pool creation using environment variables
    function run() public {
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));

        // Default to 1:1 price
        uint160 initialPrice = uint160(vm.envOr(
            "INITIAL_SQRT_PRICE",
            uint256(79228162514264337593543950336) // SQRT_PRICE_1_1
        ));

        createPool(token0, token1, hookAddress, tickSpacing, initialPrice);
    }
}
