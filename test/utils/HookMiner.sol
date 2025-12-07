// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookMiner
/// @notice Utility for mining hook addresses that match required permission flags
/// @dev Uniswap v4 hooks require their address to encode their permissions in the lower 14 bits
library HookMiner {
    /// @notice The mask for all hook permission bits (lower 14 bits)
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    /// @notice Find a salt that produces a hook address with the required flags
    /// @param deployer The address that will deploy the hook (for CREATE2)
    /// @param flags The required permission flags (encoded in lower 14 bits of address)
    /// @param creationCode The contract creation code
    /// @param constructorArgs The ABI-encoded constructor arguments
    /// @return hookAddress The address that will be deployed to
    /// @return salt The salt to use for CREATE2 deployment
    function find(
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
            hookAddress = computeAddress(deployer, salt, bytecodeHash);

            // Check if the lower 14 bits of the address EXACTLY match the required flags
            // This ensures only the specified permissions are enabled, and no others
            if (uint160(hookAddress) & ALL_HOOK_MASK == flags) {
                return (hookAddress, salt);
            }

            saltNum++;
            // Safety check to prevent infinite loop in tests
            require(saltNum < 1000000, "HookMiner: could not find valid salt");
        }
    }

    /// @notice Compute the CREATE2 address for a contract
    /// @param deployer The deployer address
    /// @param salt The salt value
    /// @param bytecodeHash The hash of the creation bytecode
    /// @return The computed address
    function computeAddress(
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
