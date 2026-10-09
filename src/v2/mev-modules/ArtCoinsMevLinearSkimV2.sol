// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsMevSkimV2} from "../interfaces/IArtCoinsMevSkimV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title  ArtCoinsMevLinearSkimV2
/// @notice Anti sniper skim schedule for v2 pools. The skim decays linearly
///         from `startingSkimBps` to `endSkimBps` over `windowSeconds`, in
///         bps of volume. The hook reads `currentSkimBps` per swap and clamps
///         the result to [pool baseline, `MAX_SKIM_BPS`]. The hook ends the
///         skim at `createdAt + MAX_MEV_WINDOW` whatever this module reports.
///
///         Trust model:
///         - Ownerless. The only state changing entry is `initialize`,
///           callable by the immutable `hook`.
///         - Each pool is configured once, in the launch transaction, and the
///           config is frozen after that.
///         - The module has no `beforeSwap` and does not set the lp fee. It
///           answers only the IArtCoinsMevSkimV2 erc-165 id.
///         - The window bounds are `Constants.MIN_MEV_WINDOW` and
///           `Constants.MAX_MEV_WINDOW`, the cap the hook also applies.
///
///         Config encoding for `initialize`:
///         - `abi.encode(uint24 startingSkimBps, uint32 windowSeconds)` (64 bytes).
///           `endSkimBps` is 0 and the hook clamps the reported value up to the
///           pool baseline, so the effective schedule reaches the baseline
///           before the window closes.
///         - `abi.encode(uint24 startingSkimBps, uint32 windowSeconds, uint24 endSkimBps)`
///           (96 bytes). The hook passes the pool baseline as
///           `endSkimBps` so the decay reaches the baseline exactly at the end of
///           the window. `endSkimBps <= startingSkimBps` and
///           `endSkimBps <= Constants.MAX_BASELINE_SKIM_BPS`.
///         - empty bytes: `Constants.DEFAULT_START_SKIM_BPS`,
///           `Constants.DEFAULT_MEV_WINDOW`, `endSkimBps = 0`.
contract ArtCoinsMevLinearSkimV2 is IArtCoinsMevSkimV2 {
    /// @notice Per pool schedule, packed in one slot, fixed after `initialize`.
    struct SkimSchedule {
        /// @dev Skim at `startTime`, bps of volume.
        uint24 startingSkimBps;
        /// @dev Skim at the end of the window, bps of volume.
        uint24 endSkimBps;
        /// @dev Window length, seconds.
        uint32 windowSeconds;
        /// @dev Block timestamp of `initialize`, seconds; 0 when not initialized.
        uint40 startTime;
    }

    /// @inheritdoc IArtCoinsMevSkimV2
    address public immutable hook;

    mapping(PoolId => SkimSchedule) internal _schedule;

    /// @param hook_ The only caller of `initialize`. Reverts with `InvalidConfig` when zero.
    constructor(address hook_) {
        if (hook_ == address(0)) revert InvalidConfig();
        hook = hook_;
    }

    /// @inheritdoc IArtCoinsMevSkimV2
    function initialize(PoolId poolId, bytes calldata config) external {
        if (msg.sender != hook) revert NotHook();
        if (_schedule[poolId].startTime != 0) revert AlreadyInitialized();
        _checkHookConstants();

        uint256 start;
        uint256 window;
        uint256 end;
        uint256 len = config.length;
        if (len == 0) {
            start = Constants.DEFAULT_START_SKIM_BPS;
            window = Constants.DEFAULT_MEV_WINDOW;
        } else if (len == 64 || len == 96) {
            (start, window) = abi.decode(config, (uint256, uint256));
            if (len == 96) {
                (,, end) = abi.decode(config, (uint256, uint256, uint256));
            }
        } else {
            revert InvalidConfig();
        }

        if (window < Constants.MIN_MEV_WINDOW || window > Constants.MAX_MEV_WINDOW) {
            revert OutOfBounds(window, Constants.MIN_MEV_WINDOW, Constants.MAX_MEV_WINDOW);
        }
        if (start > Constants.MAX_SKIM_BPS) {
            revert StartingSkimTooHigh(
                uint24(start > type(uint24).max ? type(uint24).max : start), Constants.MAX_SKIM_BPS
            );
        }
        if (end > start || end > Constants.MAX_BASELINE_SKIM_BPS) revert InvalidConfig();

        uint40 startTime = uint40(block.timestamp);
        _schedule[poolId] = SkimSchedule({
            startingSkimBps: uint24(start),
            endSkimBps: uint24(end),
            windowSeconds: uint32(window),
            startTime: startTime
        });

        emit MevConfigInitialized(poolId, uint24(start), uint24(end), uint32(window), startTime);
    }

    /// @inheritdoc IArtCoinsMevSkimV2
    function currentSkimBps(PoolId poolId) external view returns (uint24 skimBps, bool active) {
        SkimSchedule memory s = _schedule[poolId];
        if (s.startTime == 0) return (0, false);

        uint256 elapsed = block.timestamp - s.startTime;
        if (elapsed >= s.windowSeconds) return (s.endSkimBps, false);

        uint256 range = uint256(s.startingSkimBps) - s.endSkimBps;
        skimBps = uint24(uint256(s.startingSkimBps) - (range * elapsed) / s.windowSeconds);
        active = true;
    }

    /// @inheritdoc IArtCoinsMevSkimV2
    function windowEnd(PoolId poolId) external view returns (uint40) {
        SkimSchedule memory s = _schedule[poolId];
        if (s.startTime == 0) return 0;
        return s.startTime + s.windowSeconds;
    }

    /// @notice The stored schedule of a pool (all zero if never initialized).
    /// @param poolId Pool id.
    /// @return The schedule.
    function schedule(PoolId poolId) external view returns (SkimSchedule memory) {
        return _schedule[poolId];
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsMevSkimV2).interfaceId
            || interfaceId == type(IConstantsBound).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev The hook must have been built against the same `Constants` set.
    function _checkHookConstants() private view {
        (bool ok, bytes memory ret) =
            hook.staticcall(abi.encodeCall(IConstantsBound.constantsHash, ()));
        if (!ok || ret.length != 32 || abi.decode(ret, (bytes32)) != Constants.hash()) {
            revert ConstantsMismatch(hook);
        }
    }
}
