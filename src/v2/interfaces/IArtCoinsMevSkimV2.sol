// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IConstantsBound} from "./IConstantsBound.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title  IArtCoinsMevSkimV2
/// @notice Anti sniper skim schedule, configured once per pool by the hook.
///         The factory accepts only modules answering `supportsInterface`
///         for `type(IArtCoinsMevSkimV2).interfaceId`.
interface IArtCoinsMevSkimV2 is IERC165, IConstantsBound {
    event MevConfigInitialized(
        PoolId indexed poolId, uint24 startingSkimBps, uint32 windowSeconds, uint40 startTime
    );

    error NotHook();
    error AlreadyInitialized();
    error InvalidConfig();
    /// @notice The window is outside [MIN_MEV_WINDOW, MAX_MEV_WINDOW], in seconds.
    error OutOfBounds(uint256 value, uint256 min, uint256 max);
    error StartingSkimTooHigh(uint24 startingSkimBps, uint24 max);

    /// @notice Hook only, once per pool. Checks the hook's `constantsHash()`.
    /// @param  config abi.encode(uint24 startingSkimBps, uint32 windowSeconds).
    function initialize(PoolId poolId, bytes calldata config) external;

    /// @notice Current anti sniper skim (BPS of volume) and whether the window is open.
    function currentSkimBps(PoolId poolId) external view returns (uint24 skimBps, bool active);

    /// @notice Timestamp at which the window closes (0 if never initialized).
    function windowEnd(PoolId poolId) external view returns (uint40);

    /// @notice The only hook allowed to initialize.
    function hook() external view returns (address);
}
