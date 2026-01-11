// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Gas Benchmark Tests
 * @notice Measures and documents gas consumption of all SentimentFeeHook operations
 * @dev Run with: forge test --match-contract GasBenchmark -vvv --gas-report
 *
 * ┌──────────────────────────────────────────────────────────────────────┐
 * │                     GAS BENCHMARKING EXPLAINED                       │
 * ├──────────────────────────────────────────────────────────────────────┤
 * │                                                                      │
 * │  Why Benchmark Gas?                                                  │
 * │  • beforeSwap is called on EVERY swap - must be cheap               │
 * │  • updateSentiment called ~every 4 hours - can be more expensive    │
 * │  • View functions (getCurrentFee) may be called by frontends        │
 * │                                                                      │
 * │  How to Read Results:                                                │
 * │  • Operations < 5,000 gas: Excellent (view functions)               │
 * │  • Operations 5,000 - 30,000 gas: Good (state changes)              │
 * │  • Operations > 30,000 gas: May need optimization                   │
 * │                                                                      │
 * │  For Reference (EIP-2929 costs):                                     │
 * │  • SLOAD (cold): ~2,100 gas                                         │
 * │  • SLOAD (warm): ~100 gas                                           │
 * │  • SSTORE (0→non-0): ~20,000 gas                                    │
 * │  • SSTORE (non-0→non-0): ~2,900 gas                                 │
 * │                                                                      │
 * └──────────────────────────────────────────────────────────────────────┘
 */

import {Test, console2} from "forge-std/Test.sol";
import {SentimentFeeHook} from "../src/SentimentFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract GasBenchmark is Test {
    SentimentFeeHook public hook;
    PoolManager public poolManager;

    address public owner = address(this);
    address public keeper = address(0xBEEF);

    uint8 constant EMA_ALPHA = 30;
    uint256 constant STALENESS_THRESHOLD = 6 hours;

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

        // Deploy hook
        hook = new SentimentFeeHook{salt: salt}(
            IPoolManager(address(poolManager)),
            keeper,
            EMA_ALPHA,
            STALENESS_THRESHOLD
        );

        assertEq(address(hook), hookAddress);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice CRITICAL: This is called on every swap via beforeSwap
    function test_gas_getCurrentFee() public view {
        hook.getCurrentFee();
    }

    function test_gas_sentimentScore() public view {
        hook.sentimentScore();
    }

    function test_gas_isStale() public view {
        hook.isStale();
    }

    function test_gas_timeUntilStale() public view {
        hook.timeUntilStale();
    }

    function test_gas_isAuthorizedKeeper() public view {
        hook.isAuthorizedKeeper(keeper);
    }

    function test_gas_emaAlpha() public view {
        hook.emaAlpha();
    }

    function test_gas_stalenessThreshold() public view {
        hook.stalenessThreshold();
    }

    function test_gas_primaryKeeper() public view {
        hook.primaryKeeper();
    }

    /*//////////////////////////////////////////////////////////////
                     UPDATE SENTIMENT BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice First update - measures with warm storage from setUp
    function test_gas_updateSentiment_first() public {
        vm.prank(keeper);
        hook.updateSentiment(75);
    }

    /// @notice Second update immediately after - fully warm storage
    function test_gas_updateSentiment_warm() public {
        vm.prank(keeper);
        hook.updateSentiment(75);

        vm.prank(keeper);
        hook.updateSentiment(25);
    }

    /// @notice Update with extreme value (0)
    function test_gas_updateSentiment_zero() public {
        vm.prank(keeper);
        hook.updateSentiment(0);
    }

    /// @notice Update with extreme value (100)
    function test_gas_updateSentiment_max() public {
        vm.prank(keeper);
        hook.updateSentiment(100);
    }

    /// @notice Update after time has passed (simulates real usage)
    function test_gas_updateSentiment_afterDelay() public {
        vm.prank(keeper);
        hook.updateSentiment(75);

        vm.warp(block.timestamp + 4 hours);

        vm.prank(keeper);
        hook.updateSentiment(60);
    }

    /*//////////////////////////////////////////////////////////////
                      ADMIN FUNCTION BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    function test_gas_setKeeperAuthorization_add() public {
        hook.setKeeperAuthorization(address(0xCAFE), true);
    }

    function test_gas_setKeeperAuthorization_remove() public {
        hook.setKeeperAuthorization(address(0xCAFE), true);
        hook.setKeeperAuthorization(address(0xCAFE), false);
    }

    function test_gas_setEmaAlpha() public {
        hook.setEmaAlpha(40);
    }

    function test_gas_setStalenessThreshold() public {
        hook.setStalenessThreshold(8 hours);
    }

    function test_gas_setKeeper() public {
        hook.setKeeper(address(0xCAFE));
    }

    function test_gas_transferOwnership() public {
        hook.transferOwnership(address(0xCAFE));
    }

    /*//////////////////////////////////////////////////////////////
                      STALENESS SCENARIO BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// @notice getCurrentFee when data is stale (returns default)
    function test_gas_getCurrentFee_stale() public {
        vm.warp(block.timestamp + 7 hours);
        assertTrue(hook.isStale());
        hook.getCurrentFee();
    }

    /// @notice Update after staleness period
    function test_gas_updateSentiment_afterStale() public {
        vm.warp(block.timestamp + 7 hours);
        assertTrue(hook.isStale());

        vm.prank(keeper);
        hook.updateSentiment(50);
    }

    /*//////////////////////////////////////////////////////////////
                         SUMMARY & ANALYSIS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Prints gas summary - run with -vvv to see
     * @dev This test logs analysis, actual measurements come from --gas-report
     */
    function test_gas_summary() public pure {
        console2.log("");
        console2.log("============================================================");
        console2.log("           GAS BENCHMARK ANALYSIS");
        console2.log("============================================================");
        console2.log("");
        console2.log("CRITICAL PATH (every swap):");
        console2.log("  getCurrentFee() should be < 5,000 gas");
        console2.log("");
        console2.log("PERIODIC (every ~4 hours):");
        console2.log("  updateSentiment() can be up to 30,000 gas");
        console2.log("");
        console2.log("RARE (admin operations):");
        console2.log("  setKeeper, setEmaAlpha, etc. - gas not critical");
        console2.log("");
        console2.log("Run with --gas-report for detailed measurements");
        console2.log("============================================================");
    }
}
