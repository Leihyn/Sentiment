// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/// @title NetworkConfig
/// @notice Configuration for Uniswap v4 deployments across networks
/// @dev PoolManager addresses - update with actual deployed addresses
///      Check https://docs.uniswap.org/contracts/v4/deployments for latest
contract NetworkConfig is Script {
    struct Config {
        address poolManager;
        address positionManager;
        address quoter;
        uint256 chainId;
        string name;
    }

    // ============ Mainnet Addresses ============
    // NOTE: These are placeholder addresses. Update with actual v4 deployments.
    // Uniswap v4 uses CREATE2 with deterministic addresses across chains.

    // Ethereum Mainnet (update when v4 launches)
    address constant MAINNET_POOL_MANAGER = address(0);

    // Arbitrum One
    address constant ARBITRUM_POOL_MANAGER = address(0);

    // Optimism
    address constant OPTIMISM_POOL_MANAGER = address(0);

    // Base
    address constant BASE_POOL_MANAGER = address(0);

    // Polygon
    address constant POLYGON_POOL_MANAGER = address(0);

    // ============ Testnet Addresses ============

    // Sepolia (check Uniswap docs for current deployment)
    address constant SEPOLIA_POOL_MANAGER = address(0);

    // Base Sepolia
    address constant BASE_SEPOLIA_POOL_MANAGER = address(0);

    // Arbitrum Sepolia
    address constant ARBITRUM_SEPOLIA_POOL_MANAGER = address(0);

    /// @notice Get the PoolManager address for the current chain
    /// @dev Returns address(0) if not configured - set via POOL_MANAGER env var
    function getPoolManager() public view returns (address) {
        uint256 chainId = block.chainid;

        // Mainnets
        if (chainId == 1) return MAINNET_POOL_MANAGER;
        if (chainId == 42161) return ARBITRUM_POOL_MANAGER;
        if (chainId == 10) return OPTIMISM_POOL_MANAGER;
        if (chainId == 8453) return BASE_POOL_MANAGER;
        if (chainId == 137) return POLYGON_POOL_MANAGER;

        // Testnets
        if (chainId == 11155111) return SEPOLIA_POOL_MANAGER;
        if (chainId == 84532) return BASE_SEPOLIA_POOL_MANAGER;
        if (chainId == 421614) return ARBITRUM_SEPOLIA_POOL_MANAGER;

        // Local/Anvil - return zero (must deploy fresh or set via env)
        if (chainId == 31337) return address(0);

        // Unknown chain - return zero
        return address(0);
    }

    /// @notice Get full config for the current chain
    function getConfig() public view returns (Config memory) {
        uint256 chainId = block.chainid;
        address poolManager = getPoolManager();

        string memory name;
        if (chainId == 1) name = "Ethereum Mainnet";
        else if (chainId == 42161) name = "Arbitrum One";
        else if (chainId == 10) name = "Optimism";
        else if (chainId == 8453) name = "Base";
        else if (chainId == 137) name = "Polygon";
        else if (chainId == 11155111) name = "Sepolia";
        else if (chainId == 84532) name = "Base Sepolia";
        else if (chainId == 421614) name = "Arbitrum Sepolia";
        else if (chainId == 31337) name = "Local/Anvil";
        else name = "Unknown";

        return Config({
            poolManager: poolManager,
            positionManager: address(0),
            quoter: address(0),
            chainId: chainId,
            name: name
        });
    }

    /// @notice Check if we're on a testnet
    function isTestnet() public view returns (bool) {
        uint256 chainId = block.chainid;
        return chainId == 11155111 || // Sepolia
               chainId == 84532 ||    // Base Sepolia
               chainId == 421614 ||   // Arbitrum Sepolia
               chainId == 31337;      // Anvil/Local
    }
}
