// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsMevModule} from "../../interfaces/IArtCoinsMevModule.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IArtCoinsMevDescendingFees
/// @notice Interface for the descending-fee MEV module.
interface IArtCoinsMevDescendingFees is IArtCoinsMevModule {
    /// @notice Emitted when the decay period ends and the module disables itself.
    /// @param poolId The pool id.
    event DecayPeriodOver(PoolId poolId);
    /// @notice Emitted when the fee config is set for a pool.
    /// @param poolId The pool id.
    /// @param startingFee Starting fee.
    /// @param endingFee Ending fee.
    /// @param secondsToDecay Seconds over which the fee decays.
    event FeeConfigSet(PoolId poolId, uint24 startingFee, uint24 endingFee, uint256 secondsToDecay);

    /// @notice Reverts when the module is initialized for a pool that already has a config.
    error PoolAlreadyInitialized();
    /// @notice Reverts when the starting fee is zero.
    error StartingFeeMustBeGreaterThanZero();
    /// @notice Reverts when the starting fee is not greater than the ending fee.
    error StartingFeeMustBeGreaterThanEndingFee();
    /// @notice Reverts when the seconds-to-decay is zero.
    error TimeDecayMustBeGreaterThanZero();
    /// @notice Reverts when the bound hook is not a ArtCoinsHookV2.
    error OnlyArtCoinsHook();
    /// @notice Reverts when a swap occurs in the same second as deployment.
    error SameSecondAsDeployment();
    /// @notice Reverts when the seconds-to-decay exceeds the hook's max MEV delay.
    error TimeDecayLongerThanMaxMevDelay();
    /// @notice Reverts when the starting fee exceeds the hook's max MEV LP fee.
    error StartingFeeGreaterThanMaxLpFee();

    /// @notice Per-pool fee decay configuration.
    /// @param startingFee Fee at the start of the decay period.
    /// @param endingFee Fee at the end of the decay period.
    /// @param secondsToDecay Seconds over which the fee decays from start to end.
    struct FeeConfig {
        uint24 startingFee;
        uint24 endingFee;
        uint256 secondsToDecay;
    }

    /// @notice Returns the current fee for a pool.
    /// @param poolId The pool id.
    /// @return The fee.
    function getFee(PoolId poolId) external view returns (uint24);
}
