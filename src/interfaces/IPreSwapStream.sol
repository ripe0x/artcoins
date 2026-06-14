// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IPreSwapStream
/// @notice Optional interface a fee recipient may implement to have the hook
///         flush its buffered balance onward at the START of each swap. If the
///         configured bounty recipient implements this, `ArtCoinsHookSkimFee`
///         calls `streamForward()` on it in `_beforeSwap` (via try/catch, so a
///         non-implementing recipient or a no-op return can never brick a
///         swap), letting that recipient advance its downstream balance from
///         PRIOR swaps' accrued fees on a per-swap cadence.
///
///         Implementations MUST be safe to call mid-`_beforeSwap`: no re-entry
///         into the PoolManager, and they must not revert in a way that bricks
///         the swap (return 0 for "nothing to do" / "rate-limited").
interface IPreSwapStream {
    /// @notice Forward buffered funds onward; returns the amount forwarded
    ///         (0 on a no-op).
    function streamForward() external returns (uint256 forwarded);
}
