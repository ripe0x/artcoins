// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IBurnRouterV2
/// @notice Buys a v2 art coin with the native eth it holds and burns it. One
///         burn per block, price impact capped per call, keeper reward paid on
///         eth actually consumed.
interface IBurnRouterV2 {
    event BurnRouterInitialized(address indexed coin, PoolKey poolKey);
    event Burned(address indexed caller, uint256 ethIn, uint256 burned, uint256 reward);
    event RefundClaimed(uint256 amount);
    event MaxImpactBpsSet(uint16 oldBps, uint16 newBps);
    event MinProcessThresholdSet(uint96 oldThreshold, uint96 newThreshold);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotInitialized();
    error ZeroAddress();
    error InvalidPoolKey();
    error AlreadyBurnedThisBlock();
    error BelowMinThreshold(uint256 balance, uint256 minThreshold);
    error NothingToBurn();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error OutOfBounds(uint256 value, uint256 min, uint256 max);
    error CannotRescue(address token);

    /// @notice Owner, once. Binds the coin and its native eth pool.
    function initialize(address coin, PoolKey calldata poolKey) external;

    /// @notice Swaps eth for the coin (impact capped) and burns it; pays the caller a keeper reward.
    function processBurn(uint256 minOut) external returns (uint256 ethIn, uint256 burned);
    /// @notice As `processBurn` but settles the swap after taking (open tab).
    function processBurnOpenTab(uint256 minOut) external returns (uint256 ethIn, uint256 burned);
    /// @notice Pulls this router's skim refunds from the fee escrow.
    function claimRefund() external returns (uint256 amount);

    function coin() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
    function lastBurnBlock() external view returns (uint64);
    function maxImpactBps() external view returns (uint16);
    function minProcessThreshold() external view returns (uint96);

    /// @dev Within [Constants.PRICE_IMPACT_MIN, Constants.PRICE_IMPACT_MAX].
    function setMaxImpactBps(uint16 bps) external;
    /// @dev >= Constants.BURN_THRESHOLD_FLOOR.
    function setMinProcessThreshold(uint96 threshold) external;
    /// @notice Sends tokens other than the coin.
    function rescue(address token, address to, uint256 amount) external;
}
