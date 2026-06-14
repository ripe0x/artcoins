// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsHookV2} from "./ArtCoinsHookV2.sol";

import {IArtCoinsHookDynamicFee} from "../interfaces/IArtCoinsHookDynamicFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ArtCoinsHookDynamicFeeV2
/// @notice Hook variant whose LP fee scales quadratically with realized tick volatility,
///         estimated by simulating the candidate swap and comparing to a periodically-reset
///         reference tick.
contract ArtCoinsHookDynamicFeeV2 is ArtCoinsHookV2, IArtCoinsHookDynamicFee {
    using StateLibrary for IPoolManager;

    /// @notice Basis-point denominator (10,000 = 100%).
    uint24 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Minimum allowed base fee (0.25%).
    uint24 public constant MIN_BASE_FEE = 2500;
    /// @notice Maximum allowed volatility decay filter in BPS.
    uint256 public constant MAX_DECAY_FILTER_BPS = 30_000;
    /// @notice Denominator used in the variable-fee equation.
    uint256 public constant FEE_CONTROL_DENOMINATOR = 10_000_000_000;

    mapping(PoolId => PoolDynamicFeeVars) internal _poolFeeVars;
    mapping(PoolId => PoolDynamicConfigVars) internal _poolConfigVars;

    /// @notice Reverts with the simulated tick to bubble it out of `simulateSwap`.
    error TickReturned(int24 tick);

    /// @param _poolManager Uniswap v4 pool manager.
    /// @param _factory The ArtCoins factory.
    /// @param _poolExtensionAllowlist Pool-extension allowlist contract.
    /// @param _weth WETH address.
    constructor(
        address _poolManager,
        address _factory,
        address _poolExtensionAllowlist,
        address _weth
    ) ArtCoinsHookV2(_poolManager, _factory, _poolExtensionAllowlist, _weth) {}

    /// @notice Returns the dynamic fee configuration for a pool.
    /// @param poolId The pool id.
    /// @return The configuration struct.
    function poolConfigVars(PoolId poolId) external view returns (PoolDynamicConfigVars memory) {
        return _poolConfigVars[poolId];
    }

    /// @notice Returns the live dynamic fee state for a pool.
    /// @param poolId The pool id.
    /// @return The state struct.
    function poolFeeVars(PoolId poolId) external view returns (PoolDynamicFeeVars memory) {
        return _poolFeeVars[poolId];
    }

    function _initializeFeeData(PoolKey memory poolKey, bytes memory feeData) internal override {
        PoolDynamicConfigVars memory __poolConfigVars = abi.decode(feeData, (PoolDynamicConfigVars));

        if (__poolConfigVars.baseFee < MIN_BASE_FEE) {
            revert BaseFeeTooLow();
        }

        if (__poolConfigVars.maxLpFee > MAX_LP_FEE) {
            revert MaxLpFeeTooHigh();
        }

        if (__poolConfigVars.baseFee > __poolConfigVars.maxLpFee) {
            revert BaseFeeGreaterThanMaxLpFee();
        }

        emit PoolInitialized({
            poolId: poolKey.toId(),
            baseFee: __poolConfigVars.baseFee,
            maxLpFee: __poolConfigVars.maxLpFee,
            referenceTickFilterPeriod: __poolConfigVars.referenceTickFilterPeriod,
            feeControlNumerator: __poolConfigVars.feeControlNumerator,
            decayFilterBps: __poolConfigVars.decayFilterBps,
            resetPeriod: __poolConfigVars.resetPeriod,
            resetTickFilter: __poolConfigVars.resetTickFilter
        });

        _poolConfigVars[poolKey.toId()] = __poolConfigVars;
    }

    /// @dev Computes the dynamic LP fee from estimated post-swap volatility and applies it.
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        override
    {
        uint256 volAccumulator = _getVolatilityAccumulator(poolKey, swapParams);
        uint24 lpFee = _getLpFee(volAccumulator, poolKey.toId());
        _setProtocolFee(lpFee);

        IPoolManager(poolManager).updateDynamicLPFee(poolKey, lpFee);
    }

    function _getLpFee(uint256 volAccumulator, PoolId poolId) internal returns (uint24 lpFee) {
        PoolDynamicConfigVars storage _poolConfigVars_ = _poolConfigVars[poolId];
        uint256 variableFee = uint256(_poolConfigVars_.feeControlNumerator) * (volAccumulator ** 2)
            / FEE_CONTROL_DENOMINATOR;

        uint256 fee = variableFee + _poolConfigVars_.baseFee;
        fee = fee > _poolConfigVars_.maxLpFee ? _poolConfigVars_.maxLpFee : fee;

        return uint24(fee);
    }

    function _getVolatilityAccumulator(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams
    ) internal returns (uint24 volatilityAccumulator) {
        PoolId poolId = poolKey.toId();
        PoolDynamicFeeVars storage poolFVars = _poolFeeVars[poolId];
        PoolDynamicConfigVars storage poolCVars = _poolConfigVars[poolId];
        // grab the tick before the swap
        (, int24 tickBefore,,) = poolManager.getSlot0(poolId);

        // reset the reference tick if the tick filter period has passed
        if (poolFVars.lastSwapTimestamp + poolCVars.referenceTickFilterPeriod < block.timestamp) {
            // set the reference tick to the tick before the swap
            poolFVars.referenceTick = tickBefore;

            // set the reset tick to the tick before the swap and record the reset timestamp
            poolFVars.resetTick = tickBefore;
            poolFVars.resetTickTimestamp = block.timestamp;

            // if the reset period has NOT passed but the tick filter period has, trigger
            // the volatility decay process
            if (poolFVars.lastSwapTimestamp + poolCVars.resetPeriod > block.timestamp) {
                // do math in uint256 to avoid overflow
                uint256 appliedVR = (uint256(poolFVars.prevVA) * uint256(poolCVars.decayFilterBps))
                    / BPS_DENOMINATOR;
                if (appliedVR > type(uint24).max) {
                    poolFVars.appliedVR = type(uint24).max;
                } else {
                    poolFVars.appliedVR = uint24(appliedVR);
                }
            } else {
                poolFVars.appliedVR = 0;
            }

            // set estimated fee for getting simulation closer to actual result
            uint24 approxLPFee = _getLpFee(poolFVars.appliedVR, poolId);
            _setProtocolFee(approxLPFee);
            IPoolManager(poolManager).updateDynamicLPFee(poolKey, approxLPFee);
        } // if we didn't just reset, check if the reset period has passed
        else if (poolFVars.resetTickTimestamp + poolCVars.resetPeriod < block.timestamp) {
            // check if the tick difference is greater than the reset tick filter
            int24 resetTickDifference = tickBefore > poolFVars.resetTick
                ? tickBefore - poolFVars.resetTick
                : poolFVars.resetTick - tickBefore;

            if (resetTickDifference > poolCVars.resetTickFilter) {
                // the tick difference is large enough, don't kill the reference tick
                poolFVars.resetTick = tickBefore;
                poolFVars.resetTickTimestamp = block.timestamp;
            } else {
                // the tick difference is not large enough, clear the stored volatility
                poolFVars.referenceTick = tickBefore;
                poolFVars.resetTick = tickBefore;
                poolFVars.resetTickTimestamp = block.timestamp;
                poolFVars.appliedVR = 0;

                // clear out fee for simulation
                uint24 approxLPFee = poolCVars.baseFee;
                _setProtocolFee(approxLPFee);
                IPoolManager(poolManager).updateDynamicLPFee(poolKey, approxLPFee);
            }
        }
        // update the reference tick timestamp
        poolFVars.lastSwapTimestamp = block.timestamp;

        // find the tick after via simulation
        int24 tickAfter = _getTicks(poolKey, swapParams);

        // calculate the tick difference to use in the volatility equation
        uint24 tickDifference = (poolFVars.referenceTick - tickAfter) > 0
            ? uint24(poolFVars.referenceTick - tickAfter)
            : uint24(tickAfter - poolFVars.referenceTick);

        // apply volatility decay
        // do math in uint256 to avoid overflow
        uint256 volatilityAccumulator_ = (uint256(tickDifference) + uint256(poolFVars.appliedVR));
        if (volatilityAccumulator_ > type(uint24).max) {
            volatilityAccumulator = type(uint24).max;
        } else {
            volatilityAccumulator = uint24(volatilityAccumulator_);
        }
        poolFVars.prevVA = volatilityAccumulator;

        emit EstimatedTickDifference(tickBefore, tickAfter);
    }

    function _getTicks(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        returns (int24 tickAfter)
    {
        // simulate swap to get the estimated end tick
        //
        // note: this is not going to exactly match the result tick,
        // if we apply a fee change based on this outcome, the resulting
        // tick of the swap could be shifted
        try this.simulateSwap(poolKey, swapParams) {
            revert("simulate swap should fail");
        } catch (bytes memory reason) {
            // Decode the selector (first 4 bytes)
            bytes4 selector = bytes4(reason);

            if (selector != TickReturned.selector) {
                revert("returned selector should be TickReturned");
            }

            // Decode the uint24 value (assuming it's at the end)
            assembly {
                // If we're looking at the last 32 bytes, we need to position our pointer
                // reason + 32 (to skip length) + reason.length - 32 (to get to the last 32 bytes)
                let lastWordPtr := add(add(reason, 32), sub(mload(reason), 32))

                // For uint24, we only need the last 3 bytes of the last word
                // This assumes the uint24 is right-aligned in the last word
                let lastWord := mload(lastWordPtr)

                // Mask to get only the last 3 bytes (24 bits)
                tickAfter := and(lastWord, 0xFFFFFF)
            }
        }
    }

    /// @notice Simulates a swap and reverts with the post-swap tick — used internally to estimate volatility.
    /// @dev Self-call only; reverts with `TickReturned`.
    /// @param poolKey The pool key.
    /// @param swapParams The candidate swap params.
    function simulateSwap(PoolKey calldata poolKey, IPoolManager.SwapParams memory swapParams)
        external
    {
        if (msg.sender != address(this)) {
            revert("simulateSwap can only be called by the hook");
        }

        // apply the protocol fee adjustments to have simulation closer to actual result
        bool token0IsArtCoins = artCoinIsToken0[poolKey.toId()];
        bool swappingForArtCoins = swapParams.zeroForOne != token0IsArtCoins;
        bool isExactInput = swapParams.amountSpecified < 0;
        if (isExactInput && swappingForArtCoins) {
            uint128 scaledProtocolFee = uint128(protocolFee) * 1e18 / (1_000_000 + protocolFee);
            int128 fee = int128(swapParams.amountSpecified * -int128(scaledProtocolFee) / 1e18);
            swapParams.amountSpecified = swapParams.amountSpecified + fee;
        }
        if (!isExactInput && !swappingForArtCoins) {
            uint128 scaledProtocolFee = uint128(protocolFee) * 1e18 / (1_000_000 - protocolFee);
            int128 fee = int128(swapParams.amountSpecified * int128(scaledProtocolFee) / 1e18);
            swapParams.amountSpecified = swapParams.amountSpecified + fee;
        }

        // run the swap
        poolManager.swap(poolKey, swapParams, abi.encode());

        // get the tick after the swap
        (, int24 tickAfter,,) = poolManager.getSlot0(poolKey.toId());

        // return the tick post-swap
        revert TickReturned(tickAfter);
    }
}
