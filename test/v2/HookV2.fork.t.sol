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
    HV2HostileRecipient,
    HV2LyingModule,
    HV2Rejecter,
    HV2ReturnBomb,
    HV2RevertingModule,
    HV2StreamRecipient,
    HV2SwapSeqRouter
} from "./mocks/HookV2Mocks.sol";

import {Constants} from "../../src/Constants.sol";
import {IArtCoinsHook} from "../../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsFeeEscrowV2} from "../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {ArtCoinsTokenV2} from "../../src/v2/ArtCoinsTokenV2.sol";
import {ArtCoinsHookV2} from "../../src/v2/hooks/ArtCoinsHookV2.sol";
import {HookCalldata} from "../../src/v2/hooks/libraries/HookCalldata.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsMevSkimV2} from "../../src/v2/interfaces/IArtCoinsMevSkimV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";
import {ArtCoinsLpLockerV2} from "../../src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";
import {ArtCoinsMevLinearSkimV2} from "../../src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// v4 periphery ExactInputSingleParams as the live universal router decodes it.
struct URExactInSingle {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

interface IUniversalRouterLike {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

/// exposes the internal hookData parser.
contract HV2CalldataHarness {
    function refundTo(bytes calldata d) external pure returns (address) {
        return HookCalldata.refundTo(d);
    }

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
    function _legs(uint256 skim, uint256 bps)
        internal
        pure
        returns (uint256 bounty, uint256 protocol)
    {
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
        token = _newToken(l.restricted, l.bounty, address(hook));
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
        (uint256 bounty,) = _legs((1 ether * uint256(BASELINE)) / D, BASELINE);
        assertGe(bountyEoa.balance - b0, bounty, "bounty pushed to the eoa");
        assertEq(_escrowed(bountyEoa), 0);
    }

    function test_swap_bountyEmptyFallback_noRevert() public onlyFork {
        HV2EmptyFallback r = new HV2EmptyFallback();
        vm.deal(address(r), 1 ether);
        PoolKey memory key = _launchSimple(address(r));
        uint256 b0 = address(r).balance;
        _swap(key, true, -1 ether, 0, "");
        (uint256 bounty,) = _legs((1 ether * uint256(BASELINE)) / D, BASELINE);
        assertEq(address(r).balance - b0, bounty, "pushed, empty fallback accepts eth");
        // and again once its balance is far above the stream floor
        _swap(key, true, -1 ether, 0, "");
    }

    function test_swap_bountyReturnBomb_bounded() public onlyFork {
        uint256 refGas = _refSwapGas();
        HV2ReturnBomb r = new HV2ReturnBomb();
        vm.deal(address(r), 1 ether);
        PoolKey memory key = _launchSimple(address(r));
        _swap(key, true, -0.1 ether, 0, ""); // warm the pool and the escrow slot
        uint256 g0 = gasleft();
        _swap(key, true, -1 ether, 0, "");
        uint256 used = g0 - gasleft();
        // the push carries only the 2,300 stipend; 100kb of returndata runs
        // the bomb out of gas, nothing is copied, the leg lands in escrow
        assertLt(used, refGas + 20_000, "return bomb bounded");
        (uint256 bounty,) = _legs((1 ether * uint256(BASELINE)) / D, BASELINE);
        assertGe(_escrowed(address(r)), bounty, "escrowed");
        assertEq(address(r).balance, 1 ether);
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
        // stipend only push (D41) + a warm escrow credit
        assertLt(used, refGas + 20_000, "gas burner bounded");
        assertGt(_escrowed(address(r)), 0, "bounty escrowed");
    }

    function test_swap_bountyRejectsEth_escrowed() public onlyFork {
        HV2Rejecter r = new HV2Rejecter();
        vm.deal(address(r), 1 ether); // streamForward reverts too, and is probed
        PoolKey memory key = _launchSimple(address(r));
        uint256 skim = (1 ether * uint256(BASELINE)) / D;
        (uint256 bounty,) = _legs(skim, BASELINE);
        vm.expectEmit(true, true, true, true, address(hook));
        emit IArtCoinsHookV2.FeeDelivered(
            key.toId(), Constants.LEG_BOUNTY, address(r), bounty, true
        );
        _swap(key, true, -1 ether, 0, "");
        assertEq(_escrowed(address(r)), bounty);
        assertEq(address(r).balance, 1 ether);
    }

    function test_swap_protocolRejectsOrBurnsGas_escrowed() public onlyFork {
        HV2Rejecter rej = new HV2Rejecter();
        (PoolKey memory key,) = _launchProtocol(_defaults(bountyEoa), address(rej));
        _swap(key, true, -1 ether, 0, "");
        (, uint256 protocol) = _legs((1 ether * uint256(BASELINE)) / D, BASELINE);
        assertEq(_escrowed(address(rej)), protocol);

        HV2GasBurner burner = new HV2GasBurner();
        (key,) = _launchProtocol(_defaults(bountyEoa), address(burner));
        _swap(key, true, -1 ether, 0, "");
        assertEq(_escrowed(address(burner)), protocol);
    }

    /// D41: no `streamForward` probe, whatever the recipient's balance.
    function test_swap_noStreamProbe() public onlyFork {
        HV2StreamRecipient r = new HV2StreamRecipient();
        vm.deal(address(r), 100 ether);
        PoolKey memory key = _launchSimple(address(r));
        uint256 b0 = address(r).balance;
        _swap(key, true, -1 ether, 0, "");
        assertEq(r.streams(), 0, "never probed");
        (uint256 bounty,) = _legs((1 ether * uint256(BASELINE)) / D, BASELINE);
        assertEq(address(r).balance - b0, bounty, "empty receive gets the stipend push");
    }

    /// V2H-01 regression: a recipient that acts on the PoolManager from
    /// `receive` (take 1 wei, sync the coin, mint a claim) while the swapper's
    /// unlock is open cannot revert the swap. PoolSwapTest settles native eth
    /// without syncing, so a surviving coin sync would revert it too.
    function test_swap_hostileRecipient_cannotRevertSwap() public onlyFork {
        uint8[3] memory modes = [uint8(0), 2, 3];
        for (uint256 i; i < 3; ++i) {
            HV2HostileRecipient r = new HV2HostileRecipient(pm, modes[i]);
            (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(_defaults(address(r)));
            r.setCoin(address(token));
            _swap(key, true, -1 ether, 0, ""); // buy: eth settled after the push
            _swap(key, false, -1 ether, 0, ""); // sell
            // modes 0 and 3 run out of gas (escrowed); a coin sync may fit the
            // stipend and is undone by the hook. either way the swaps settled.
            assertGt(address(r).balance + _escrowed(address(r)), 0, "legs delivered");
            assertEq(pm.balanceOf(address(r), 0), 0, "no claim minted");
        }
    }

    /// V2H-01 regression: a VENUE bounty recipient that tries to spend the
    /// buyer's exemption (take coin from the PoolManager inside `receive`)
    /// fails; the buyer's take stays fully exempt (expected tax 0).
    // ─── b3 / H4 H5: skim on the realized fill, unfilled share refunded ───

    function test_skim_fullFill_noRefund() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        uint256 skim = _skimOfBuy1Eth(key, bountyEoa);
        assertEq(skim, (1 ether * uint256(BASELINE)) / D);
        assertEq(_escrowed(address(swapRouter)), 0, "no refund");
    }

    /// b3: the unfilled skim of a price limited exact in buy is credited in
    /// escrow; the returned BalanceDelta and the transient delta agree, so
    /// both router styles (settle returned delta: PoolSwapTest; settle
    /// currencyDelta: seq) settle cleanly.
    function test_skim_exactInPriceLimited_refundsUnfilled() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        uint256 a = 100 ether;
        uint256 charged = (a * BASELINE) / D;
        uint256 requested = a - charged;
        uint160 lim = TickMath.getSqrtPriceAtTick(-100);
        uint256 b0 = _paid(bountyEoa);
        uint256 p0 = _paid(protocolR);

        (int256 net0,) = _swapNet(key, true, -int256(a), lim, "");
        assertEq(seq.lastReturned0(), net0, "returned delta == transient delta");

        uint256 fair = (_paid(bountyEoa) - b0) + (_paid(protocolR) - p0);
        uint256 r = uint256(-net0) - charged; // realized pool input
        assertLt(r, requested / 4, "partial fill");
        assertEq(fair, (charged * r) / requested, "legs on the fill");
        assertEq(_escrowed(address(seq)), charged - fair, "unfilled skim refunded");
        assertApproxEqRel(fair * D, (r + fair) * BASELINE, 1e12);

        // a router that settles the returned delta works too
        _swap(key, true, -int256(a), TickMath.getSqrtPriceAtTick(-200), "");
        assertGt(_escrowed(address(swapRouter)), 0);
    }

