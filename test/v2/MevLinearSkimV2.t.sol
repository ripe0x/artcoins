// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../src/Constants.sol";
import {IArtCoinsMevModule} from "../../src/interfaces/IArtCoinsMevModule.sol";
import {IArtCoinsMevModuleBase} from "../../src/interfaces/IArtCoinsMevModuleBase.sol";
import {IArtCoinsMevSkimV2} from "../../src/v2/interfaces/IArtCoinsMevSkimV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";
import {ArtCoinsMevLinearSkimV2} from "../../src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev Stands in for the hook: answers `constantsHash` and forwards `initialize`.
contract MockSkimHook {
    bytes32 public h = Constants.hash();

    function setHash(bytes32 h_) external {
        h = h_;
    }

    function constantsHash() external view returns (bytes32) {
        return h;
    }

    function init(ArtCoinsMevLinearSkimV2 m, PoolId id, bytes calldata cfg) external {
        m.initialize(id, cfg);
    }
}

contract MevLinearSkimV2Test is Test {
    MockSkimHook internal hookMock;
    ArtCoinsMevLinearSkimV2 internal mod;

    PoolId internal constant POOL = PoolId.wrap(bytes32(uint256(0xA11CE)));
    PoolId internal constant POOL2 = PoolId.wrap(bytes32(uint256(0xB0B)));

    uint24 internal constant START = 68_690;
    uint24 internal constant END = 6000;
    uint32 internal constant WINDOW = 69 minutes;
    uint256 internal constant T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        hookMock = new MockSkimHook();
        mod = new ArtCoinsMevLinearSkimV2(address(hookMock));
    }

    function _cfg2(uint24 start, uint32 window) internal pure returns (bytes memory) {
        return abi.encode(start, window);
    }

    function _cfg3(uint24 start, uint32 window, uint24 end) internal pure returns (bytes memory) {
        return abi.encode(start, window, end);
    }

    function _init3() internal {
        hookMock.init(mod, POOL, _cfg3(START, WINDOW, END));
    }

    // ── config bounds ─────────────────────────────────────────────────────

    function test_mevV2_durationAboveCap_reverts() public {
        uint32 over = Constants.MAX_MEV_WINDOW + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsMevSkimV2.OutOfBounds.selector,
                over,
                Constants.MIN_MEV_WINDOW,
                Constants.MAX_MEV_WINDOW
            )
        );
        hookMock.init(mod, POOL, _cfg2(START, over));
    }

    function test_mevV2_durationBelowMin_reverts() public {
        uint32 under = Constants.MIN_MEV_WINDOW - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsMevSkimV2.OutOfBounds.selector,
                under,
                Constants.MIN_MEV_WINDOW,
                Constants.MAX_MEV_WINDOW
            )
        );
        hookMock.init(mod, POOL, _cfg2(START, under));
        vm.expectRevert();
        hookMock.init(mod, POOL, _cfg2(START, 0));
    }

    function test_mevV2_durationAtBounds_ok() public {
        hookMock.init(mod, POOL, _cfg2(START, Constants.MIN_MEV_WINDOW));
        hookMock.init(mod, POOL2, _cfg2(START, Constants.MAX_MEV_WINDOW));
        assertEq(mod.windowEnd(POOL), T0 + Constants.MIN_MEV_WINDOW);
        assertEq(mod.windowEnd(POOL2), T0 + Constants.MAX_MEV_WINDOW);
    }

    function test_mevV2_startingSkimAboveCap_reverts() public {
        uint24 over = Constants.MAX_SKIM_BPS + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsMevSkimV2.StartingSkimTooHigh.selector, over, Constants.MAX_SKIM_BPS
            )
        );
        hookMock.init(mod, POOL, _cfg2(over, WINDOW));
    }

    function test_mevV2_startingSkimAtCap_ok() public {
        hookMock.init(mod, POOL, _cfg2(Constants.MAX_SKIM_BPS, WINDOW));
        (uint24 s, bool a) = mod.currentSkimBps(POOL);
        assertEq(s, Constants.MAX_SKIM_BPS);
        assertTrue(a);
    }

    function test_mevV2_endAboveStart_reverts() public {
        vm.expectRevert(IArtCoinsMevSkimV2.InvalidConfig.selector);
        hookMock.init(mod, POOL, _cfg3(5000, WINDOW, 5001));
    }

    function test_mevV2_endAboveBaselineCap_reverts() public {
        vm.expectRevert(IArtCoinsMevSkimV2.InvalidConfig.selector);
        hookMock.init(mod, POOL, _cfg3(60_000, WINDOW, Constants.MAX_BASELINE_SKIM_BPS + 1));
    }

    function test_mevV2_badConfigLength_reverts() public {
        vm.expectRevert(IArtCoinsMevSkimV2.InvalidConfig.selector);
        hookMock.init(mod, POOL, hex"01");
        vm.expectRevert(IArtCoinsMevSkimV2.InvalidConfig.selector);
        hookMock.init(mod, POOL, abi.encode(uint256(1)));
    }

    function test_mevV2_emptyConfig_usesDefaults() public {
        hookMock.init(mod, POOL, "");
        ArtCoinsMevLinearSkimV2.SkimSchedule memory s = mod.schedule(POOL);
        assertEq(s.startingSkimBps, Constants.DEFAULT_START_SKIM_BPS);
        assertEq(s.windowSeconds, Constants.DEFAULT_MEV_WINDOW);
        assertEq(s.endSkimBps, 0);
        assertEq(s.startTime, T0);
    }

    function test_mevV2_zeroHook_reverts() public {
        vm.expectRevert(IArtCoinsMevSkimV2.InvalidConfig.selector);
        new ArtCoinsMevLinearSkimV2(address(0));
    }

    // ── access and one shot ───────────────────────────────────────────────

    function test_mevV2_nonHookCaller_reverts() public {
        vm.expectRevert(IArtCoinsMevSkimV2.NotHook.selector);
        mod.initialize(POOL, _cfg3(START, WINDOW, END));

        vm.prank(address(0xBEEF));
        vm.expectRevert(IArtCoinsMevSkimV2.NotHook.selector);
        mod.initialize(POOL, _cfg3(START, WINDOW, END));
        assertEq(mod.windowEnd(POOL), 0);
    }

    function test_mevV2_doubleInit_reverts() public {
        _init3();
        vm.expectRevert(IArtCoinsMevSkimV2.AlreadyInitialized.selector);
        hookMock.init(mod, POOL, _cfg3(START, WINDOW, END));
        // a different config cannot overwrite either
        vm.expectRevert(IArtCoinsMevSkimV2.AlreadyInitialized.selector);
        hookMock.init(mod, POOL, _cfg2(1, Constants.MIN_MEV_WINDOW));
        // another pool is independent
        hookMock.init(mod, POOL2, _cfg3(START, WINDOW, END));
    }

    function test_mevV2_constantsMismatch_reverts() public {
        hookMock.setHash(bytes32(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(hookMock))
        );
        hookMock.init(mod, POOL, _cfg3(START, WINDOW, END));
    }

    function test_mevV2_hookWithoutConstantsHash_reverts() public {
        // an EOA style hook (no code) cannot answer, so init is refused
        address eoaHook = address(0xE0A);
        ArtCoinsMevLinearSkimV2 m = new ArtCoinsMevLinearSkimV2(eoaHook);
        vm.prank(eoaHook);
        vm.expectRevert(abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, eoaHook));
        m.initialize(POOL, _cfg2(START, WINDOW));
    }

    function test_mevV2_hookIsImmutableAndNoOwner() public view {
        assertEq(mod.hook(), address(hookMock));
        (bool ok,) = address(mod).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    // ── schedule ──────────────────────────────────────────────────────────

    function test_mevV2_uninitialized_reportsZero() public view {
        (uint24 s, bool a) = mod.currentSkimBps(POOL);
        assertEq(s, 0);
        assertFalse(a);
        assertEq(mod.windowEnd(POOL), 0);
    }

    function test_mevV2_decay_0_50_100_percent() public {
        _init3();

        (uint24 s, bool a) = mod.currentSkimBps(POOL);
        assertEq(s, START, "t=0");
        assertTrue(a);

        vm.warp(T0 + WINDOW / 2);
        (s, a) = mod.currentSkimBps(POOL);
        uint24 mid = uint24(uint256(START) - (uint256(START - END) * (WINDOW / 2)) / WINDOW);
        assertEq(s, mid, "t=50%");
        assertEq(s, 37_345, "t=50% literal");
        assertTrue(a);

        vm.warp(T0 + WINDOW - 1);
        (s, a) = mod.currentSkimBps(POOL);
        assertGe(s, END);
        assertLe(s, mid);
        assertTrue(a);

        vm.warp(T0 + WINDOW);
        (s, a) = mod.currentSkimBps(POOL);
        assertEq(s, END, "t=100%");
        assertFalse(a, "inactive at end");

        vm.warp(T0 + WINDOW + 1 days);
        (s, a) = mod.currentSkimBps(POOL);
        assertEq(s, END, "after");
        assertFalse(a);

        vm.warp(T0 + 365 days);
        (s, a) = mod.currentSkimBps(POOL);
        assertEq(s, END);
        assertFalse(a);
    }

    function test_mevV2_decayToZeroWhenNoEndGiven() public {
        hookMock.init(mod, POOL, _cfg2(START, WINDOW));
        vm.warp(T0 + WINDOW);
        (uint24 s, bool a) = mod.currentSkimBps(POOL);
        assertEq(s, 0);
        assertFalse(a);
    }

    function test_mevV2_activeFlipsAtWindowEnd() public {
        _init3();
        uint40 end = mod.windowEnd(POOL);
        assertEq(end, T0 + WINDOW);

        vm.warp(end - 1);
        (, bool a) = mod.currentSkimBps(POOL);
        assertTrue(a);

        vm.warp(end);
        (, a) = mod.currentSkimBps(POOL);
        assertFalse(a);
    }

    function test_mevV2_startTimeIsInitTime_andEventsEmitted() public {
        vm.warp(T0 + 123);
        vm.expectEmit(true, false, false, true, address(mod));
        emit IArtCoinsMevSkimV2.MevConfigInitialized(POOL, START, WINDOW, uint40(T0 + 123));
        vm.expectEmit(true, false, false, true, address(mod));
        emit ArtCoinsMevLinearSkimV2.MevEndSkimSet(POOL, END);
        _init3();
        ArtCoinsMevLinearSkimV2.SkimSchedule memory s = mod.schedule(POOL);
        assertEq(s.startTime, T0 + 123);
        assertEq(mod.windowEnd(POOL), T0 + 123 + WINDOW);
    }

    function test_mevV2_configFrozen_noMutatorsExist() public {
        _init3();
        // no setter selector is answered
        bytes4[5] memory sels = [
            bytes4(keccak256("setWindow(bytes32,uint32)")),
            bytes4(keccak256("setStartingSkimBps(bytes32,uint24)")),
            bytes4(keccak256("setHook(address)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("renounceOwnership()"))
        ];
        for (uint256 i; i < sels.length; ++i) {
            (bool ok,) = address(mod).call(abi.encodeWithSelector(sels[i], bytes32(0), uint256(1)));
            assertFalse(ok);
        }
        (uint24 s,) = mod.currentSkimBps(POOL);
        assertEq(s, START);
    }

    // ── identity ──────────────────────────────────────────────────────────

    function test_mevV2_constantsHash_matchesConstants() public view {
        assertEq(mod.constantsHash(), Constants.hash());
        assertEq(hookMock.constantsHash(), mod.constantsHash());
    }

    function test_mevV2_erc165_ids() public view {
        assertTrue(mod.supportsInterface(type(IArtCoinsMevSkimV2).interfaceId));
        assertTrue(mod.supportsInterface(type(IConstantsBound).interfaceId));
        assertTrue(mod.supportsInterface(type(IERC165).interfaceId));
        assertFalse(mod.supportsInterface(0xffffffff));
        assertFalse(mod.supportsInterface(0x00000000));
    }

    /// H9: the module is never a fee module. It answers neither v1 module interface
    /// id and has no `beforeSwap`.
    function test_mevV2_neverUsableAsFeeModule() public {
        assertFalse(mod.supportsInterface(type(IArtCoinsMevModuleBase).interfaceId));
        assertFalse(mod.supportsInterface(type(IArtCoinsMevModule).interfaceId));
        (bool ok,) =
            address(mod).call(abi.encodeWithSelector(IArtCoinsMevModule.beforeSwap.selector));
        assertFalse(ok);
        // the v1 initialize(PoolKey,bytes) selector is not served either
        (ok,) =
            address(mod).call(abi.encodeWithSelector(IArtCoinsMevModuleBase.initialize.selector));
        assertFalse(ok);
    }

    // ── fuzz ──────────────────────────────────────────────────────────────

    function testFuzz_mevV2_skimMonotoneAndBounded(
        uint24 start,
        uint24 end,
        uint32 window,
        uint32 t1,
        uint32 t2
    ) public {
        start = uint24(bound(start, 0, Constants.MAX_SKIM_BPS));
        end = uint24(
            bound(
                end,
                0,
                start < Constants.MAX_BASELINE_SKIM_BPS ? start : Constants.MAX_BASELINE_SKIM_BPS
            )
        );
        window = uint32(bound(window, Constants.MIN_MEV_WINDOW, Constants.MAX_MEV_WINDOW));
        t1 = uint32(bound(t1, 0, uint256(window) * 2));
        t2 = uint32(bound(t2, t1, uint256(window) * 2 + 1));

        hookMock.init(mod, POOL, _cfg3(start, window, end));

        vm.warp(T0 + t1);
        (uint24 a, bool act1) = mod.currentSkimBps(POOL);
        vm.warp(T0 + t2);
        (uint24 b, bool act2) = mod.currentSkimBps(POOL);

        assertLe(b, a, "monotone non increasing");
        assertLe(a, start, "never above start");
        assertGe(b, end, "never below end");
        assertGe(a, end);
        assertLe(b, start);
        assertEq(act1, t1 < window);
        assertEq(act2, t2 < window);
        if (t2 >= window) assertEq(b, end, "settles at end");
        if (t1 == 0) assertEq(a, start, "starts at start");
    }
}
