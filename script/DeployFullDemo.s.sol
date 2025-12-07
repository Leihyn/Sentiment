// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SentimentFeeHook} from "../src/SentimentFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title DeployFullDemo
/// @notice Deploys mock tokens, hook, pool, and adds liquidity - complete demo
contract DeployFullDemo is Script {
    uint8 constant EMA_ALPHA = 30;
    uint256 constant STALENESS_THRESHOLD = 6 hours;
    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // 1:1 price
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Use deployer as keeper for simplicity, or set custom
        address keeper = vm.envOr("KEEPER_ADDRESS", deployer);

        // Token names (customizable via env)
        string memory token0Name = vm.envOr("TOKEN0_NAME", string("SentimentCoin"));
        string memory token0Symbol = vm.envOr("TOKEN0_SYMBOL", string("SENT"));
        string memory token1Name = vm.envOr("TOKEN1_NAME", string("StableCoin"));
        string memory token1Symbol = vm.envOr("TOKEN1_SYMBOL", string("USDC"));

        // Liquidity amount
        uint256 liquidityAmount = vm.envOr("LIQUIDITY_AMOUNT", uint256(100 ether));

        console2.log("=== DEPLOYING FULL SENTIMENT HOOK DEMO ===");
        console2.log("Deployer:", deployer);
        console2.log("Keeper:", keeper);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy PoolManager
        PoolManager poolManager = new PoolManager(address(0));
        console2.log("\n1. PoolManager deployed:", address(poolManager));

        // 2. Deploy Mock Tokens
        MockERC20 tokenA = new MockERC20(token0Name, token0Symbol, 18);
        MockERC20 tokenB = new MockERC20(token1Name, token1Symbol, 18);

        // Sort tokens (required by Uniswap)
        MockERC20 token0;
        MockERC20 token1;
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }

        console2.log("\n2. Tokens deployed:");
        console2.log("   Token0:", token0.name(), "-", address(token0));
        console2.log("   Token1:", token1.name(), "-", address(token1));

        // 3. Mint tokens to deployer
        token0.mint(deployer, 1_000_000 ether);
        token1.mint(deployer, 1_000_000 ether);
        console2.log("\n3. Minted 1,000,000 of each token to deployer");

        // 4. Deploy Hook with CREATE2
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

        SentimentFeeHook hook = new SentimentFeeHook{salt: salt}(
            IPoolManager(address(poolManager)),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );
        require(address(hook) == hookAddress, "Hook address mismatch");
        console2.log("\n4. SentimentFeeHook deployed:", address(hook));

        // 5. Deploy helper routers
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(poolManager);
        PoolSwapTest swapRouter = new PoolSwapTest(poolManager);
        console2.log("\n5. Routers deployed:");
        console2.log("   LiquidityRouter:", address(liquidityRouter));
        console2.log("   SwapRouter:", address(swapRouter));

        // 6. Approve routers
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        console2.log("\n6. Approved routers for token spending");

        // 7. Create Pool
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);
        console2.log("\n7. Pool initialized with 1:1 price");

        // 8. Add Liquidity
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: int256(liquidityAmount),
            salt: 0
        });
        liquidityRouter.modifyLiquidity(poolKey, params, "");
        console2.log("\n8. Added liquidity:", liquidityAmount / 1 ether, "tokens each side");

        vm.stopBroadcast();

        // Summary
        console2.log("\n========================================");
        console2.log("       DEPLOYMENT COMPLETE!");
        console2.log("========================================");
        console2.log("\nContract Addresses:");
        console2.log("  PoolManager:", address(poolManager));
        console2.log("  Hook:", address(hook));
        console2.log("  Token0:", address(token0));
        console2.log("  Token1:", address(token1));
        console2.log("  LiquidityRouter:", address(liquidityRouter));
        console2.log("  SwapRouter:", address(swapRouter));
        console2.log("\nHook Settings:");
        console2.log("  Keeper:", keeper);
        console2.log("  Initial Sentiment:", hook.sentimentScore());
        console2.log("  Current Fee (bps):", hook.getCurrentFee());
        console2.log("\nNext Steps:");
        console2.log("  1. Update keeper/.env with HOOK_ADDRESS");
        console2.log("  2. Run: cd keeper && npx ts-node src/keeper.ts --once");
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
                        abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash)
                    )
                )
            )
        );
    }
}
