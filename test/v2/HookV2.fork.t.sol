// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// v2 hook suite (package h1). pool tests fork mainnet at the pinned block and
// run against the live PoolManager; they skip themselves without an rpc.
// owner, flag and calldata parser tests run without a fork.
//
// covers DESIGN section 3 b1 (hook half), b2, b3, b7, d1, d3, d5, d6 and the
// hooks review (docs/v2/review/contracts-hooks-mev.md) proofs flipped into
// regressions: H1 H2 H3 H4 H5 H7 H8 H11 H13 H14, N2.

import {HookV2ForkBase} from "./mocks/HookV2ForkBase.sol";
import {
    HV2AddRemoveRouter,
    HV2ConstantsStub,
    HV2EmptyFallback,
    HV2Extension,
    HV2GasBurner,
    HV2LyingModule,
    HV2Rejecter,
    HV2ReturnBomb,
    HV2RevertingModule,
    HV2RevertingPayout,
    HV2StreamRecipient
} from "./mocks/HookV2Mocks.sol";

import {Constants} from "../../src/Constants.sol";
import {IArtCoinsHook} from "../../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsTokenV2} from "../../src/v2/ArtCoinsTokenV2.sol";
import {HookCalldata} from "../../src/v2/hooks/libraries/HookCalldata.sol";
import {IArtCoinsHookV2} from "../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsMevSkimV2} from "../../src/v2/interfaces/IArtCoinsMevSkimV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";
import {ArtCoinsMevLinearSkimV2} from "../../src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// exposes the internal hookData parser.
contract HV2CalldataHarness {
    function decode(bytes calldata d)
        external
        pure
        returns (bytes memory ext, HookCalldata.Attribution memory att)
    {
        (bytes calldata e, HookCalldata.Attribution memory a) = HookCalldata.decode(d);
        return (e, a);
    }
}

