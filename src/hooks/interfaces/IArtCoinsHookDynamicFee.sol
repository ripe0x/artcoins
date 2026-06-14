// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IArtCoinsHookDynamicFee
/// @notice Interface for the dynamic-fee hook variant.
interface IArtCoinsHookDynamicFee {
    /// @notice Reverts when the configured base fee is below `MIN_BASE_FEE`.
    error BaseFeeTooLow();
    /// @notice Reverts when the configured max LP fee exceeds `MAX_LP_FEE`.
    error MaxLpFeeTooHigh();
    /// @notice Reverts when the base fee exceeds the max LP fee.
    error BaseFeeGreaterThanMaxLpFee();

    /// @notice Emitted when a pool is initialized with dynamic fee parameters.
    event PoolInitialized(
        PoolId poolId,
        uint24 baseFee,
        uint24 maxLpFee,
        uint256 referenceTickFilterPeriod,
        uint256 resetPeriod,
        int24 resetTickFilter,
        uint256 feeControlNumerator,
        uint24 decayFilterBps
    );

    /// @notice Emitted with the simulated pre/post tick used when computing the dynamic fee.
    /// @param beforeTick Tick before the swap.
    /// @param afterTick Estimated tick after the swap.
    event EstimatedTickDifference(int24 beforeTick, int24 afterTick);

    /// @notice Pool-level dynamic fee configuration.
    /// @param baseFee Floor LP fee.
    /// @param maxLpFee Cap LP fee.
    /// @param referenceTickFilterPeriod Time before the reference tick is reset.
    /// @param resetPeriod Time before stored volatility is fully reset.
    /// @param resetTickFilter Tick distance threshold used during the reset check.
    /// @param feeControlNumerator Slope of the volatility-to-fee curve.
    /// @param decayFilterBps Volatility decay applied at each filter period.
    struct PoolDynamicConfigVars {
        uint24 baseFee;
        uint24 maxLpFee;
        uint256 referenceTickFilterPeriod;
        uint256 resetPeriod;
        int24 resetTickFilter;
        uint256 feeControlNumerator;
        uint24 decayFilterBps;
    }

    /// @notice Live dynamic-fee state for a pool.
    /// @param referenceTick Reference tick used for volatility estimation.
    /// @param resetTick Tick at the start of the current reset window.
    /// @param resetTickTimestamp Timestamp the reset tick was set.
    /// @param lastSwapTimestamp Timestamp of the most recent swap.
    /// @param appliedVR Applied volatility reference.
    /// @param prevVA Previous volatility accumulation, used to derive the next VR.
    struct PoolDynamicFeeVars {
        int24 referenceTick;
        int24 resetTick;
        uint256 resetTickTimestamp;
        uint256 lastSwapTimestamp;
        uint24 appliedVR;
        uint24 prevVA;
    }

    /// @notice Returns the dynamic-fee configuration for a pool.
    /// @param poolId The pool id.
    /// @return The configuration struct.
    function poolConfigVars(PoolId poolId) external view returns (PoolDynamicConfigVars memory);
    /// @notice Returns the live dynamic-fee state for a pool.
    /// @param poolId The pool id.
    /// @return The state struct.
    function poolFeeVars(PoolId poolId) external view returns (PoolDynamicFeeVars memory);
}
