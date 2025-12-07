// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SentimentFeeHook} from "../src/SentimentFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/// @title DeploySentimentHook
/// @notice Deployment script for SentimentFeeHook with CREATE2 address mining
contract DeploySentimentHook is Script {
    // Hook configuration
    uint8 constant EMA_ALPHA = 30; // 30% weight to new values
    uint256 constant STALENESS_THRESHOLD = 6 hours;

    function run() public {
        // Get PoolManager from network config
        NetworkConfig config = new NetworkConfig();
        address poolManager = config.getPoolManager();

        // Allow override from environment
        poolManager = vm.envOr("POOL_MANAGER", poolManager);
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Deployer:", deployer);
        console2.log("Pool Manager:", poolManager);
        console2.log("Keeper:", keeper);

        // Calculate required hook flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);

        // Mine the hook address
        bytes memory constructorArgs = abi.encode(
            poolManager,
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        (address hookAddress, bytes32 salt) = mineSalt(
            deployer,
            flags,
            type(SentimentFeeHook).creationCode,
            constructorArgs
        );

        console2.log("Mined hook address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));

        // Deploy
        vm.startBroadcast(deployerPrivateKey);

        SentimentFeeHook hook = new SentimentFeeHook{salt: salt}(
            IPoolManager(poolManager),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        vm.stopBroadcast();

        // Verify deployment
        require(address(hook) == hookAddress, "Deployment address mismatch");

        console2.log("Hook deployed successfully!");
        console2.log("Address:", address(hook));
        console2.log("Keeper:", hook.keeper());
        console2.log("EMA Alpha:", hook.emaAlpha());
        console2.log("Staleness Threshold:", hook.stalenessThreshold());
        console2.log("Initial Sentiment:", hook.sentimentScore());
    }

    /// @notice The mask for all hook permission bits (lower 14 bits)
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    /// @notice Mine a salt that produces a valid hook address
    function mineSalt(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 bytecodeHash = keccak256(bytecode);

        uint256 saltNum = 0;
        while (true) {
            salt = bytes32(saltNum);
            hookAddress = computeCreate2Address(deployer, salt, bytecodeHash);

            // Check if the lower 14 bits of the address EXACTLY match the required flags
            if (uint160(hookAddress) & ALL_HOOK_MASK == flags) {
                return (hookAddress, salt);
            }

            saltNum++;
            require(saltNum < 1000000, "Could not find valid salt");
        }
    }

    /// @notice Compute CREATE2 address
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