contract HookV2ForkTest is HookV2ForkBase {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant D = Constants.SKIM_DENOMINATOR;

    // ─── helpers ─────────────────────────────────────────────────────────

    /// expected (bounty, protocol) for a skim at `bps` with no referral.
    function _legs(uint256 skim, uint256 bps) internal pure returns (uint256 bounty, uint256 protocol) {
        uint256 base = (skim * BASELINE) / bps;
        uint256 bs = (base * BOUNTY_BPS) / Constants.BPS;
        protocol = base - bs;
        bounty = bs + (skim - base);
    }

    function _paid(address a) internal view returns (uint256) {
        return a.balance + _escrowed(a);
    }

    function _launchProtocol(Launch memory l, address protocol)
        internal
        returns (PoolKey memory key, ArtCoinsTokenV2 token)
    {
        token = _newToken(l.taxMode, l.bounty, address(hook));
        IArtCoinsHookV2.PoolInitParams memory p = _params(l, address(token));
        p.skim.protocolRecipient = payable(protocol);
        key = hook.initializePool(p);
        _modify(key, FULL_LO, FULL_HI, int256(LIQ), 0);
        hook.initializeMevModule(key, l.mevConfig);
    }

    function _skimOfBuy1Eth(PoolKey memory key, address bounty) internal returns (uint256 total) {
        uint256 b0 = _paid(bounty);
        uint256 p0 = _paid(protocolR);
        _swap(key, true, -1 ether, 0, "");
        total = (_paid(bounty) - b0) + (_paid(protocolR) - p0);
    }

    // ─── b2 / H1 H2: no recipient behavior can revert a swap ─────────────

    function test_swap_bountyEoaWithBalance_noRevert() public onlyFork {
        vm.deal(bountyEoa, 1 ether); // v1: >= 0.01 eth on an eoa bricked every swap
        PoolKey memory key = _launchSimple(bountyEoa);
        uint256 b0 = bountyEoa.balance;
        _swap(key, true, -1 ether, 0, "");
        _swap(key, false, -1 ether, 0, "");
        (uint256 bounty,) = _legs((1 ether * BASELINE) / D, BASELINE);
        assertGe(bountyEoa.balance - b0, bounty, "bounty pushed to the eoa");
        assertEq(_escrowed(bountyEoa), 0);
    }

    function test_swap_bountyEmptyFallback_noRevert() public onlyFork {
        HV2EmptyFallback r = new HV2EmptyFallback();
        vm.deal(address(r), 1 ether);
        PoolKey memory key = _launchSimple(address(r));
        uint256 b0 = address(r).balance;
        _swap(key, true, -1 ether, 0, "");
        (uint256 bounty,) = _legs((1 ether * BASELINE) / D, BASELINE);
        assertEq(address(r).balance - b0, bounty, "pushed, empty fallback accepts eth");
        // and again once its balance is far above the stream floor
        _swap(key, true, -1 ether, 0, "");
    }

    function test_swap_bountyReturnBomb_bounded() public onlyFork {
        uint256 refGas = _refSwapGas();
        HV2ReturnBomb r = new HV2ReturnBomb();
        vm.deal(address(r), 1 ether);
        PoolKey memory key = _launchSimple(address(r));
        _swap(key, true, -0.1 ether, 0, ""); // warm the pool
        uint256 g0 = gasleft();
        _swap(key, true, -1 ether, 0, "");
        uint256 used = g0 - gasleft();
        // probe capped at preSwapStreamGas, 100kb of returndata never copied
        assertLt(used, refGas + hook.globals().preSwapStreamGas + 10_000, "return bomb bounded");
        assertEq(r.bombs(), 2, "probe succeeded and offered the blob twice");
        (uint256 bounty,) = _legs((1 ether * BASELINE) / D, BASELINE);
        assertGe(address(r).balance, 1 ether + bounty, "pushed");
    }

    /// gas of a warm 1 eth exact in buy on a pool whose bounty recipient is an eoa.
    function _refSwapGas() internal returns (uint256) {
        PoolKey memory ref = _launchSimple(bountyEoa);
        _swap(ref, true, -0.1 ether, 0, "");
        uint256 g0 = gasleft();
        _swap(ref, true, -1 ether, 0, "");
        return g0 - gasleft();
    }

    function test_swap_bountyGasBurner_bounded() public onlyFork {
        uint256 refGas = _refSwapGas();

        HV2GasBurner r = new HV2GasBurner();
        vm.deal(address(r), 1 ether);
        PoolKey memory key = _launchSimple(address(r));
        _swap(key, true, -0.1 ether, 0, "");
        uint256 g0 = gasleft();
        _swap(key, true, -1 ether, 0, "");
        uint256 used = g0 - gasleft();

        IArtCoinsHookV2.HookGlobals memory g = hook.globals();
        // probe + push caps + one cold escrow credit
        assertLt(used, refGas + g.preSwapStreamGas + g.pushGas + 80_000, "gas burner bounded");
        assertGt(_escrowed(address(r)), 0, "bounty escrowed");
    }

    function test_swap_bountyRejectsEth_escrowed() public onlyFork {
        HV2Rejecter r = new HV2Rejecter();
        vm.deal(address(r), 1 ether); // streamForward reverts too, and is probed
        PoolKey memory key = _launchSimple(address(r));
        uint256 skim = (1 ether * BASELINE) / D;
        (uint256 bounty,) = _legs(skim, BASELINE);
        vm.expectEmit(true, true, true, true, address(hook));
        emit IArtCoinsHookV2.FeeDelivered(key.toId(), Constants.LEG_BOUNTY, address(r), bounty, true);
        _swap(key, true, -1 ether, 0, "");
        assertEq(_escrowed(address(r)), bounty);
        assertEq(address(r).balance, 1 ether);
    }

    function test_swap_protocolRejectsOrBurnsGas_escrowed() public onlyFork {
        HV2Rejecter rej = new HV2Rejecter();
        (PoolKey memory key,) = _launchProtocol(_defaults(bountyEoa), address(rej));
        _swap(key, true, -1 ether, 0, "");
        (, uint256 protocol) = _legs((1 ether * BASELINE) / D, BASELINE);
        assertEq(_escrowed(address(rej)), protocol);

        HV2GasBurner burner = new HV2GasBurner();
        (key,) = _launchProtocol(_defaults(bountyEoa), address(burner));
        _swap(key, true, -1 ether, 0, "");
        assertEq(_escrowed(address(burner)), protocol);
    }

    function test_swap_streamProbe_onlyAboveFloor() public onlyFork {
        HV2StreamRecipient r = new HV2StreamRecipient();
        PoolKey memory key = _launchSimple(address(r));
        _swap(key, true, -0.01 ether, 0, ""); // recipient balance below 0.01 eth
        assertEq(r.streams(), 0, "below floor: no probe");
        vm.deal(address(r), 1 ether);
        _swap(key, true, -0.01 ether, 0, "");
        assertEq(r.streams(), 1, "probed once");
    }

    // ─── b3 / H4 H5: skim on the realized fill, unfilled share refunded ───

    function test_skim_fullFill_noRefund() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        uint256 skim = _skimOfBuy1Eth(key, bountyEoa);
        assertEq(skim, (1 ether * BASELINE) / D);
        assertEq(_escrowed(address(swapRouter)), 0, "no refund");
    }

    function test_skim_exactInPriceLimited_refundsUnfilled() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        uint256 a = 100 ether;
        uint256 charged = (a * BASELINE) / D;
        uint256 requested = a - charged;
        uint256 b0 = _paid(bountyEoa);
        uint256 p0 = _paid(protocolR);

        BalanceDelta d = _swap(key, true, -int256(a), TickMath.getSqrtPriceAtTick(-100), "");

        uint256 paid = uint256(-int256(d.amount0()));
        uint256 r = paid - charged; // realized pool input
        assertLt(r, requested / 4, "partial fill");
        uint256 fair = (charged * r) / requested;
        uint256 legs = (_paid(bountyEoa) - b0) + (_paid(protocolR) - p0);
        assertEq(legs, fair, "legs on the fill");
        assertEq(_escrowed(address(swapRouter)), charged - fair, "unfilled skim refunded to caller");
        // effective rate on the fill stays the nominal 6% (v1: unbounded)
        assertApproxEqRel(fair * D, (r + fair) * BASELINE, 1e12);
    }

    function test_skim_exactOutPriceLimited_refundsUnfilled() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        uint256 a = 100 ether; // eth out requested
        uint256 charged = (a * BASELINE) / (D - BASELINE);
        uint256 requested = a + charged;
        uint256 b0 = _paid(bountyEoa);
        uint256 p0 = _paid(protocolR);

        BalanceDelta d = _swap(key, false, int256(a), TickMath.getSqrtPriceAtTick(100), "");

        int256 r = int256(d.amount0()) + int256(charged); // realized pool output
        assertGt(r, 0);
        assertLt(uint256(r), requested / 4, "partial fill");
        uint256 fair = (charged * uint256(r)) / requested;
        uint256 refund = charged - fair;
        assertEq(_escrowed(address(swapRouter)), refund, "unfilled skim refunded to caller");
        uint256 legs = (_paid(bountyEoa) - b0) + (_paid(protocolR) - p0);
        assertEq(legs, fair);
        // H5: net of the refund the seller receives eth, never pays it
        assertGt(int256(d.amount0()) + int256(refund), 0, "seller nets eth");
    }

    function test_skim_quoteUnspecified_realized() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        // exact in sell: skim from the realized output
        uint256 b0 = _paid(bountyEoa);
        uint256 p0 = _paid(protocolR);
        BalanceDelta d = _swap(key, false, -1 ether, 0, "");
        uint256 s = (_paid(bountyEoa) - b0) + (_paid(protocolR) - p0);
        uint256 r = uint256(int256(d.amount0())) + s;
        assertEq(s, (r * BASELINE) / D);

        // exact out buy: skim grossed up on top of the realized input
        b0 = _paid(bountyEoa);
        p0 = _paid(protocolR);
        d = _swap(key, true, 1 ether, 0, "");
        s = (_paid(bountyEoa) - b0) + (_paid(protocolR) - p0);
        r = uint256(-int256(d.amount0())) - s;
        assertEq(s, (r * BASELINE) / (D - BASELINE));
        assertEq(_escrowed(address(swapRouter)), 0);
    }

    // ─── b7 / H8: hook caps every module at createdAt + MAX_MEV_WINDOW ───

    function test_hookV2_lockEndsAtCapEvenIfModuleLies() public onlyFork {
        HV2LyingModule m = new HV2LyingModule(address(hook), 95_000);
        Launch memory l = _defaults(bountyEoa);
        l.module = address(m);
        (PoolKey memory key,) = _launch(l);
        uint256 t0 = block.timestamp;

        // skim clamped to MAX_SKIM_BPS, add locked
        assertEq(_skimOfBuy1Eth(key, bountyEoa), (1 ether * uint256(Constants.MAX_SKIM_BPS)) / D);
        vm.warp(t0 + Constants.MAX_MEV_WINDOW - 1);
        vm.expectRevert();
        _modify(key, -2000, 2000, 1e18, bytes32(uint256(5)));

        // module still claims an open window; the hook ignores it
        vm.warp(t0 + Constants.MAX_MEV_WINDOW);
        (, bool active) = IArtCoinsMevSkimV2(address(m)).currentSkimBps(key.toId());
        assertTrue(active);
        _modify(key, -2000, 2000, 1e18, bytes32(uint256(5)));
        assertEq(_skimOfBuy1Eth(key, bountyEoa), (1 ether * BASELINE) / D, "baseline after cap");
    }

    function test_hookV2_realModule_decaysAndUnlocks() public onlyFork {
        ArtCoinsMevLinearSkimV2 m = new ArtCoinsMevLinearSkimV2(address(hook));
        Launch memory l = _defaults(bountyEoa);
        l.module = address(m);
        l.mevConfig = abi.encode(uint24(68_690), uint32(600));
        (PoolKey memory key,) = _launch(l);
        uint256 t0 = block.timestamp;
        assertEq(m.windowEnd(key.toId()), t0 + 600);
        assertEq(m.schedule(key.toId()).endSkimBps, BASELINE, "decays to the pool baseline");

        assertEq(_skimOfBuy1Eth(key, bountyEoa), (1 ether * 68_690) / D);
        vm.expectRevert();
        _modify(key, -2000, 2000, 1e18, bytes32(uint256(5)));

        vm.warp(t0 + 600);
        _modify(key, -2000, 2000, 1e18, bytes32(uint256(5)));
        assertEq(_skimOfBuy1Eth(key, bountyEoa), (1 ether * BASELINE) / D);
    }

    function test_mevV2_durationAboveCap_reverts() public onlyFork {
        ArtCoinsMevLinearSkimV2 m = new ArtCoinsMevLinearSkimV2(address(hook));
        Launch memory l = _defaults(bountyEoa);
        l.module = address(m);
        ArtCoinsTokenV2 token = _newToken(0, bountyEoa, address(hook));
        PoolKey memory key = hook.initializePool(_params(l, address(token)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsMevSkimV2.WindowOutOfBounds.selector,
                Constants.MAX_MEV_WINDOW + 1,
                Constants.MIN_MEV_WINDOW,
                Constants.MAX_MEV_WINDOW
            )
        );
        hook.initializeMevModule(key, abi.encode(uint24(68_690), uint32(Constants.MAX_MEV_WINDOW + 1)));
    }

    function test_hookV2_revertingModule_failsOpenToBaseline() public onlyFork {
        HV2RevertingModule m = new HV2RevertingModule();
        Launch memory l = _defaults(bountyEoa);
        l.module = address(m);
        (PoolKey memory key,) = _launch(l);
        assertEq(_skimOfBuy1Eth(key, bountyEoa), (1 ether * BASELINE) / D);
        _modify(key, -2000, 2000, 1e18, bytes32(uint256(5)));
    }

    function test_hookV2_initializeMevModule_onceAndLauncherOnly() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        vm.expectRevert(IArtCoinsHookV2.MevModuleAlreadyInitialized.selector);
        hook.initializeMevModule(key, "");
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IArtCoinsHookV2.NotLauncher.selector);
        hook.initializeMevModule(key, "");
    }

    // ─── d3 / H11: no open pools, official pools distinguishable ─────────

    function test_hookV2_noOpenInit() public {
        // v1 open entry point is gone; no fallback answers it
        (bool ok,) = address(hook).call(
            abi.encodeWithSignature(
                "initializePoolOpen(address,address,int24,int24,bytes)",
                address(1),
                address(0),
                int24(0),
                TS,
                ""
            )
        );
        assertFalse(ok, "no open init selector");
        // initializePool is launcher only
        IArtCoinsHookV2.PoolInitParams memory p = _params(_defaults(bountyEoa), address(1));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IArtCoinsHookV2.NotLauncher.selector);
        hook.initializePool(p);
        // a disabled launcher is refused too
        hook.setLauncher(address(this), false);
        vm.expectRevert(IArtCoinsHookV2.NotLauncher.selector);
        hook.initializePool(p);
    }

    function test_hookV2_directPoolManagerInit_reverts() public onlyFork {
        ArtCoinsTokenV2 token = _newToken(0, bountyEoa, address(hook));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TS,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));
        // and for any foreign coin or fee tier
        key.currency1 = Currency.wrap(address(new HV2EmptyFallback()));
        key.fee = 3000;
        vm.expectRevert();
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function test_hookV2_poolInfo_matchesLaunch() public onlyFork {
        HV2Extension ext = new HV2Extension(address(hook));
        allowlist.setPoolExtension(address(ext), true);
        ArtCoinsMevLinearSkimV2 m = new ArtCoinsMevLinearSkimV2(address(hook));
        Launch memory l = _defaults(bountyEoa);
        l.taxMode = Constants.TAX_MODE_VENUE;
        l.module = address(m);
        l.extension = address(ext);
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(l);
        PoolId pid = key.toId();

        IArtCoinsHookV2.PoolInfo memory info = hook.poolInfo(pid);
        assertEq(info.version, Constants.STACK_VERSION);
        assertEq(info.taxMode, Constants.TAX_MODE_VENUE);
        assertEq(info.createdAt, block.timestamp);
        assertEq(info.launcher, address(this));
        assertEq(info.token, address(token));
        assertEq(info.locker, address(lockerStub));
        assertEq(info.mevModule, address(m));
        assertEq(info.extension, address(ext));
        assertTrue(hook.isOfficialPool(pid));
        assertEq(PoolId.unwrap(pid), token.canonicalPoolId());
        assertEq(_lpFee(key), LP_FEE, "lp fee frozen at init");

        IArtCoinsHookV2.SkimConfig memory c = hook.skimConfig(pid);
        assertEq(c.baselineSkimBps, BASELINE);
        assertEq(c.bountyBps, BOUNTY_BPS);
        assertEq(c.maxReferralBpsOfVolume, MAX_REF);
        assertEq(c.lpFee, LP_FEE);
        assertEq(c.bountyRecipient, bountyEoa);
        assertEq(c.protocolRecipient, protocolR);
        assertEq(c.referralPayout, address(payout));
        assertEq(c.quoteToken, address(0));

        // a pool id nobody launched is not official
        assertFalse(hook.isOfficialPool(PoolId.wrap(bytes32(uint256(1)))));
        assertEq(ext.preSetups(), 1);
        assertEq(ext.postSetups(), 1);
    }

    function test_versionTag_consistentAcrossTokenHookFactory() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(_defaults(bountyEoa));
        assertEq(hook.poolInfo(key.toId()).version, token.launcherVersion());
        assertEq(token.launcherVersion(), Constants.STACK_VERSION);
        assertEq(token.launcher(), hook.poolInfo(key.toId()).launcher);
    }

    function test_hookV2_tokenMustNameThisHook() public onlyFork {
        ArtCoinsTokenV2 token = _newToken(0, bountyEoa, makeAddr("otherHook"));
        IArtCoinsHookV2.PoolInitParams memory p = _params(_defaults(bountyEoa), address(token));
        vm.expectRevert(IArtCoinsHookV2.CanonicalHookMismatch.selector);
        hook.initializePool(p);
        // tick spacing must match the token's pinned pool id
        token = _newToken(0, bountyEoa, address(hook));
        p = _params(_defaults(bountyEoa), address(token));
        p.tickSpacing = 60;
        vm.expectRevert(IArtCoinsHookV2.CanonicalHookMismatch.selector);
        hook.initializePool(p);
    }

    function test_hookV2_extensionMustBeAllowlisted() public onlyFork {
        HV2Extension ext = new HV2Extension(address(hook));
        ArtCoinsTokenV2 token = _newToken(0, bountyEoa, address(hook));
        Launch memory l = _defaults(bountyEoa);
        l.extension = address(ext);
        IArtCoinsHookV2.PoolInitParams memory p = _params(l, address(token));
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.ExtensionNotAllowed.selector, address(ext))
        );
        hook.initializePool(p);
    }

    // ─── d5: constants checked at init ───────────────────────────────────

    function test_constants_mismatchedModule_rejected() public {
        HV2ConstantsStub bad = new HV2ConstantsStub(keccak256("other"));
        Launch memory l = _defaults(bountyEoa);
        l.module = address(bad);
        IArtCoinsHookV2.PoolInitParams memory p = _params(l, address(1));
        vm.expectRevert(abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(bad)));
        hook.initializePool(p);

        p = _params(_defaults(bountyEoa), address(1));
        p.locker = address(bad);
        vm.expectRevert(abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(bad)));
        hook.initializePool(p);

        // a codeless "module" is refused as well
        p = _params(_defaults(bountyEoa), address(1));
        p.mevModule = makeAddr("eoaModule");
        vm.expectRevert(
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, p.mevModule)
        );
        hook.initializePool(p);
    }

    function test_skimConfig_bounds() public {
        IArtCoinsHookV2.PoolInitParams memory p = _params(_defaults(bountyEoa), address(1));
        p.skim.lpFee = Constants.MAX_LP_FEE + 1;
        vm.expectRevert(IArtCoinsHookV2.LpFeeTooHigh.selector);
        hook.initializePool(p);

        p = _params(_defaults(bountyEoa), address(1));
        p.skim.baselineSkimBps = Constants.MAX_BASELINE_SKIM_BPS + 1;
        vm.expectRevert(IArtCoinsHookV2.BaselineSkimBpsTooHigh.selector);
        hook.initializePool(p);

        p = _params(_defaults(bountyEoa), address(1));
        p.skim.bountyBps = Constants.MAX_BOUNTY_BPS + 1;
        vm.expectRevert(IArtCoinsHookV2.BadLegBps.selector);
        hook.initializePool(p);

        p = _params(_defaults(bountyEoa), address(1));
        p.skim.maxReferralBpsOfVolume = Constants.MAX_REFERRAL_CAP_OF_VOLUME + 1;
        vm.expectRevert(IArtCoinsHookV2.MaxReferralTooHigh.selector);
        hook.initializePool(p);

        p = _params(_defaults(address(0)), address(1));
        vm.expectRevert(IArtCoinsHookV2.BountyRecipientZero.selector);
        hook.initializePool(p);

        p = _params(_defaults(bountyEoa), address(1));
        p.skim.protocolRecipient = payable(address(0));
        vm.expectRevert(IArtCoinsHookV2.ProtocolRecipientZero.selector);
        hook.initializePool(p);

        // H3: a codeless referral payout would revert referred swaps
        p = _params(_defaults(bountyEoa), address(1));
        p.skim.referralPayout = payable(makeAddr("eoaPayout"));
        vm.expectRevert(IArtCoinsHookV2.ReferralPayoutZero.selector);
        hook.initializePool(p);

        p = _params(_defaults(bountyEoa), address(1));
        p.skim.quoteToken = address(2);
        vm.expectRevert(IArtCoinsHookV2.QuoteTokenMustBeNative.selector);
        hook.initializePool(p);
    }

    // ─── d1 / D16 / H13: referral leg ────────────────────────────────────

    function test_referral_paidAndCapped() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        address ref = makeAddr("ref");
        uint256 p0 = protocolR.balance;
        _swap(key, true, -1 ether, 0, _attribution(ref, 1000)); // asks 1%, cap 0.25%
        uint256 referral = (1 ether * uint256(MAX_REF)) / D;
        assertEq(payout.credited(ref), referral);
        (, uint256 protocol) = _legs((1 ether * BASELINE) / D, BASELINE);
        assertEq(protocolR.balance - p0, protocol - referral, "referral comes out of protocol");
    }

    function test_referral_selfReferralByCaller_refused() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        uint256 p0 = protocolR.balance;
        _swap(key, true, -1 ether, 0, _attribution(address(swapRouter), 250));
        assertEq(payout.credited(address(swapRouter)), 0, "caller cannot name itself");
        (, uint256 protocol) = _legs((1 ether * BASELINE) / D, BASELINE);
        assertEq(protocolR.balance - p0, protocol, "protocol leg intact");
    }

    function test_referral_payoutReverts_creditsReferrer() public onlyFork {
        HV2RevertingPayout bad = new HV2RevertingPayout();
        Launch memory l = _defaults(bountyEoa);
        l.referralPayout = address(bad);
        (PoolKey memory key,) = _launch(l);
        address ref = makeAddr("ref");
        _swap(key, true, -1 ether, 0, _attribution(ref, 250));
        assertEq(_escrowed(ref), (1 ether * uint256(MAX_REF)) / D, "referrer credited, not protocol");
    }

    function test_hookData_malformed_neverReverts() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        _swap(key, true, -0.1 ether, 0, hex"deadbeef");
        _swap(key, true, -0.1 ether, 0, abi.encode(uint256(type(uint256).max), uint256(7), uint256(9)));
        bytes memory junk = new bytes(300);
        for (uint256 i; i < 300; ++i) {
            junk[i] = bytes1(uint8(i * 7));
        }
        _swap(key, false, -0.1 ether, 0, junk);
    }

    // ─── N2: extension sees the trader facing realized delta ────────────

    function test_extension_seesRealizedTraderDelta() public onlyFork {
        HV2Extension ext = new HV2Extension(address(hook));
        allowlist.setPoolExtension(address(ext), true);
        Launch memory l = _defaults(bountyEoa);
        l.extension = address(ext);
        (PoolKey memory key,) = _launch(l);
        bytes memory hd = _attribution(makeAddr("ref"), 100);
        BalanceDelta d = _swap(key, true, -100 ether, TickMath.getSqrtPriceAtTick(-100), hd);
        assertEq(ext.swaps(), 1);
        // trader paid paid = r + charged at the PoolManager, refund comes back via escrow
        uint256 refund = _escrowed(address(swapRouter));
        assertEq(int256(ext.lastAmount0()), int256(d.amount0()) + int256(refund));
        assertEq(
            keccak256(ext.lastData()),
            keccak256(abi.decode(hd, (IArtCoinsHook.PoolSwapData)).poolExtensionSwapData)
        );
    }

    // ─── b1 / H14 / d2: tax attestations and flow grants ─────────────────

    function test_tax_addThenRemoveSameTx_mintsNoBudget() public onlyFork {
        Launch memory l = _defaults(bountyEoa);
        l.taxMode = Constants.TAX_MODE_VENUE;
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(l);
        HV2AddRemoveRouter router = _fundedRouter(token);
        (uint256 b0,,) = token.pendingCanonical();
        router.run(key, -2000, 2000, 50e18, bytes32(uint256(7)), 0);
        (uint256 b1,,) = token.pendingCanonical();
        assertEq(b1, b0, "add then remove attests nothing");
    }

    function test_hard_addThenRemoveSameTx_grantsNoOutflow() public onlyFork {
        Launch memory l = _defaults(bountyEoa);
        l.taxMode = Constants.TAX_MODE_HARD;
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(l);
        HV2AddRemoveRouter router = _fundedRouter(token);
        (, uint256 o0,) = token.pendingCanonical();
        router.run(key, -2000, 2000, 50e18, bytes32(uint256(7)), 0);
        (, uint256 o1,) = token.pendingCanonical();
        assertEq(o1, o0, "no outflow grant");
    }

    function test_venue_canonicalBuy_untaxed() public onlyFork {
        Launch memory l = _defaults(bountyEoa);
        l.taxMode = Constants.TAX_MODE_VENUE;
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(l);
        uint256 dead0 = token.balanceOf(Constants.DEAD);
        uint256 bal0 = token.balanceOf(address(this));
        BalanceDelta d = _swap(key, true, -1 ether, 0, "");
        assertEq(token.balanceOf(address(this)) - bal0, uint256(int256(d.amount1())), "buy untaxed");
        assertEq(token.balanceOf(Constants.DEAD), dead0);
    }

    function test_hard_launchLiquidityPlacement_pass() public onlyFork {
        Launch memory l = _defaults(bountyEoa);
        l.taxMode = Constants.TAX_MODE_HARD;
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(l);
        assertEq(hook.poolInfo(key.toId()).taxMode, Constants.TAX_MODE_HARD);
        assertGt(token.balanceOf(address(pm)), 0, "launch liquidity placed");
    }

    function test_hard_canonicalBuyAndSell_pass() public onlyFork {
        Launch memory l = _defaults(bountyEoa);
        l.taxMode = Constants.TAX_MODE_HARD;
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(l);
        _swap(key, true, -1 ether, 0, "");
        _swap(key, false, -1 ether, 0, "");
        _swap(key, true, 1 ether, 0, "");
        _swap(key, false, 0.5 ether, 0, "");
        (, uint256 o, uint256 i) = token.pendingCanonical();
        assertEq(o, 0, "outflow grants consumed exactly");
        assertEq(i, 0, "inflow grants consumed exactly");
    }

    function _fundedRouter(ArtCoinsTokenV2 token) internal returns (HV2AddRemoveRouter router) {
        router = new HV2AddRemoveRouter(pm);
        vm.deal(address(router), 200 ether);
        token.transfer(address(router), 200e18);
    }

    // ─── invariants ──────────────────────────────────────────────────────

    function test_hookHoldsNothing_afterEverySwapShape() public onlyFork {
        HV2ReturnBomb r = new HV2ReturnBomb();
        vm.deal(address(r), 1 ether);
        PoolKey memory key = _launchSimple(address(r));
        // _swap asserts zero erc6909 claims and zero eth on the hook after each
        _swap(key, true, -1 ether, 0, "");
        _swap(key, true, 1 ether, 0, "");
        _swap(key, false, -1 ether, 0, "");
        _swap(key, false, 1 ether, 0, "");
        _swap(key, true, -50 ether, TickMath.getSqrtPriceAtTick(-60), "");
        _swap(key, false, 50 ether, TickMath.getSqrtPriceAtTick(60), "");
        _swap(key, true, -1, 0, ""); // dust: zero skim
    }

    function test_rescueClaims_sendsStrayClaims() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        swapRouter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        uint256 id = key.currency1.toId();
        uint256 c = pm.balanceOf(address(this), id);
        assertGt(c, 0);
        pm.transfer(address(hook), id, c);
        address to = makeAddr("rescueTo");
        hook.rescueClaims(key.currency1, to, c);
        assertEq(pm.balanceOf(to, id), c);
        assertEq(pm.balanceOf(address(hook), id), 0);
    }

    // ─── owner and globals (no fork needed) ──────────────────────────────

    function test_hookAddress_flags() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x2dcc);
        assertEq(hook.constantsHash(), Constants.hash());
    }

    function test_globals_defaults() public view {
        IArtCoinsHookV2.HookGlobals memory g = hook.globals();
        assertEq(g.pushGas, Constants.PUSH_GAS_DEFAULT);
        assertEq(g.preSwapStreamGas, Constants.STREAM_GAS_DEFAULT);
        assertEq(g.preSwapStreamMin, Constants.STREAM_MIN_BALANCE_DEFAULT);
        assertEq(g.feeEscrow, address(escrow));
        assertEq(g.extensionAllowlist, address(allowlist));
        assertTrue(hook.isLauncher(address(this)));
        assertEq(hook.owner(), address(this));
    }

    function test_owner_setDeliveryParams_bounded() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsHookV2.ParamOutOfBounds.selector,
                uint256(Constants.PUSH_GAS_MIN - 1),
                uint256(Constants.PUSH_GAS_MIN),
                uint256(Constants.PUSH_GAS_MAX)
            )
        );
        hook.setDeliveryParams(Constants.PUSH_GAS_MIN - 1, Constants.STREAM_GAS_DEFAULT, 0);
        vm.expectRevert();
        hook.setDeliveryParams(Constants.PUSH_GAS_MAX + 1, Constants.STREAM_GAS_DEFAULT, 0);
        vm.expectRevert();
        hook.setDeliveryParams(Constants.PUSH_GAS_DEFAULT, Constants.STREAM_GAS_MIN - 1, 0);
        vm.expectRevert();
        hook.setDeliveryParams(Constants.PUSH_GAS_DEFAULT, Constants.STREAM_GAS_MAX + 1, 0);
        vm.expectRevert();
        hook.setDeliveryParams(
            Constants.PUSH_GAS_DEFAULT, Constants.STREAM_GAS_DEFAULT, Constants.STREAM_MIN_BALANCE_MAX + 1
        );

        vm.expectEmit(address(hook));
        emit IArtCoinsHookV2.DeliveryParamsSet(20_000, 40_000, 1 ether);
        hook.setDeliveryParams(20_000, 40_000, 1 ether);
        IArtCoinsHookV2.HookGlobals memory g = hook.globals();
        assertEq(g.pushGas, 20_000);
        assertEq(g.preSwapStreamGas, 40_000);
        assertEq(g.preSwapStreamMin, 1 ether);
    }

    function test_owner_onlyOwner() public {
        address s = makeAddr("stranger");
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, s);
        vm.startPrank(s);
        vm.expectRevert(err);
        hook.setLauncher(s, true);
        vm.expectRevert(err);
        hook.setFeeEscrow(address(escrow));
        vm.expectRevert(err);
        hook.setExtensionAllowlist(address(0));
        vm.expectRevert(err);
        hook.setDeliveryParams(Constants.PUSH_GAS_DEFAULT, Constants.STREAM_GAS_DEFAULT, 0);
        vm.expectRevert(err);
        hook.rescue(address(0), s, 0);
        vm.expectRevert(err);
        hook.rescueClaims(Currency.wrap(address(0)), s, 0);
        vm.stopPrank();
    }

    function test_owner_setFeeEscrow_checksConstants() public {
        HV2ConstantsStub bad = new HV2ConstantsStub(keccak256("other"));
        vm.expectRevert(abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(bad)));
        hook.setFeeEscrow(address(bad));
        HV2ConstantsStub good = new HV2ConstantsStub(Constants.hash());
        vm.expectEmit(address(hook));
        emit IArtCoinsHookV2.FeeEscrowSet(address(escrow), address(good));
        hook.setFeeEscrow(address(good));
        assertEq(hook.globals().feeEscrow, address(good));
        vm.expectRevert(IArtCoinsHookV2.ZeroAddress.selector);
        hook.setLauncher(address(0), true);
    }

    function test_owner_twoStepTransfer() public {
        address n = makeAddr("newOwner");
        hook.transferOwnership(n);
        assertEq(hook.owner(), address(this));
        vm.prank(n);
        hook.acceptOwnership();
        assertEq(hook.owner(), n);
    }

    function test_receive_onlyPoolManager() public {
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "stray eth refused");
    }

    function test_rescue_eth() public {
        vm.deal(address(hook), 1 ether); // forced in (selfdestruct style)
        address to = makeAddr("rescueTo");
        hook.rescue(address(0), to, 1 ether);
        assertEq(to.balance, 1 ether);
        vm.expectRevert(IArtCoinsHookV2.ZeroAddress.selector);
        hook.rescue(address(0), address(0), 0);
    }

    // ─── hookData parser ─────────────────────────────────────────────────

    function test_calldata_decodesAttribution() public {
        HV2CalldataHarness h = new HV2CalldataHarness();
        address ref = makeAddr("ref");
        bytes memory hd = _attribution(ref, 123);
        (bytes memory ext, HookCalldata.Attribution memory att) = h.decode(hd);
        assertEq(att.referrer, ref);
        assertEq(att.referralBps, 123);
        assertEq(att.sourceId, bytes32("src"));
        assertEq(att.campaignId, bytes16("cmp"));
        assertEq(
            keccak256(ext), keccak256(abi.decode(hd, (IArtCoinsHook.PoolSwapData)).poolExtensionSwapData)
        );
        (ext, att) = h.decode("");
        assertEq(ext.length, 0);
        assertEq(att.referrer, address(0));
    }

    function testFuzz_calldata_neverReverts(bytes calldata junk) public {
        HV2CalldataHarness h = new HV2CalldataHarness();
        h.decode(junk);
        // and a valid outer frame around junk
        h.decode(
            abi.encode(
                IArtCoinsHook.PoolSwapData({mevModuleSwapData: junk, poolExtensionSwapData: junk})
            )
        );
    }
}

