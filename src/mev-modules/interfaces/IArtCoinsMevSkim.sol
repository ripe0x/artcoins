// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsMevModuleBase} from "../../interfaces/IArtCoinsMevModuleBase.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title  IArtCoinsMevSkim
/// @notice Interface implemented by MEV modules that drive a hook-level skim
///         (e.g. `ArtCoinsMevLinearSkim`), consumed by `ArtCoinsHookSkimFee`.
///         Extends the shared {IArtCoinsMevModuleBase} (one-time `initialize` +
///         ERC-165) with two read-only views that let the hook compute how much
///         quote-side skim to claim on the current swap and whether the
///         anti-sniper window is still open.
/// @dev    A skim module is deliberately NOT an {IArtCoinsMevModule}: it exposes
///         no per-swap `beforeSwap` callback. `ArtCoinsHookSkimFee` reads
///         `currentSkimBps` / `operational` directly and never routes the module
///         through the base hook's generic `_runMevModule` plumbing.
interface IArtCoinsMevSkim is IArtCoinsMevModuleBase {
    /// @notice Current total skim bps the hook should take on this swap.
    /// @dev    Includes the baseline skim. The hook subtracts the per-pool
    ///         `baselineSkimBps` from this value to compute the anti-sniper
    ///         extra slice. The hook is expected to clamp to its own
    ///         `MAX_SKIM_BPS` before use, so a misbehaving module can never
    ///         push effective fee past the hook's cap.
    /// @param  poolId The pool id.
    /// @return Total skim in basis points (10_000 = 100%).
    function currentSkimBps(PoolId poolId) external view returns (uint24);

    /// @notice Whether this module's decay window is still active.
    /// @dev    The hook ALSO uses this to gate `_beforeAddLiquidity` — public
    ///         LPs are blocked while the module is operational. Returns false
    ///         before init and after the configured duration elapses.
    /// @param  poolId The pool id.
    /// @return True while the decay window is open.
    function operational(PoolId poolId) external view returns (bool);
}
