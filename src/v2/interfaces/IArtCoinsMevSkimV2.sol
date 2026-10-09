// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IConstantsBound} from "./IConstantsBound.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title  IArtCoinsMevSkimV2
/// @notice Anti sniper skim schedule, configured once per pool by the hook.
///         The factory accepts only modules answering `supportsInterface`
///         for `type(IArtCoinsMevSkimV2).interfaceId`.
///
///         Units: skim rates are bps of swap volume (1/10,000); durations and
///         timestamps are seconds.
interface IArtCoinsMevSkimV2 is IERC165, IConstantsBound {
    /// @notice The pool's anti sniper schedule was stored. It decays linearly
    ///         from `startingSkimBps` to `endSkimBps` over `windowSeconds`,
    ///         starting at `startTime`, and is fixed afterwards.
    /// @param poolId Pool id.
    /// @param startingSkimBps Skim at `startTime`, bps of volume.
    /// @param endSkimBps Skim at the end of the window, bps of volume.
    /// @param windowSeconds Window length, seconds.
    /// @param startTime Block timestamp of `initialize`, seconds.
    event MevConfigInitialized(
        PoolId indexed poolId,
        uint24 startingSkimBps,
        uint24 endSkimBps,
        uint32 windowSeconds,
        uint40 startTime
    );

    /// @notice The caller of `initialize` is not the module's hook.
    error NotHook();

    /// @notice The pool's schedule was already stored.
    error AlreadyInitialized();

    /// @notice The module config has an unsupported length, `endSkimBps` exceeds
    ///         `startingSkimBps` or Constants.MAX_BASELINE_SKIM_BPS, or the hook
    ///         address given at construction is zero.
    error InvalidConfig();

    /// @notice The window is outside [Constants.MIN_MEV_WINDOW, Constants.MAX_MEV_WINDOW], in seconds.
    /// @param value The rejected window, seconds.
    /// @param min Lower bound, seconds.
    /// @param max Upper bound, seconds.
    error OutOfBounds(uint256 value, uint256 min, uint256 max);

    /// @notice `startingSkimBps` exceeds Constants.MAX_SKIM_BPS.
    /// @param startingSkimBps The rejected value, bps, saturated at the uint24 maximum.
    /// @param max Upper bound, bps.
    error StartingSkimTooHigh(uint24 startingSkimBps, uint24 max);

    /// @notice Stores the pool's schedule. Callable by the module's hook only, once per pool.
    /// @dev    `config` is empty for the Constants defaults,
    ///         `abi.encode(uint24 startingSkimBps, uint32 windowSeconds)` (64 bytes,
    ///         endSkimBps 0), or
    ///         `abi.encode(uint24 startingSkimBps, uint32 windowSeconds, uint24 endSkimBps)`
    ///         (96 bytes). The hook's `constantsHash()` must match this build's.
    ///         Reverts with `NotHook`, `AlreadyInitialized`, `ConstantsMismatch`,
    ///         `InvalidConfig`, `OutOfBounds` or `StartingSkimTooHigh`.
    /// @param poolId Pool id.
    /// @param config Schedule encoding described above.
    function initialize(PoolId poolId, bytes calldata config) external;

    /// @notice Current anti sniper skim and whether the window is open.
    /// @dev    Returns (0, false) before `initialize` and (endSkimBps, false)
    ///         after the window closes.
    /// @param poolId Pool id.
    /// @return skimBps Skim at the current block timestamp, bps of volume.
    /// @return active True while the window is open.
    function currentSkimBps(PoolId poolId) external view returns (uint24 skimBps, bool active);

    /// @notice Timestamp at which the window closes.
    /// @param poolId Pool id.
    /// @return The close timestamp in seconds; 0 before `initialize`.
    function windowEnd(PoolId poolId) external view returns (uint40);

    /// @notice The hook that may call `initialize`.
    /// @return The hook address.
    function hook() external view returns (address);
}