    function test_skim_exactOutPriceLimited_refundsUnfilled() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        uint256 a = 100 ether; // eth out requested
        uint256 charged = (a * BASELINE) / (D - BASELINE);
        uint256 requested = a + charged;
        uint256 b0 = _paid(bountyEoa);
        uint256 p0 = _paid(protocolR);

        (int256 net0,) = _swapNet(key, false, int256(a), TickMath.getSqrtPriceAtTick(100), "");
        assertEq(seq.lastReturned0(), net0, "returned delta == transient delta");

        int256 r = net0 + int256(charged); // realized pool output
        assertGt(r, 0);
        assertLt(uint256(r), requested / 4, "partial fill");
        uint256 fair = (_paid(bountyEoa) - b0) + (_paid(protocolR) - p0);
        assertEq(fair, (charged * uint256(r)) / requested);
        uint256 refund = charged - fair;
        assertEq(_escrowed(address(seq)), refund, "unfilled skim refunded");
        // V2H-06 (documented): net of the refund the seller receives eth
        assertGt(net0 + int256(refund), 0, "seller nets eth after the refund");

        // a router that settles the returned delta works too
        _swap(key, false, int256(a), TickMath.getSqrtPriceAtTick(200), "");
    }

    /// V2H-03: the swapper names a refund address in hookData; the unfilled
    /// skim is credited to it instead of the router.
    function test_skim_refundTo_fromHookData() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        address me = makeAddr("refundMe");
        _swapNet(key, true, -100 ether, TickMath.getSqrtPriceAtTick(-100), _refundData(me));
        assertGt(_escrowed(me), 0, "credited to the named address");
        assertEq(_escrowed(address(seq)), 0);
    }

    function _refundData(address to) internal pure returns (bytes memory) {
        return abi.encode(
            IArtCoinsHook.PoolSwapData({
                mevModuleSwapData: abi.encode(to), poolExtensionSwapData: ""
            })
        );
    }

    /// V2H-03 through the live universal router (V4Router settles the full
    /// debt, min price limit): a buy past the last launch position fills
    /// partially; with a refund address in hookData the unfilled skim is
    /// credited to the user, nothing is stranded under UR.
    function test_skim_universalRouterPartialFill_nothingInEscrow() public onlyFork {
        address ur = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
        ArtCoinsTokenV2 token = _newToken(false, bountyEoa, address(hook));
        PoolKey memory key = hook.initializePool(_params(_defaults(bountyEoa), address(token)));
        _modify(key, -2000, 2000, int256(LIQ), 0); // narrow: ~105 eth exhausts it
        hook.initializeMevModule(key, "");

        uint256 a = 300 ether;
        uint256 charged = (a * BASELINE) / D;
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            URExactInSingle(key, true, uint128(a), uint128(0), _refundData(address(this)))
        );
        params[1] = abi.encode(key.currency0, a);
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(address(0), address(this), uint256(0)); // sweep eth
        uint256 eth0 = address(this).balance;
        uint256 b0 = _paid(bountyEoa);
        uint256 p0 = _paid(protocolR);
        IUniversalRouterLike(ur).execute{value: a}(
            abi.encodePacked(uint8(0x10), uint8(0x04)), inputs, block.timestamp
        );

        uint256 spent = eth0 - address(this).balance; // r + charged
        uint256 fair = (_paid(bountyEoa) - b0) + (_paid(protocolR) - p0);
        uint256 r = spent - charged;
        assertLt(r, (a - charged) / 2, "partial fill");
        assertEq(fair, (charged * r) / (a - charged));
        assertEq(_escrowed(address(this)), charged - fair, "refund credited to the user");
        assertEq(_escrowed(ur), 0, "nothing stranded under UR");
        assertEq(ur.balance, 0);
        assertGt(token.balanceOf(address(this)), 0);
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
        assertEq(
            _skimOfBuy1Eth(key, bountyEoa), (1 ether * uint256(BASELINE)) / D, "baseline after cap"
        );
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
        assertEq(_skimOfBuy1Eth(key, bountyEoa), (1 ether * uint256(BASELINE)) / D);
    }

    function test_mevV2_durationAboveCap_reverts() public onlyFork {
        ArtCoinsMevLinearSkimV2 m = new ArtCoinsMevLinearSkimV2(address(hook));
        Launch memory l = _defaults(bountyEoa);
        l.module = address(m);
        ArtCoinsTokenV2 token = _newToken(false, bountyEoa, address(hook));
        PoolKey memory key = hook.initializePool(_params(l, address(token)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsMevSkimV2.WindowOutOfBounds.selector,
                Constants.MAX_MEV_WINDOW + 1,
                Constants.MIN_MEV_WINDOW,
                Constants.MAX_MEV_WINDOW
            )
        );
        hook.initializeMevModule(
            key, abi.encode(uint24(68_690), uint32(Constants.MAX_MEV_WINDOW + 1))
        );
    }

    function test_hookV2_revertingModule_failsOpenToBaseline() public onlyFork {
        HV2RevertingModule m = new HV2RevertingModule();
        Launch memory l = _defaults(bountyEoa);
        l.module = address(m);
        (PoolKey memory key,) = _launch(l);
        assertEq(_skimOfBuy1Eth(key, bountyEoa), (1 ether * uint256(BASELINE)) / D);
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
        (bool ok,) = address(hook)
            .call(
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
        ArtCoinsTokenV2 token = _newToken(false, bountyEoa, address(hook));
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
        l.restricted = true;
        l.module = address(m);
        l.extension = address(ext);
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(l);
        PoolId pid = key.toId();

        IArtCoinsHookV2.PoolInfo memory info = hook.poolInfo(pid);
        assertEq(info.version, Constants.STACK_VERSION);
        assertTrue(info.restricted);
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
        ArtCoinsTokenV2 token = _newToken(false, bountyEoa, makeAddr("otherHook"));
        IArtCoinsHookV2.PoolInitParams memory p = _params(_defaults(bountyEoa), address(token));
        vm.expectRevert(IArtCoinsHookV2.CanonicalHookMismatch.selector);
        hook.initializePool(p);
        // tick spacing must match the token's pinned pool id
        token = _newToken(false, bountyEoa, address(hook));
        p = _params(_defaults(bountyEoa), address(token));
        p.tickSpacing = 60;
        vm.expectRevert(IArtCoinsHookV2.CanonicalHookMismatch.selector);
        hook.initializePool(p);
    }

    function test_hookV2_extensionMustBeAllowlisted() public onlyFork {
        HV2Extension ext = new HV2Extension(address(hook));
        ArtCoinsTokenV2 token = _newToken(false, bountyEoa, address(hook));
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
        vm.expectRevert(
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(bad))
        );
        hook.initializePool(p);

        p = _params(_defaults(bountyEoa), address(1));
        p.locker = address(bad);
        vm.expectRevert(
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(bad))
        );
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

        // V2H-08: recipients that can never receive eth
        p = _params(_defaults(address(hook)), address(1));
        vm.expectRevert(
            abi.encodeWithSelector(ArtCoinsHookV2.RecipientCannotReceive.selector, address(hook))
        );
        hook.initializePool(p);
        p = _params(_defaults(bountyEoa), address(1));
        p.skim.protocolRecipient = payable(POOL_MANAGER);
        vm.expectRevert(
            abi.encodeWithSelector(ArtCoinsHookV2.RecipientCannotReceive.selector, POOL_MANAGER)
        );
        hook.initializePool(p);

    }

    // ─── d1 / D16 / H13: referral leg ────────────────────────────────────

    /// V2H-05: the referral base is the realized pool side quote amount `r`
    /// for every shape. exact in buy, full fill: r = a - skim.
    function test_referral_paidAndCapped() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        address ref = makeAddr("ref");
        uint256 p0 = protocolR.balance;
        _swap(key, true, -1 ether, 0, _attribution(ref, 1000)); // asks 1%, cap 0.25%
        uint256 skim = (1 ether * uint256(BASELINE)) / D;
        uint256 referral = ((1 ether - skim) * uint256(MAX_REF)) / D;
        assertEq(ref.balance, referral, "pushed to the referrer (D41)");
        (, uint256 protocol) = _legs(skim, BASELINE);
        assertEq(protocolR.balance - p0, protocol - referral, "referral comes out of protocol");

        // exact in sell: r = pool output before skim
        _checkSellReferral(key, ref);
    }

    function _checkSellReferral(PoolKey memory key, address ref) internal {
        uint256 r0 = ref.balance;
        BalanceDelta d = _swap(key, false, -1 ether, 0, _attribution(ref, 250));
        uint256 net = uint256(int256(d.amount0())); // r - skim
        uint256 r = (net * D) / (D - uint256(BASELINE)); // +-1
        assertApproxEqAbs(ref.balance - r0, (r * uint256(MAX_REF)) / D, 1);
    }

    /// D52 / V2F-01: referral cap at the 1% maximum and a referrer named:
    /// the protocol leg never drops below `minProtocolShareBps` of the
    /// baseline skim; the referral only takes what is above it.
    function test_referral_neverBelowProtocolFloor() public onlyFork {
        ArtCoinsTokenV2 t = _newToken(false, bountyEoa, address(hook));
        Launch memory l = _defaults(bountyEoa);
        l.baseline = 1000; // 1% of volume
        l.bountyBps = 7000;
        l.maxRef = Constants.MAX_REFERRAL_CAP_OF_VOLUME; // 1% of volume
        IArtCoinsHookV2.PoolInitParams memory p = _params(l, address(t));
        p.minProtocolShareBps = 2000;
        PoolKey memory k = hook.initializePool(p);
        _modify(k, FULL_LO, FULL_HI, int256(LIQ), 0);
        hook.initializeMevModule(k, "");
        assertEq(hook.minProtocolShareBps(k.toId()), 2000);

        address ref = makeAddr("floorRef");
        uint256 p0 = protocolR.balance;
        _swap(k, true, -1 ether, 0, _attribution(ref, 1000));
        uint256 skim = (1 ether * 1000) / D; // 0.01 eth, all baseline
        uint256 floor = (skim * 2000) / Constants.BPS; // 0.002 eth
        uint256 protocolLeg = skim - (skim * 7000) / Constants.BPS; // 0.003 eth
        assertEq(protocolR.balance - p0, floor, "protocol keeps exactly its floor");
        assertEq(ref.balance, protocolLeg - floor, "referral only above the floor");

        // bounty plus floor above the baseline is refused at init
        p = _params(l, address(_newToken(false, bountyEoa, address(hook))));
        p.minProtocolShareBps = 3001;
        vm.expectRevert(IArtCoinsHookV2.BadLegBps.selector);
        hook.initializePool(p);
    }

    function test_referral_selfReferralByCaller_refused() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        uint256 p0 = protocolR.balance;
        uint256 r0 = address(swapRouter).balance;
        _swap(key, true, -1 ether, 0, _attribution(address(swapRouter), 250));
        assertEq(address(swapRouter).balance, r0, "caller cannot name itself");
        (, uint256 protocol) = _legs((1 ether * uint256(BASELINE)) / D, BASELINE);
        assertEq(protocolR.balance - p0, protocol, "protocol leg intact");
    }

    /// D16 under D41: a referrer that cannot take a stipend push is credited
    /// in escrow, not folded into protocol.
    function test_referral_rejectingReferrer_escrowed() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        HV2Rejecter ref = new HV2Rejecter();
        _swap(key, true, -1 ether, 0, _attribution(address(ref), 250));
        uint256 skim = (1 ether * uint256(BASELINE)) / D;
        assertEq(_escrowed(address(ref)), ((1 ether - skim) * uint256(MAX_REF)) / D);
    }

    function test_hookData_malformed_neverReverts() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        _swap(key, true, -0.1 ether, 0, hex"deadbeef");
        _swap(
            key, true, -0.1 ether, 0, abi.encode(uint256(type(uint256).max), uint256(7), uint256(9))
        );
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
        (int256 net0,) = _swapNet(key, true, -100 ether, TickMath.getSqrtPriceAtTick(-100), hd);
        assertEq(ext.swaps(), 1);
        // trader facing: fill plus fair skim (the refund comes back via escrow)
        assertEq(int256(ext.lastAmount0()), net0 + int256(_escrowed(address(seq))));
        assertEq(
            keccak256(ext.lastData()),
            keccak256(abi.decode(hd, (IArtCoinsHook.PoolSwapData)).poolExtensionSwapData)
        );
    }

    // ─── restriction: PoolManager transfer allowance granted on each swap ─

    /// A restricted coin: a direct PoolManager `modifyLiquidity` add from a non
    /// allowlisted router moves coin to the PoolManager with no granted
    /// allowance, so the token transfer rule reverts the whole unlock.
    function test_restricted_thirdPartyLpAdd_reverts() public onlyFork {
        Launch memory l = _defaults(bountyEoa);
        l.restricted = true;
        (PoolKey memory k, ArtCoinsTokenV2 t) = _launch(l);
        HV2AddRemoveRouter r = new HV2AddRemoveRouter(pm);
        vm.deal(address(r), 200 ether);
        t.transfer(address(r), 200e18); // launcher is allowlisted, funding passes
        vm.expectRevert();
        r.run(k, -2000, 2000, 50e18, bytes32(uint256(7)), 2);
    }

    /// A restricted coin trades through the allowlisted router both ways.
    function test_restricted_canonicalBuyAndSell_pass() public onlyFork {
        Launch memory l = _defaults(bountyEoa);
        l.restricted = true;
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(l);
        assertTrue(hook.poolInfo(key.toId()).restricted);
        assertGt(token.balanceOf(address(pm)), 0, "launch liquidity placed");
        _swap(key, true, -1 ether, 0, "");
        _swap(key, false, -1 ether, 0, "");
        _swap(key, true, 1 ether, 0, "");
        _swap(key, false, 0.5 ether, 0, "");
    }

    // ─── invariants ──────────────────────────────────────────────────────

    function test_hookHoldsNothing_afterEverySwapShape() public onlyFork {
        HV2ReturnBomb r = new HV2ReturnBomb();
        vm.deal(address(r), 1 ether);
        PoolKey memory key = _launchSimple(address(r));
        // _swap and _swapNet assert zero erc6909 claims and zero eth on the hook
        _swap(key, true, -1 ether, 0, "");
        _swap(key, true, 1 ether, 0, "");
        _swap(key, false, -1 ether, 0, "");
        _swap(key, false, 1 ether, 0, "");
        _swapNet(key, true, -50 ether, TickMath.getSqrtPriceAtTick(-60), "");
        _swapNet(key, false, 50 ether, TickMath.getSqrtPriceAtTick(60), "");
        _swap(key, true, -1, 0, ""); // dust: zero skim
    }

    function test_rescueClaims_sendsStrayClaims() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        swapRouter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
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
        assertEq(uint160(address(hook)) & 0x3fff, 0x28cc);
        assertEq(hook.constantsHash(), Constants.hash());
    }

    function test_globals_defaults() public view {
        IArtCoinsHookV2.HookGlobals memory g = hook.globals();
        assertEq(g.feeEscrow, address(escrow));
        assertEq(g.extensionAllowlist, address(allowlist));
        assertTrue(hook.isLauncher(address(this)));
        assertEq(hook.owner(), address(this));
    }

    // ─── D76: coin admin changes the bounty recipient ────────────────────

    /// the coin admin repoints the bounty recipient; the next swap's bounty leg
    /// flows to the new recipient, the old one gets nothing.
    function test_setBountyRecipient_flowsToNewOnSwap() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(_defaults(bountyEoa));
        PoolId pid = key.toId();
        address payable newBounty = payable(makeAddr("newBounty"));

        vm.expectEmit(true, true, true, true, address(hook));
        emit ArtCoinsHookV2.BountyRecipientSet(pid, bountyEoa, newBounty);
        assertEq(token.admin(), address(this), "admin is this test contract");
        hook.setBountyRecipient(pid, newBounty);
        assertEq(hook.skimConfig(pid).bountyRecipient, newBounty, "config updated");

        uint256 oldB = _paid(bountyEoa);
        uint256 nb0 = _paid(newBounty);
        _swap(key, true, -1 ether, 0, "");
        (uint256 bounty,) = _legs((1 ether * uint256(BASELINE)) / D, BASELINE);
        assertEq(_paid(bountyEoa) - oldB, 0, "old bounty gets nothing");
        assertEq(_paid(newBounty) - nb0, bounty, "new bounty paid");
    }

    function test_setBountyRecipient_nonAdminReverts() public onlyFork {
        (PoolKey memory key,) = _launch(_defaults(bountyEoa));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ArtCoinsHookV2.NotCoinAdmin.selector);
        hook.setBountyRecipient(key.toId(), payable(makeAddr("x")));
    }

    function test_setBountyRecipient_rejectedAddressesRevert() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(_defaults(bountyEoa));
        PoolId pid = key.toId();
        // parity with the factory launch checks the hook can know: coin, hook,
        // PoolManager, fee escrow.
        address[4] memory bad = [address(token), address(hook), POOL_MANAGER, address(escrow)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(ArtCoinsHookV2.RecipientCannotReceive.selector, bad[i])
            );
            hook.setBountyRecipient(pid, payable(bad[i]));
        }
        vm.expectRevert(IArtCoinsHookV2.BountyRecipientZero.selector);
        hook.setBountyRecipient(pid, payable(address(0)));
    }

    function test_setBountyRecipient_unknownPoolReverts() public {
        PoolKey memory fake;
        fake.tickSpacing = 1;
        vm.expectRevert(ArtCoinsHookV2.UnknownPool.selector);
        hook.setBountyRecipient(fake.toId(), payable(bountyEoa));
    }

    function test_setBountyRecipient_lockFreezes() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(_defaults(bountyEoa));
        token.lockRecipients();
        assertTrue(token.recipientsLocked());
        vm.expectRevert(ArtCoinsHookV2.RecipientsLocked.selector);
        hook.setBountyRecipient(key.toId(), payable(makeAddr("x")));
    }

    function test_setBountyRecipient_renounceFreezes() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(_defaults(bountyEoa));
        token.renounceAdmin();
        vm.expectRevert(ArtCoinsHookV2.NotCoinAdmin.selector);
        hook.setBountyRecipient(key.toId(), payable(makeAddr("x")));
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
        hook.rescue(address(0), s, 0);
        vm.expectRevert(err);
        hook.rescueClaims(Currency.wrap(address(0)), s, 0);
        vm.stopPrank();
    }

    function test_owner_setFeeEscrow_checksConstantsAndDepositor() public {
        HV2ConstantsStub bad = new HV2ConstantsStub(keccak256("other"));
        vm.expectRevert(
            abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, address(bad))
        );
        hook.setFeeEscrow(address(bad));
        // a matching escrow that does not list the hook as core depositor would
        // turn every failed push into a swap revert
        ArtCoinsFeeEscrowV2 e2 = new ArtCoinsFeeEscrowV2(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(ArtCoinsHookV2.EscrowNotCoreDepositor.selector, address(e2))
        );
        hook.setFeeEscrow(address(e2));
        e2.addDepositor(address(hook), false);
        vm.expectRevert(
            abi.encodeWithSelector(ArtCoinsHookV2.EscrowNotCoreDepositor.selector, address(e2))
        );
        hook.setFeeEscrow(address(e2));
        ArtCoinsFeeEscrowV2 e3 = new ArtCoinsFeeEscrowV2(address(this));
        e3.addDepositor(address(hook), true);
        vm.expectEmit(address(hook));
        emit IArtCoinsHookV2.FeeEscrowSet(address(escrow), address(e3));
        hook.setFeeEscrow(address(e3));
        assertEq(hook.globals().feeEscrow, address(e3));
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
            keccak256(ext),
            keccak256(abi.decode(hd, (IArtCoinsHook.PoolSwapData)).poolExtensionSwapData)
        );
        (ext, att) = h.decode("");
        assertEq(ext.length, 0);
        assertEq(att.referrer, address(0));
    }

    function test_calldata_refundTo() public {
        HV2CalldataHarness h = new HV2CalldataHarness();
        address me = makeAddr("me");
        assertEq(h.refundTo(_refundData(me)), me);
        assertEq(h.refundTo(_attribution(me, 1)), address(0), "empty mev data");
        assertEq(h.refundTo(""), address(0));
        bytes memory dirty = abi.encode(
            IArtCoinsHook.PoolSwapData({
                mevModuleSwapData: abi.encode(type(uint256).max), poolExtensionSwapData: ""
            })
        );
        assertEq(h.refundTo(dirty), address(0), "dirty high bits");
    }

    function testFuzz_calldata_neverReverts(bytes calldata junk) public {
        HV2CalldataHarness h = new HV2CalldataHarness();
        h.decode(junk);
        h.refundTo(junk);
        // and a valid outer frame around junk
        h.decode(
            abi.encode(
                IArtCoinsHook.PoolSwapData({mevModuleSwapData: junk, poolExtensionSwapData: junk})
            )
        );
    }
}

