// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IArtCoinsHookStaticFee
/// @notice Interface for the static-fee hook variant.
interface IArtCoinsHookStaticFee {
    /// @notice Reverts when the configured `artCoinFee` exceeds `MAX_LP_FEE`.
    error ArtCoinsFeeTooHigh();
    /// @notice Reverts when the configured `pairedFee` exceeds `MAX_LP_FEE`.
    error PairedFeeTooHigh();

    /// @notice Emitted when a pool is initialized with its static fees.
    /// @param poolId The pool id.
    /// @param artCoinFee Fee charged when buying ArtCoins.
    /// @param pairedFee Fee charged when selling ArtCoins.
    event PoolInitialized(PoolId poolId, uint24 artCoinFee, uint24 pairedFee);

    /// @notice Static-fee configuration encoded in `feeData` at pool initialization.
    /// @param artCoinFee Fee for buying ArtCoins.
    /// @param pairedFee Fee for selling ArtCoins.
    struct PoolStaticConfigVars {
        uint24 artCoinFee;
        uint24 pairedFee;
    }

    /// @notice Fee applied when the art coin is the swap input (a sell), in pips.
    /// @param poolId The pool id.
    /// @return The fee.
    function artCoinFee(PoolId poolId) external view returns (uint24);
    /// @notice Fee applied when the paired currency is the swap input (a buy), in pips.
    /// @param poolId The pool id.
    /// @return The fee.
    function pairedFee(PoolId poolId) external view returns (uint24);
}
