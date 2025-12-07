// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title SentimentFeeHook
/// @notice A Uniswap v4 hook that dynamically adjusts swap fees based on market sentiment
/// @dev Implements counter-cyclical fee dynamics: higher fees during greed, lower during fear
contract SentimentFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyKeeper();
    error OnlyOwner();
    error InvalidSentimentScore();
    error StalenessThresholdTooLow();
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SentimentUpdated(uint8 indexed oldScore, uint8 indexed newScore, uint8 emaScore, uint256 timestamp);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event StalenessThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event EmaAlphaUpdated(uint8 oldAlpha, uint8 newAlpha);

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum fee: 0.25% = 2500 pips (1 pip = 0.0001%)
    uint24 public constant MIN_FEE = 2500;

    /// @notice Maximum fee: 0.44% = 4400 pips
    uint24 public constant MAX_FEE = 4400;

    /// @notice Fee range for calculation
    uint24 public constant FEE_RANGE = MAX_FEE - MIN_FEE; // 1900 pips

    /// @notice Default fee when sentiment is stale: 0.30% = 3000 pips
    uint24 public constant DEFAULT_FEE = 3000;

    /// @notice Maximum sentiment score
    uint8 public constant MAX_SENTIMENT = 100;

    /// @notice EMA scaling factor (using 100 as denominator for percentage)
    uint8 public constant EMA_DENOMINATOR = 100;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Current EMA-smoothed sentiment score (0 = extreme fear, 100 = extreme greed)
    uint8 public sentimentScore;

    /// @notice Timestamp of last sentiment update
    uint256 public lastUpdateTimestamp;

    /// @notice EMA alpha factor (0-100, represents percentage weight of new value)
    /// @dev newEMA = (newScore * alpha + oldEMA * (100 - alpha)) / 100
    uint8 public emaAlpha;

    /// @notice Maximum age of sentiment data before considered stale (in seconds)
    uint256 public stalenessThreshold;

    /// @notice Address authorized to push sentiment updates
    address public keeper;

    /// @notice Contract owner for admin functions
    address public owner;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _poolManager The Uniswap v4 pool manager
    /// @param _keeper Address authorized to update sentiment
    /// @param _emaAlpha EMA smoothing factor (0-100)
    /// @param _stalenessThreshold Max age of data in seconds (e.g., 6 hours = 21600)
    constructor(
        IPoolManager _poolManager,
        address _keeper,
        uint8 _emaAlpha,
        uint256 _stalenessThreshold
    ) BaseHook(_poolManager) {
        if (_keeper == address(0)) revert ZeroAddress();
        if (_stalenessThreshold < 1 hours) revert StalenessThresholdTooLow();

        keeper = _keeper;
        owner = msg.sender;
        emaAlpha = _emaAlpha;
        stalenessThreshold = _stalenessThreshold;
        sentimentScore = 50; // Start neutral
        lastUpdateTimestamp = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                              HOOK CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the hook's permissions
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                              HOOK LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Called before every swap to determine the dynamic fee
    /// @dev Returns fee override based on current sentiment
    function _beforeSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = _calculateFee();

        // Return the fee with the override flag set
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /*//////////////////////////////////////////////////////////////
                           SENTIMENT ORACLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the sentiment score with EMA smoothing
    /// @param _rawScore Raw sentiment score (0-100) from external sources
    function updateSentiment(uint8 _rawScore) external {
        if (msg.sender != keeper) revert OnlyKeeper();
        if (_rawScore > MAX_SENTIMENT) revert InvalidSentimentScore();

        uint8 oldScore = sentimentScore;
        uint8 newEmaScore = _applyEMA(_rawScore);

        sentimentScore = newEmaScore;
        lastUpdateTimestamp = block.timestamp;

        emit SentimentUpdated(oldScore, _rawScore, newEmaScore, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE CALCULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates the current fee based on sentiment
    /// @return fee The fee in pips (0.0001% units)
    function _calculateFee() internal view returns (uint24) {
        // Check for stale data
        if (block.timestamp > lastUpdateTimestamp + stalenessThreshold) {
            return DEFAULT_FEE;
        }

        // Linear interpolation: fee = MIN_FEE + (sentiment / 100) * FEE_RANGE
        // Using fixed point math to avoid precision loss
        uint24 fee = MIN_FEE + uint24((uint256(sentimentScore) * FEE_RANGE) / MAX_SENTIMENT);

        return fee;
    }

    /// @notice Applies exponential moving average smoothing
    /// @param _newScore The new raw sentiment score
    /// @return The EMA-smoothed score
    function _applyEMA(uint8 _newScore) internal view returns (uint8) {
        // EMA formula: newEMA = (newScore * alpha + oldEMA * (100 - alpha)) / 100
        uint256 weighted = (uint256(_newScore) * emaAlpha) +
                          (uint256(sentimentScore) * (EMA_DENOMINATOR - emaAlpha));
        return uint8(weighted / EMA_DENOMINATOR);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current fee that would be applied
    function getCurrentFee() external view returns (uint24) {
        return _calculateFee();
    }

    /// @notice Checks if the sentiment data is stale
    function isStale() external view returns (bool) {
        return block.timestamp > lastUpdateTimestamp + stalenessThreshold;
    }

    /// @notice Returns time until data becomes stale (0 if already stale)
    function timeUntilStale() external view returns (uint256) {
        uint256 staleAt = lastUpdateTimestamp + stalenessThreshold;
        if (block.timestamp >= staleAt) return 0;
        return staleAt - block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @notice Updates the keeper address
    function setKeeper(address _newKeeper) external onlyOwner {
        if (_newKeeper == address(0)) revert ZeroAddress();
        emit KeeperUpdated(keeper, _newKeeper);
        keeper = _newKeeper;
    }

    /// @notice Updates the staleness threshold
    function setStalenessThreshold(uint256 _newThreshold) external onlyOwner {
        if (_newThreshold < 1 hours) revert StalenessThresholdTooLow();
        emit StalenessThresholdUpdated(stalenessThreshold, _newThreshold);
        stalenessThreshold = _newThreshold;
    }

    /// @notice Updates the EMA alpha factor
    function setEmaAlpha(uint8 _newAlpha) external onlyOwner {
        emit EmaAlphaUpdated(emaAlpha, _newAlpha);
        emaAlpha = _newAlpha;
    }

    /// @notice Transfers ownership
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        owner = _newOwner;
    }
}