/// tests that need a position created in an earlier tx (setUp is its own tx,
/// so the same tx position marker is clear when the test body runs).
abstract contract HookV2PriorTxBase is HookV2ForkBase {
    PoolKey internal key;
    ArtCoinsTokenV2 internal token;
    HV2AddRemoveRouter internal router;
    bytes32 internal constant SALT = bytes32(uint256(9));
    uint256 internal constant POS_LIQ = 20e18;

    function _mode() internal pure virtual returns (uint8);

    function setUp() public virtual override {
        super.setUp();
        if (!onFork) return;
        Launch memory l = _defaults(bountyEoa);
        l.taxMode = _mode();
        (key, token) = _launch(l);
        router = new HV2AddRemoveRouter(pm);
        vm.deal(address(router), 200 ether);
        token.transfer(address(router), 200e18);
        router.run(key, -2000, 2000, POS_LIQ, SALT, 2);
        // a sell accrues coin side fees to the position
        _swap(key, false, -20 ether, 0, "");
    }
}

contract HookV2PriorTxVenueTest is HookV2PriorTxBase {
    function _mode() internal pure override returns (uint8) {
        return Constants.TAX_MODE_VENUE;
    }

    function test_tax_priorTxLpExit_isExempt() public onlyFork {
        uint256 bal0 = token.balanceOf(address(this));
        uint256 dead0 = token.balanceOf(Constants.DEAD);
        router.run(key, -2000, 2000, POS_LIQ, SALT, 3);
        uint256 taken = router.lastTake1();
        assertGt(taken, 0);
        assertEq(token.balanceOf(address(this)) - bal0, taken, "lp exit untaxed");
        assertEq(token.balanceOf(Constants.DEAD), dead0);
    }

    function test_tax_lockerCollect_isExempt() public onlyFork {
        uint256 bal0 = token.balanceOf(address(this));
        router.run(key, -2000, 2000, 0, SALT, 3); // zero liquidity: fee collect
        uint256 taken = router.lastTake1();
        assertGt(taken, 0, "coin fees accrued");
        assertEq(token.balanceOf(address(this)) - bal0, taken, "fee collect untaxed");
    }

    /// documents the residual the design accepts (DESIGN b1 invariant): a
    /// position that existed before the tx can be removed and re added in one
    /// unlock; the removal attests its coin side although no coin leaves the
    /// PoolManager. bounded by the position's own coin amount, no cost.
    function test_residual_removeThenAddSameTx_boundedByPriorPosition() public onlyFork {
        (uint256 b0,,) = token.pendingCanonical();
        router.run(key, -2000, 2000, POS_LIQ, SALT, 1);
        (uint256 b1,,) = token.pendingCanonical();
        assertGt(b1, b0);
        assertLt(b1 - b0, 200e18, "bounded by the prior position");
    }
}

contract HookV2PriorTxHardTest is HookV2PriorTxBase {
    function _mode() internal pure override returns (uint8) {
        return Constants.TAX_MODE_HARD;
    }

    function test_hard_priorTxLpExit_pass() public onlyFork {
        uint256 bal0 = token.balanceOf(address(this));
        router.run(key, -2000, 2000, POS_LIQ, SALT, 3);
        assertEq(token.balanceOf(address(this)) - bal0, router.lastTake1());
        (, uint256 o,) = token.pendingCanonical();
        assertEq(o, 0, "grant consumed exactly");
    }

    function test_hard_lockerCollect_pass() public onlyFork {
        router.run(key, -2000, 2000, 0, SALT, 3);
        assertGt(router.lastTake1(), 0);
        (, uint256 o,) = token.pendingCanonical();
        assertEq(o, 0);
    }
}
