// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SentimentFeeHook} from "../src/SentimentFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title DeployLocal
/// @notice Deploys PoolManager and SentimentFeeHook to local Anvil
contract DeployLocal is Script {
    uint8 constant EMA_ALPHA = 30;
    uint256 constant STALENESS_THRESHOLD = 6 hours;
    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    // Forge's deterministic CREATE2 deployer
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Deployer:", deployer);
        console2.log("Keeper:", keeper);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy PoolManager
        PoolManager poolManager = new PoolManager(address(0));
        console2.log("PoolManager deployed:", address(poolManager));

        // Mine hook address using CREATE2_DEPLOYER (forge's deterministic deployer)
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        (address hookAddress, bytes32 salt) = mineSalt(
            CREATE2_DEPLOYER,
            flags,
            type(SentimentFeeHook).creationCode,
            constructorArgs
        );

        console2.log("Mined hook address:", hookAddress);

        // Deploy hook
        SentimentFeeHook hook = new SentimentFeeHook{salt: salt}(
            IPoolManager(address(poolManager)),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        vm.stopBroadcast();

        require(address(hook) == hookAddress, "Address mismatch");

        console2.log("");
        console2.log("=== DEPLOYMENT COMPLETE ===");
        console2.log("PoolManager:", address(poolManager));
        console2.log("Hook:", address(hook));
        console2.log("Keeper:", keeper);
        console2.log("Initial sentiment:", hook.sentimentScore());
    }

    function mineSalt(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 bytecodeHash = keccak256(bytecode);

        uint256 saltNum = 0;
        while (saltNum < 1000000) {
            salt = bytes32(saltNum);
            hookAddress = computeCreate2Address(deployer, salt, bytecodeHash);
            if (uint160(hookAddress) & ALL_HOOK_MASK == flags) {
                return (hookAddress, salt);
            }
            saltNum++;
        }
        revert("Could not find valid salt");
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
