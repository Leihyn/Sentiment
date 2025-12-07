// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SentimentFeeHook} from "../src/SentimentFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title MineHookAddress
/// @notice Standalone script to mine a valid hook address
/// @dev Run with: forge script script/MineHookAddress.s.sol --sig "mine(address,address,address)"
contract MineHookAddress is Script {
    /// @notice The mask for all hook permission bits (lower 14 bits)
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    /// @notice Mine a valid hook address for given parameters
    /// @param deployer The address that will deploy (for CREATE2 calculation)
    /// @param poolManager The Uniswap v4 PoolManager address
    /// @param keeper The keeper address for sentiment updates
    function mine(
        address deployer,
        address poolManager,
        address keeper
    ) public pure {
        uint8 emaAlpha = 30;
        uint256 stalenessThreshold = 6 hours;

        console2.log("=== Hook Address Mining ===");
        console2.log("Deployer:", deployer);
        console2.log("Pool Manager:", poolManager);
        console2.log("Keeper:", keeper);
        console2.log("");

        // Required flags for beforeSwap
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        console2.log("Required flags:", flags);

        bytes memory constructorArgs = abi.encode(
            poolManager,
            keeper,
            emaAlpha,
            stalenessThreshold
        );

        bytes memory bytecode = abi.encodePacked(
            type(SentimentFeeHook).creationCode,
            constructorArgs
        );
        bytes32 bytecodeHash = keccak256(bytecode);

        console2.log("Bytecode hash:", vm.toString(bytecodeHash));
        console2.log("");
        console2.log("Mining...");

        uint256 saltNum = 0;
        uint256 maxIterations = 1000000;

        while (saltNum < maxIterations) {
            bytes32 salt = bytes32(saltNum);
            address hookAddress = computeCreate2Address(deployer, salt, bytecodeHash);

            // Check if the lower 14 bits EXACTLY match
            if (uint160(hookAddress) & ALL_HOOK_MASK == flags) {
                console2.log("");
                console2.log("=== FOUND VALID ADDRESS ===");
                console2.log("Salt (uint256):", saltNum);
                console2.log("Salt (bytes32):", vm.toString(salt));
                console2.log("Hook Address:", hookAddress);
                console2.log("");
                console2.log("Address flags check:");
                console2.log("  Lower 14 bits:", uint160(hookAddress) & ALL_HOOK_MASK);
                console2.log("  Required flags:", flags);
                console2.log("  Exact match:", uint160(hookAddress) & ALL_HOOK_MASK == flags);
                return;
            }

            if (saltNum % 100000 == 0 && saltNum > 0) {
                console2.log("Searched", saltNum, "salts...");
            }

            saltNum++;
        }

        console2.log("ERROR: Could not find valid salt in", maxIterations, "iterations");
    }

    /// @notice Quick mine with environment variables
    function run() public view {
        address deployer = vm.envOr("DEPLOYER", msg.sender);
        address poolManager = vm.envAddress("POOL_MANAGER");
        address keeper = vm.envAddress("KEEPER_ADDRESS");

        mine(deployer, poolManager, keeper);
    }

    function computeCreate2Address(
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
}