/// End to end with the real v2 locker, the live v4 PositionManager and
/// Permit2. A restricted coin: the allowlisted locker places and collects, and
/// a non allowlisted third party add reverts. An unrestricted coin keeps lp open.
contract HookV2RealLockerTest is HookV2ForkBase {
    address internal constant POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    int24 internal constant START = -200_000;
    address internal project = makeAddr("project");

    function _realLaunch(bool restricted)
        internal
        returns (PoolKey memory k, ArtCoinsTokenV2 t, ArtCoinsLpLockerV2 rl)
    {
        rl = new ArtCoinsLpLockerV2(address(this), POSM, PERMIT2, address(escrow));
        escrow.addDepositor(address(rl), true);
        rl.setLauncher(address(this), true);
        Launch memory l = _defaults(bountyEoa);
        l.restricted = restricted;
        t = _newToken(restricted, bountyEoa, address(hook));
        // the real locker places and collects coin; allowlist it (the factory
        // seeds the stack locker the same way at launch).
        if (restricted) t.setAllowed(address(rl), true);
        IArtCoinsHookV2.PoolInitParams memory p = _params(l, address(t));
        p.locker = address(rl);
        p.tickIfToken0IsArtCoin = START;
        k = hook.initializePool(p);

        IArtCoinsFactoryV2.LockerConfigV2 memory lc;
        lc.locker = address(rl);
        lc.rewardRecipients = new address[](1);
        lc.rewardRecipients[0] = project;
        lc.rewardBps = new uint16[](1);
        lc.rewardBps[0] = 10_000;
        lc.tickLower = new int24[](1);
        lc.tickUpper = new int24[](1);
        lc.positionBps = new uint16[](1);
        lc.tickLower[0] = START;
        lc.tickUpper[0] = -120_000;
        lc.positionBps[0] = 10_000;
        IArtCoinsFactoryV2.PoolConfigV2 memory pc;
        pc.hook = address(hook);
        pc.tickIfToken0IsArtCoin = START;
        pc.tickSpacing = TS;
        uint256 supply = 500_000_000e18;
        t.approve(address(rl), supply);
        rl.placeLiquidity(lc, pc, k, supply, address(t), type(uint256).max); // through the PositionManager
        hook.initializeMevModule(k, "");

        // trade both ways so the position earns eth and coin fees
        uint256 b0 = t.balanceOf(address(this));
        _swap(k, true, -1 ether, 0, "");
        uint256 bought = t.balanceOf(address(this)) - b0;
        _swap(k, false, -int256(bought / 2), 0, "");
    }

    /// The allowlisted real locker places and collects coin on a restricted
    /// coin (the launch path). The non allowlisted third party add is proven to
    /// revert in `HookV2ForkTest.test_restricted_thirdPartyLpAdd_reverts`, which
    /// launches with no prior swap, so no leftover same tx allowance covers it.
    function test_realLocker_restricted_placeAndCollect_pass() public onlyFork {
        (, ArtCoinsTokenV2 t, ArtCoinsLpLockerV2 rl) = _realLaunch(true);
        rl.collectRewards(address(t));
        assertGt(t.balanceOf(project) + escrow.balances(project, address(t)), 0, "coin fees out");
    }

    function test_realLocker_unrestricted_lpOpen() public onlyFork {
        (PoolKey memory k, ArtCoinsTokenV2 t, ArtCoinsLpLockerV2 rl) = _realLaunch(false);
        rl.collectRewards(address(t));
        assertGt(t.balanceOf(project) + escrow.balances(project, address(t)), 0, "coin fees out");
        // an unrestricted coin keeps lp open: a third party add passes.
        HV2AddRemoveRouter r = new HV2AddRemoveRouter(pm);
        vm.deal(address(r), 10 ether);
        t.transfer(address(r), 10e18);
        r.run(k, 200_000, 202_000, 1e18, bytes32(uint256(1)), 2);
    }
}

interface IPosmLike {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}
