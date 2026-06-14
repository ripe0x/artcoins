// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsMevModuleBase} from "./IArtCoinsMevModuleBase.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IArtCoinsMevModule
/// @notice Interface for fee-dialing MEV-protection modules invoked on each
///         swap by the parent hook. Extends the shared {IArtCoinsMevModuleBase}
///         (one-time `initialize` + ERC-165) with the per-swap `beforeSwap`
///         callback the hook uses to apply anti-sniper LP fees.
/// @dev    `type(IArtCoinsMevModule).interfaceId == beforeSwap.selector`: the
///         inherited `initialize` / `supportsInterface` selectors are excluded
///         from `type(I).interfaceId` and live under
///         `type(IArtCoinsMevModuleBase).interfaceId` instead. The factory's
///         `setMevModule` gate therefore keys off the base id, not this one.
interface IArtCoinsMevModule is IArtCoinsMevModuleBase {
    /// @notice Reverts when pool interaction is attempted while locked.
    error PoolLocked();

    /// @notice Called by the hook before each swap to apply MEV protections.
    /// @param poolKey The pool key.
    /// @param swapParams The swap parameters.
    /// @param artCoinIsToken0 True if the ArtCoins token is token0.
    /// @param mevModuleSwapData Encoded swap-time data specific to the module.
    /// @return disableMevModule True if the hook should disable further MEV-module calls.
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bool artCoinIsToken0,
        bytes calldata mevModuleSwapData
    ) external returns (bool disableMevModule);
}
