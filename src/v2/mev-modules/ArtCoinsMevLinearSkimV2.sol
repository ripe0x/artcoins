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
///         BPS. The hook reads
///         `currentSkimBps` per swap and clamps the result itself (never below
///         the pool baseline, never above `MAX_SKIM_BPS`, expired at
///         `createdAt + MAX_MEV_WINDOW` whatever this module reports).
///
///         Trust model:
///         - No owner, no admin, no setters. The only state changing entry is
///           `initialize`, callable by the immutable `hook` only.
///         - Each pool is configured once, in the launch transaction, and the
///           config is frozen after that.
///         - The module never touches the lp fee. It has no `beforeSwap` and
///           does not answer the v1 `IArtCoinsMevModuleBase` or
///           `IArtCoinsMevModule` interface ids, so it can never be enabled as a
///           fee dialing module (review finding H9).
///         - The window bounds are `Constants.MIN_MEV_WINDOW` and
///           `Constants.MAX_MEV_WINDOW`, the same cap the hook enforces
///           (review finding H8).
///
///         Config encoding for `initialize`:
///         - `abi.encode(uint24 startingSkimBps, uint32 windowSeconds)` (64 bytes,
///           the frozen interface form). `endSkimBps` is 0, the hook clamps the
///           reported value up to the pool baseline, so the effective schedule
///           reaches the baseline before the window closes.
///         - `abi.encode(uint24 startingSkimBps, uint32 windowSeconds, uint24 endSkimBps)`
///           (96 bytes, additive). The hook passes the pool baseline as
///           `endSkimBps` so the decay reaches the baseline exactly at the end of
///           the window. `endSkimBps <= startingSkimBps` and
///           `endSkimBps <= Constants.MAX_BASELINE_SKIM_BPS`.
///         - empty bytes: `Constants.DEFAULT_START_SKIM_BPS`,
///           `Constants.DEFAULT_MEV_WINDOW`, `endSkimBps = 0`.
contract ArtCoinsMevLinearSkimV2 is IArtCoinsMevSkimV2 {
    /// @notice Per pool schedule, packed in one slot, frozen after `initialize`.
    struct SkimSchedule {
        uint24 startingSkimBps;
        uint24 endSkimBps;
        uint32 windowSeconds;
        uint40 startTime;
    }

    /// @inheritdoc IArtCoinsMevSkimV2
    address public immutable hook;

    mapping(PoolId => SkimSchedule) internal _schedule;

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

    /// @notice Additive. The frozen schedule of a pool (all zero if never initialized).
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
