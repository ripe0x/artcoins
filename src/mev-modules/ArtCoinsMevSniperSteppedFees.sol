// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsHook} from "../interfaces/IArtCoinsHook.sol";
import {IArtCoinsMevModule} from "../interfaces/IArtCoinsMevModule.sol";
import {IArtCoinsMevModuleBase} from "../interfaces/IArtCoinsMevModuleBase.sol";

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ArtCoinsMevSniperSteppedFees
/// @notice Anti-sniper MEV module that signals an "extra" fee on top of the
///         pool's base LP fee for each step in a stepped schedule. The hook's
///         sniper-extra path collects the extra from the swap's input
///         currency and routes it to the per-pool `sniperFeeRecipient`
///         (typically the LAYER BurnRouter), bypassing the normal locker
///         reward split.
///
/// @dev    Schedule entries are TOTAL trader-paid fees (matching the
///         user-facing brief: "minute 0 fee is 50%"). The module derives the
///         per-step extra as `totalPpm - basePpm` and calls the hook's
///         `mevModuleSetSniperFee(poolKey, extraPpm)` accordingly.
///
///         The pool's actual LP fee is NEVER changed by this module — the
///         locker reward split keeps receiving only the pool's configured
///         base fee throughout the sniper window.
///
///         Default LAYER schedule:
///           basePpm = 10_000 (1.00%)
///           step 0:  0–60s     500_000 ppm total (extra 490_000)
///           step 1:  60–180s   250_000 ppm total (extra 240_000)
///           step 2:  180–300s  150_000 ppm total (extra 140_000)
///           step 3:  300–600s   70_000 ppm total (extra  60_000)
///           step 4:  600–900s   30_000 ppm total (extra  20_000)
///           after 900s: disabled (normal pool fee resumes; no extra)
///
///         Validation:
///           - schedule.length ∈ [1, 16]
///           - feePpm strictly monotonically decreasing
///           - feePpm[0] ≤ MAX_FEE (990_000)
///           - basePpm < feePpm[last]  (every step has a positive extra)
///           - sum(durationSec) ≤ hook.MAX_MEV_MODULE_DELAY() (15m for LAYER hook)
///           - sum(durationSec) ≤ 7200 (2h absolute hard cap)
///           - each durationSec > 0
contract ArtCoinsMevSniperSteppedFees is IArtCoinsMevModule {
    using PoolIdLibrary for PoolKey;

    /// @notice Reverts on invalid init data, re-initialization, or out-of-range parameters.
    error InvalidConfig();

    /// @notice One step in the schedule.
    /// @param durationSec Length of this step in seconds.
    /// @param feePpm TOTAL trader-paid fee active during this step, in ppm
    ///        (1e6 = 100%). Must be > basePpm.
    struct Step {
        uint32 durationSec;
        uint24 feePpm;
    }

    /// @notice Per-pool config.
    /// @param startTime When the schedule began (block.timestamp at init).
    /// @param totalDuration Sum of all step durations.
    /// @param basePpm The pool's base LP fee at the time of init. Used to
    ///        compute each step's extra as `step.feePpm - basePpm`.
    /// @param steps Ordered schedule (max 16 entries).
    struct ScheduleConfig {
        uint64 startTime;
        uint32 totalDuration;
        uint24 basePpm;
        Step[] steps;
    }

    /// @notice Maximum allowed initial total fee (99%).
    uint24 public constant MAX_FEE = 990_000;
    /// @notice Maximum number of steps in a schedule.
    uint256 public constant MAX_STEPS = 16;
    /// @notice Maximum total duration across all steps (2 hours).
    uint32 public constant MAX_TOTAL_DURATION = 2 hours;

    /// @notice Per-pool configuration.
    mapping(PoolId => ScheduleConfig) internal _configs;

    /// @dev Restricts a function to the pool's hook.
    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) revert OnlyHook();
        _;
    }

    /// @inheritdoc IArtCoinsMevModuleBase
    /// @dev `mevModuleInitData = abi.encode(Step[] schedule, uint24 basePpm)`.
    ///       Empty bytes is rejected — the deployer must explicitly supply a
    ///       schedule and base.
    function initialize(PoolKey calldata poolKey, bytes calldata mevModuleInitData)
        external
        onlyHook(poolKey)
    {
        ScheduleConfig storage config = _configs[poolKey.toId()];
        if (config.startTime != 0) revert InvalidConfig();
        if (mevModuleInitData.length == 0) revert InvalidConfig();

        (Step[] memory schedule, uint24 basePpm) = abi.decode(mevModuleInitData, (Step[], uint24));

        uint256 n = schedule.length;
        if (n == 0 || n > MAX_STEPS) revert InvalidConfig();

        if (schedule[0].feePpm > MAX_FEE) revert InvalidConfig();

        // Validate monotonic decay + nonzero durations + cap on totalDuration.
        uint256 total = 0;
        for (uint256 i = 0; i < n; i++) {
            if (schedule[i].durationSec == 0) revert InvalidConfig();
            total += schedule[i].durationSec;
            if (i + 1 < n) {
                if (schedule[i].feePpm <= schedule[i + 1].feePpm) revert InvalidConfig();
            }
        }
        if (total > MAX_TOTAL_DURATION) revert InvalidConfig();
        if (total > IArtCoinsHook(address(poolKey.hooks)).MAX_MEV_MODULE_DELAY()) {
            revert InvalidConfig();
        }

        // Every step must have a positive "extra" — otherwise this module
        // would no-op for that step and the spec ("100% of extra to burn")
        // wouldn't be testable. Use the LAST (smallest) step as the gate;
        // monotonic decay above guarantees all earlier steps qualify too.
        if (basePpm >= schedule[n - 1].feePpm) revert InvalidConfig();

        config.startTime = uint64(block.timestamp);
        config.totalDuration = uint32(total);
        config.basePpm = basePpm;
        for (uint256 i = 0; i < n; i++) {
            config.steps.push(schedule[i]);
        }
    }

    /// @inheritdoc IArtCoinsMevModule
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata,
        bool,
        bytes calldata
    ) external onlyHook(poolKey) returns (bool disableMevModule) {
        ScheduleConfig storage config = _configs[poolKey.toId()];

        uint256 elapsed = block.timestamp - config.startTime;
        if (elapsed >= config.totalDuration) {
            // Full schedule complete — disable; normal fee takes over and no
            // extra is signaled.
            return true;
        }

        // Find the step that covers `elapsed`.
        uint256 cumulative = 0;
        uint256 n = config.steps.length;
        for (uint256 i = 0; i < n; i++) {
            cumulative += config.steps[i].durationSec;
            if (elapsed < cumulative) {
                uint24 totalPpm = config.steps[i].feePpm;
                // basePpm < smallest step.feePpm enforced at init, so this is
                // always positive.
                uint24 extraPpm = totalPpm - config.basePpm;
                IArtCoinsHook(msg.sender).mevModuleSetSniperFee(poolKey, extraPpm);
                return false;
            }
        }
        // Unreachable in practice (elapsed < totalDuration ⇒ falls into a step).
        return true;
    }

    /// @notice Returns the current total fee for a pool in ppm (1% = 10_000).
    function getCurrentTotalFeePpm(PoolKey calldata poolKey) external view returns (uint24) {
        ScheduleConfig storage config = _configs[poolKey.toId()];
        if (config.startTime == 0) return 0;
        uint256 elapsed = block.timestamp - config.startTime;
        if (elapsed >= config.totalDuration) {
            // Last step's fee for display purposes after end.
            return config.steps[config.steps.length - 1].feePpm;
        }
        uint256 cumulative = 0;
        uint256 n = config.steps.length;
        for (uint256 i = 0; i < n; i++) {
            cumulative += config.steps[i].durationSec;
            if (elapsed < cumulative) return config.steps[i].feePpm;
        }
        return config.steps[n - 1].feePpm;
    }

    /// @notice Returns the current EXTRA fee (above base) for a pool, in ppm.
    /// @return Zero after the schedule completes; otherwise the active step's
    ///         total minus the configured base.
    function getCurrentExtraFeePpm(PoolKey calldata poolKey) external view returns (uint24) {
        ScheduleConfig storage config = _configs[poolKey.toId()];
        if (config.startTime == 0) return 0;
        uint256 elapsed = block.timestamp - config.startTime;
        if (elapsed >= config.totalDuration) return 0;
        uint256 cumulative = 0;
        uint256 n = config.steps.length;
        for (uint256 i = 0; i < n; i++) {
            cumulative += config.steps[i].durationSec;
            if (elapsed < cumulative) {
                return config.steps[i].feePpm - config.basePpm;
            }
        }
        return 0;
    }

    /// @notice Returns seconds remaining in the anti-sniper period.
    function getTimeRemaining(PoolKey calldata poolKey) external view returns (uint256) {
        ScheduleConfig storage config = _configs[poolKey.toId()];
        if (config.startTime == 0) return 0;
        uint256 elapsed = block.timestamp - config.startTime;
        if (elapsed >= config.totalDuration) return 0;
        return config.totalDuration - elapsed;
    }

    /// @notice Returns the full schedule for a pool (view helper).
    function scheduleOf(PoolKey calldata poolKey)
        external
        view
        returns (uint64 startTime, uint32 totalDuration, uint24 basePpm, Step[] memory steps)
    {
        ScheduleConfig storage config = _configs[poolKey.toId()];
        startTime = config.startTime;
        totalDuration = config.totalDuration;
        basePpm = config.basePpm;
        uint256 n = config.steps.length;
        steps = new Step[](n);
        for (uint256 i = 0; i < n; i++) {
            steps[i] = config.steps[i];
        }
    }

    /// @inheritdoc IArtCoinsMevModuleBase
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsMevModule).interfaceId
            || interfaceId == type(IArtCoinsMevModuleBase).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}
