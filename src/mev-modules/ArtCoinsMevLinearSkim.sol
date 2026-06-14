// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SkimFeeConstants} from "../hooks/libraries/SkimFeeConstants.sol";
import {IArtCoinsMevModuleBase} from "../interfaces/IArtCoinsMevModuleBase.sol";
import {IArtCoinsMevSkim} from "./interfaces/IArtCoinsMevSkim.sol";

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  ArtCoinsMevLinearSkim
/// @notice Anti-sniper MEV module that DRIVES A HOOK-LEVEL SKIM rather than
///         dialing the LP fee. Parallel to `ArtCoinsMevLinearFees`, but the
///         consuming hook is `ArtCoinsHookSkimFee` (which reads `currentSkimBps`
///         and `operational` from this contract directly to compute the
///         per-swap skim claim).
///
///         Decay is linear from `startingBps` to `endingBps` over
///         `durationSeconds`. `endingBps` should equal the hook's per-pool
///         `baselineSkimBps` — after expiry, `currentSkimBps` returns
///         `endingBps` exactly (the baseline) and the anti-sniper extra
///         computed by the hook becomes 0.
///
///         The module's anti-sniper lifetime is owned by ONE model: the linear
///         decay window (`startTime + durationSeconds`), exposed read-only via
///         `IArtCoinsMevSkim` (`currentSkimBps` for the per-swap amount,
///         `operational` for the public-LP lock). `ArtCoinsHookSkimFee` reads
///         these directly and does NOT route this module through the base
///         hook's generic per-swap `_runMevModule` plumbing.
///
///         Registration and init come from the shared
///         {IArtCoinsMevModuleBase} (which `IArtCoinsMevSkim` extends):
///         `ArtCoinsFactory.setMevModule` gates on
///         `supportsInterface(type(IArtCoinsMevModuleBase).interfaceId)` and the
///         hook's `initializeMevModule` calls `initialize` through that base.
///         This module is NOT an `IArtCoinsMevModule` — it has no per-swap
///         `beforeSwap` callback at all. The hook never dials the LP fee for
///         skim pools; it takes the skim as a `BeforeSwapDelta` /
///         `AfterSwapDelta` claim computed from `currentSkimBps`.
contract ArtCoinsMevLinearSkim is IArtCoinsMevSkim {
    using PoolIdLibrary for PoolKey;

    /// @notice Reverts on invalid init data, re-initialization, or out-of-range parameters.
    error InvalidConfig();

    /// @notice Per-pool decay configuration.
    /// @param startingBps Skim bps at launch (capped at MAX_SKIM_BPS).
    /// @param endingBps Skim bps after decay completes (must equal the hook's baseline).
    /// @param durationSeconds Decay duration in seconds.
    /// @param startTime Block timestamp when the pool was initialized with this module.
    struct SkimConfig {
        uint24 startingBps;
        uint24 endingBps;
        uint32 durationSeconds;
        uint256 startTime;
    }

    /// @notice Maximum permitted skim bps (90%), sourced from the shared
    ///         `SkimFeeConstants` so the module, hook, and init-lib can never
    ///         silently diverge on the ceiling.
    uint24 public constant MAX_SKIM_BPS = SkimFeeConstants.MAX_SKIM_BPS;
    /// @notice Default starting bps (~69% total trader cost at t=0 with the
    ///         1% LP fee).
    uint24 public constant DEFAULT_STARTING_BPS = 68_690;
    /// @notice Default ending bps (5% — the PC baseline).
    uint24 public constant DEFAULT_ENDING_BPS = 5000;
    /// @notice Default decay duration (69 minutes).
    uint32 public constant DEFAULT_DURATION = 69 minutes;
    /// @notice Minimum allowed decay duration.
    uint32 public constant MIN_DURATION = 1 minutes;
    /// @notice Maximum allowed decay duration.
    uint32 public constant MAX_DURATION = 180 minutes;

    /// @notice Skim config for each pool id.
    mapping(PoolId => SkimConfig) public skimConfigs;

    /// @dev Restricts a function to the pool's hook.
    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) {
            revert OnlyHook();
        }
        _;
    }

    /// @notice Called by the hook during pool initialization.
    /// @dev ABI-encoded `(uint24 startingBps, uint24 endingBps, uint32 durationSeconds)`
    ///      or empty bytes for defaults. `endingBps` must be < `startingBps`
    ///      and ≤ `MAX_SKIM_BPS`; `endingBps` should match the hook's
    ///      per-pool `baselineSkimBps` (the deployer is responsible for this
    ///      pairing — a mismatch only changes the post-window steady-state
    ///      skim, doesn't break safety).
    /// @param poolKey The pool being initialized.
    /// @param mevModuleInitData ABI-encoded config or empty for defaults.
    function initialize(PoolKey calldata poolKey, bytes calldata mevModuleInitData)
        external
        onlyHook(poolKey)
    {
        PoolId id = poolKey.toId();
        if (skimConfigs[id].startTime != 0) {
            revert InvalidConfig();
        }

        SkimConfig memory cfg;
        if (mevModuleInitData.length == 0) {
            cfg = SkimConfig({
                startingBps: DEFAULT_STARTING_BPS,
                endingBps: DEFAULT_ENDING_BPS,
                durationSeconds: DEFAULT_DURATION,
                startTime: block.timestamp
            });
        } else {
            (uint24 startingBps, uint24 endingBps, uint32 durationSeconds) =
                abi.decode(mevModuleInitData, (uint24, uint24, uint32));

            if (startingBps > MAX_SKIM_BPS) revert InvalidConfig();
            if (endingBps >= startingBps) revert InvalidConfig();
            if (durationSeconds < MIN_DURATION || durationSeconds > MAX_DURATION) {
                revert InvalidConfig();
            }

            cfg = SkimConfig({
                startingBps: startingBps,
                endingBps: endingBps,
                durationSeconds: durationSeconds,
                startTime: block.timestamp
            });
        }

        skimConfigs[id] = cfg;
    }

    /// @inheritdoc IArtCoinsMevSkim
    function currentSkimBps(PoolId poolId) external view returns (uint24) {
        SkimConfig memory cfg = skimConfigs[poolId];
        if (cfg.startTime == 0) return 0;

        uint256 elapsed = block.timestamp - cfg.startTime;
        if (elapsed >= cfg.durationSeconds) return cfg.endingBps;

        uint24 range = cfg.startingBps - cfg.endingBps;
        return cfg.startingBps - uint24(uint256(range) * elapsed / cfg.durationSeconds);
    }

    /// @inheritdoc IArtCoinsMevSkim
    function operational(PoolId poolId) external view returns (bool) {
        SkimConfig memory cfg = skimConfigs[poolId];
        if (cfg.startTime == 0) return false;
        return block.timestamp < cfg.startTime + cfg.durationSeconds;
    }

    /// @notice Seconds remaining in the decay window for a pool.
    /// @param poolKey The pool key.
    /// @return Seconds until decay completes (0 if already complete or uninitialized).
    function getTimeRemaining(PoolKey calldata poolKey) external view returns (uint256) {
        SkimConfig memory cfg = skimConfigs[poolKey.toId()];
        if (cfg.startTime == 0) return 0;
        uint256 elapsed = block.timestamp - cfg.startTime;
        if (elapsed >= cfg.durationSeconds) return 0;
        return cfg.durationSeconds - elapsed;
    }

    /// @inheritdoc IArtCoinsMevModuleBase
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsMevModuleBase).interfaceId
            || interfaceId == type(IArtCoinsMevSkim).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}
