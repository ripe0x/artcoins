// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IArtCoinsMevModule} from "../src/interfaces/IArtCoinsMevModule.sol";
import {IArtCoinsMevModuleBase} from "../src/interfaces/IArtCoinsMevModuleBase.sol";
import {ArtCoinsMevSniperSteppedFees} from "../src/mev-modules/ArtCoinsMevSniperSteppedFees.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Mock hook used by the module's `onlyHook` modifier. Records the
///         most recent `mevModuleSetSniperFee` call so tests can assert that
///         the module is signaling the right extra at each step.
contract MockHook {
    uint24 public lastExtraPpm;
    uint256 public callCount;

    function mevModuleSetSniperFee(PoolKey calldata, uint24 extraPpm) external {
        lastExtraPpm = extraPpm;
        callCount++;
    }

    function MAX_MEV_MODULE_DELAY() external pure returns (uint256) {
        return 15 minutes;
    }
}

contract ArtCoinsMevSniperSteppedFeesTest is Test {
    ArtCoinsMevSniperSteppedFees internal module;
    MockHook internal hook;
    PoolKey internal poolKey;
    IPoolManager.SwapParams internal swapParams;

    function setUp() public {
        module = new ArtCoinsMevSniperSteppedFees();
        hook = new MockHook();
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0xAAAA)),
            currency1: Currency.wrap(address(0xBBBB)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        swapParams = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
        });
    }

    /// @dev Default LAYER schedule used by most tests: 5 steps decaying from
    ///      50% to 3%, with base = 1%.
    function _defaultSchedule()
        internal
        pure
        returns (ArtCoinsMevSniperSteppedFees.Step[] memory schedule, uint24 basePpm)
    {
        schedule = new ArtCoinsMevSniperSteppedFees.Step[](5);
        schedule[0] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 60, feePpm: 500_000});
        schedule[1] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 120, feePpm: 250_000});
        schedule[2] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 120, feePpm: 150_000});
        schedule[3] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 300, feePpm: 70_000});
        schedule[4] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 300, feePpm: 30_000});
        basePpm = 10_000;
    }

    function _initDefault() internal {
        (ArtCoinsMevSniperSteppedFees.Step[] memory schedule, uint24 basePpm) = _defaultSchedule();
        vm.prank(address(hook));
        module.initialize(poolKey, abi.encode(schedule, basePpm));
    }

    // ─── init / config ──────────────────────────────────────────────────

    function test_configureMevModule() public {
        _initDefault();
        (
            uint64 startTime,
            uint32 totalDuration,
            uint24 basePpm,
            ArtCoinsMevSniperSteppedFees.Step[] memory steps
        ) = module.scheduleOf(poolKey);
        assertEq(startTime, uint64(block.timestamp));
        assertEq(totalDuration, 60 + 120 + 120 + 300 + 300);
        assertEq(basePpm, 10_000);
        assertEq(steps.length, 5);
        assertEq(steps[0].feePpm, 500_000);
        assertEq(steps[4].feePpm, 30_000);
    }

    function test_initFromNonHookReverts() public {
        (ArtCoinsMevSniperSteppedFees.Step[] memory schedule, uint24 basePpm) = _defaultSchedule();
        vm.expectRevert(IArtCoinsMevModuleBase.OnlyHook.selector);
        module.initialize(poolKey, abi.encode(schedule, basePpm));
    }

    function test_emptyInitDataRejected() public {
        vm.prank(address(hook));
        vm.expectRevert(ArtCoinsMevSniperSteppedFees.InvalidConfig.selector);
        module.initialize(poolKey, "");
    }

    function test_zeroStepDurationRejected() public {
        ArtCoinsMevSniperSteppedFees.Step[] memory schedule =
            new ArtCoinsMevSniperSteppedFees.Step[](2);
        schedule[0] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 0, feePpm: 500_000});
        schedule[1] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 60, feePpm: 30_000});
        vm.prank(address(hook));
        vm.expectRevert(ArtCoinsMevSniperSteppedFees.InvalidConfig.selector);
        module.initialize(poolKey, abi.encode(schedule, uint24(10_000)));
    }

    function test_nonDecreasingFeesRejected() public {
        ArtCoinsMevSniperSteppedFees.Step[] memory schedule =
            new ArtCoinsMevSniperSteppedFees.Step[](2);
        schedule[0] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 60, feePpm: 100_000});
        schedule[1] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 60, feePpm: 100_000});
        vm.prank(address(hook));
        vm.expectRevert(ArtCoinsMevSniperSteppedFees.InvalidConfig.selector);
        module.initialize(poolKey, abi.encode(schedule, uint24(10_000)));
    }

    function test_initialFeeAboveMaxRejected() public {
        ArtCoinsMevSniperSteppedFees.Step[] memory schedule =
            new ArtCoinsMevSniperSteppedFees.Step[](1);
        schedule[0] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 60, feePpm: 991_000});
        vm.prank(address(hook));
        vm.expectRevert(ArtCoinsMevSniperSteppedFees.InvalidConfig.selector);
        module.initialize(poolKey, abi.encode(schedule, uint24(10_000)));
    }

    function test_baseTooHighRejected() public {
        // Last step is 30_000 ppm; base ≥ 30_000 means the smallest extra
        // would be ≤ 0, defeating the module's purpose.
        (ArtCoinsMevSniperSteppedFees.Step[] memory schedule,) = _defaultSchedule();
        vm.prank(address(hook));
        vm.expectRevert(ArtCoinsMevSniperSteppedFees.InvalidConfig.selector);
        module.initialize(poolKey, abi.encode(schedule, uint24(30_000)));
    }

    function test_totalDurationAboveHookMaxRejected() public {
        ArtCoinsMevSniperSteppedFees.Step[] memory schedule =
            new ArtCoinsMevSniperSteppedFees.Step[](2);
        schedule[0] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 600, feePpm: 100_000});
        schedule[1] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 301, feePpm: 30_000});

        vm.prank(address(hook));
        vm.expectRevert(ArtCoinsMevSniperSteppedFees.InvalidConfig.selector);
        module.initialize(poolKey, abi.encode(schedule, uint24(10_000)));
    }

    function test_doubleInitRejected() public {
        _initDefault();
        (ArtCoinsMevSniperSteppedFees.Step[] memory schedule, uint24 basePpm) = _defaultSchedule();
        vm.prank(address(hook));
        vm.expectRevert(ArtCoinsMevSniperSteppedFees.InvalidConfig.selector);
        module.initialize(poolKey, abi.encode(schedule, basePpm));
    }

    // ─── per-step EXTRA assertions (the whole point of the module) ───────

    /// @dev The user spec dictates: "minute 0 fee is 50%, base 1%, extra 49%"
    ///      and so on for each step. Verify the module derives the right
    ///      extras at the right times.
    function test_currentExtraFeeAtEachStep() public {
        uint64 t0 = uint64(block.timestamp);
        _initDefault();

        // step 0: 0–60s -> total 500_000, extra 490_000
        assertEq(module.getCurrentExtraFeePpm(poolKey), 490_000, "step 0 extra");
        assertEq(module.getCurrentTotalFeePpm(poolKey), 500_000, "step 0 total");

        // step 1: 60–180s -> total 250_000, extra 240_000
        vm.warp(t0 + 90);
        assertEq(module.getCurrentExtraFeePpm(poolKey), 240_000, "step 1 extra");
        assertEq(module.getCurrentTotalFeePpm(poolKey), 250_000, "step 1 total");

        // step 2: 180–300s -> total 150_000, extra 140_000
        vm.warp(t0 + 240);
        assertEq(module.getCurrentExtraFeePpm(poolKey), 140_000, "step 2 extra");
        assertEq(module.getCurrentTotalFeePpm(poolKey), 150_000, "step 2 total");

        // step 3: 300–600s -> total 70_000, extra 60_000
        vm.warp(t0 + 450);
        assertEq(module.getCurrentExtraFeePpm(poolKey), 60_000, "step 3 extra");
        assertEq(module.getCurrentTotalFeePpm(poolKey), 70_000, "step 3 total");

        // step 4: 600–900s -> total 30_000, extra 20_000
        vm.warp(t0 + 750);
        assertEq(module.getCurrentExtraFeePpm(poolKey), 20_000, "step 4 extra");
        assertEq(module.getCurrentTotalFeePpm(poolKey), 30_000, "step 4 total");

        // 900s+: schedule complete; extra MUST be 0 (no fee leak)
        vm.warp(t0 + 900);
        assertEq(module.getCurrentExtraFeePpm(poolKey), 0, "post-schedule extra");

        vm.warp(t0 + 3600);
        assertEq(module.getCurrentExtraFeePpm(poolKey), 0, "1h post-schedule extra");
    }

    // ─── beforeSwap — the live signaling path ───────────────────────────

    function test_beforeSwapSignalsExtraToHook() public {
        _initDefault();

        // step 0
        vm.prank(address(hook));
        bool disable = module.beforeSwap(poolKey, swapParams, true, "");
        assertEq(disable, false);
        assertEq(hook.lastExtraPpm(), 490_000, "step 0 signaled extra");
        assertEq(hook.callCount(), 1);

        // step 4
        vm.warp(block.timestamp + 750);
        vm.prank(address(hook));
        disable = module.beforeSwap(poolKey, swapParams, true, "");
        assertEq(disable, false);
        assertEq(hook.lastExtraPpm(), 20_000, "step 4 signaled extra");
        assertEq(hook.callCount(), 2);
    }

    function test_beforeSwapDisablesAfterSchedule() public {
        _initDefault();
        vm.warp(block.timestamp + 900);
        vm.prank(address(hook));
        bool disable = module.beforeSwap(poolKey, swapParams, true, "");
        assertEq(disable, true, "module signals disable after schedule");
        // No extra signaled when disabling
        assertEq(hook.callCount(), 0, "no extra signaled at disable");
    }

    function test_beforeSwapFromNonHookReverts() public {
        _initDefault();
        vm.expectRevert(IArtCoinsMevModuleBase.OnlyHook.selector);
        module.beforeSwap(poolKey, swapParams, true, "");
    }

    // ─── getTimeRemaining ───────────────────────────────────────────────

    function test_timeRemainingAcrossSchedule() public {
        uint64 t0 = uint64(block.timestamp);
        _initDefault();
        assertEq(module.getTimeRemaining(poolKey), 900, "at start = 900s");

        vm.warp(t0 + 60);
        assertEq(module.getTimeRemaining(poolKey), 840, "after 60s = 840s");

        vm.warp(t0 + 900);
        assertEq(module.getTimeRemaining(poolKey), 0, "at end = 0");

        vm.warp(t0 + 3600);
        assertEq(module.getTimeRemaining(poolKey), 0, "after end = 0");
    }

    // ─── ERC-165 ────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(module.supportsInterface(type(IArtCoinsMevModule).interfaceId));
    }
}
