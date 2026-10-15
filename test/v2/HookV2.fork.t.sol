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

    function decode(bytes calldata d) external pure returns (bytes memory ext, address referrer) {
        (bytes calldata e, address r) = HookCalldata.decode(d);
        return (e, r);
    }
}

contract HookV2ForkTest is HookV2ForkBase {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant D = Constants.BPS;

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

        (int256 net0,) = _swapNet(key, true, -int256(a), lim, _refundData(address(seq)));
        assertEq(seq.lastReturned0(), net0, "returned delta == transient delta");

        uint256 fair = (_paid(bountyEoa) - b0) + (_paid(protocolR) - p0);
        uint256 r = uint256(-net0) - charged; // realized pool input
        assertLt(r, requested / 4, "partial fill");
        assertEq(fair, (charged * r) / requested, "legs on the fill");
        assertEq(_escrowed(address(seq)), charged - fair, "unfilled skim refunded");
        assertApproxEqRel(fair * D, (r + fair) * BASELINE, 1e12);

        // a router that settles the returned delta works too
        _swap(
            key,
            true,
            -int256(a),
            TickMath.getSqrtPriceAtTick(-200),
            _refundData(address(swapRouter))
        );
        assertGt(_escrowed(address(swapRouter)), 0);
    }

    function test_skim_exactOutPriceLimited_refundsUnfilled() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        uint256 a = 100 ether; // eth out requested
        uint256 charged = (a * BASELINE) / (D - BASELINE);
        uint256 requested = a + charged;
        uint256 b0 = _paid(bountyEoa);
        uint256 p0 = _paid(protocolR);

        (int256 net0,) = _swapNet(
            key, false, int256(a), TickMath.getSqrtPriceAtTick(100), _refundData(address(seq))
        );
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
        _swap(
            key,
            false,
            int256(a),
            TickMath.getSqrtPriceAtTick(200),
            _refundData(address(swapRouter))
        );
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

    /// A partial quote specified fill without a refund address reverts.
    function test_skim_partialFill_withoutRefundAddress_reverts() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(IArtCoinsHookV2.RefundAddressRequired.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swapNet(key, true, -100 ether, TickMath.getSqrtPriceAtTick(-100), "");
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
        l.mevConfig = abi.encode(uint24(6869), uint32(600));
        (PoolKey memory key,) = _launch(l);
        uint256 t0 = block.timestamp;
        assertEq(m.windowEnd(key.toId()), t0 + 600);
        assertEq(m.schedule(key.toId()).endSkimBps, BASELINE, "decays to the pool baseline");

        assertEq(_skimOfBuy1Eth(key, bountyEoa), (1 ether * 6869) / D);
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
                IArtCoinsMevSkimV2.OutOfBounds.selector,
                Constants.MAX_MEV_WINDOW + 1,
                Constants.MIN_MEV_WINDOW,
                Constants.MAX_MEV_WINDOW
            )
        );
        hook.initializeMevModule(
            key, abi.encode(uint24(6869), uint32(Constants.MAX_MEV_WINDOW + 1))
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

        IArtCoinsHookV2.SkimConfig memory c = hook.skimConfig(pid);
        assertEq(c.baselineSkimBps, BASELINE);
        assertEq(c.bountyBps, BOUNTY_BPS);
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
        p.skim.baselineSkimBps = Constants.MAX_BASELINE_SKIM_BPS + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsHookV2.BaselineSkimOutOfBounds.selector,
                Constants.MAX_BASELINE_SKIM_BPS + 1
            )
        );
        hook.initializePool(p);

        p = _params(_defaults(bountyEoa), address(1));
        p.skim.baselineSkimBps = 0;
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.BaselineSkimOutOfBounds.selector, uint24(0))
        );
        hook.initializePool(p);

        p = _params(_defaults(bountyEoa), address(1));
        p.skim.bountyBps = Constants.MAX_BOUNTY_BPS + 1;
        vm.expectRevert(IArtCoinsHookV2.BountyBpsTooHigh.selector);
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
            abi.encodeWithSelector(IArtCoinsHookV2.RecipientCannotReceive.selector, address(hook))
        );
        hook.initializePool(p);
        p = _params(_defaults(bountyEoa), address(1));
        p.skim.protocolRecipient = payable(POOL_MANAGER);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.RecipientCannotReceive.selector, POOL_MANAGER)
        );
        hook.initializePool(p);
    }

    // ─── d1 / D16 / H13: referral leg ────────────────────────────────────

    /// V2H-05: the referral base is the realized pool side quote amount `r`
    /// for every shape. exact in buy, full fill: r = a - skim.
    function test_referral_paidAndCapped() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        hook.setReferralBps(key.toId(), REFERRAL_BPS);
        address ref = makeAddr("ref");
        uint256 p0 = protocolR.balance;
        _swap(key, true, -1 ether, 0, _referral(ref)); // asks 1%, cap 0.25%
        uint256 skim = (1 ether * uint256(BASELINE)) / D;
        uint256 referral = ((1 ether - skim) * uint256(REFERRAL_BPS)) / D;
        assertEq(ref.balance, referral, "pushed to the referrer (D41)");
        (, uint256 protocol) = _legs(skim, BASELINE);
        assertEq(protocolR.balance - p0, protocol - referral, "referral comes out of protocol");

        // exact in sell: r = pool output before skim
        _checkSellReferral(key, ref);
    }

    function _checkSellReferral(PoolKey memory key, address ref) internal {
        uint256 r0 = ref.balance;
        BalanceDelta d = _swap(key, false, -1 ether, 0, _referral(ref));
        uint256 net = uint256(int256(d.amount0())); // r - skim
        uint256 r = (net * D) / (D - uint256(BASELINE)); // +-1
        assertApproxEqAbs(ref.balance - r0, (r * uint256(REFERRAL_BPS)) / D, 1);
    }

    /// the referral is `referralBps` of volume, capped at the protocol leg of
    /// the swap: a rate above the leg takes the whole leg and no more.
    function test_referral_cappedAtProtocolLeg() public onlyFork {
        ArtCoinsTokenV2 t = _newToken(false, bountyEoa, address(hook));
        Launch memory l = _defaults(bountyEoa);
        l.baseline = 100; // 1% of volume
        l.bountyBps = 9000; // protocol leg: 0.1% of volume
        l.referralBps = Constants.MAX_REFERRAL_CAP_OF_VOLUME; // asks 1% of volume
        PoolKey memory k = hook.initializePool(_params(l, address(t)));
        _modify(k, FULL_LO, FULL_HI, int256(LIQ), 0);
        hook.initializeMevModule(k, "");

        address ref = makeAddr("capRef");
        uint256 p0 = protocolR.balance;
        _swap(k, true, -1 ether, 0, _referral(ref));
        uint256 skim = (1 ether * 100) / D; // 0.01 eth, all baseline
        uint256 protocolLeg = skim - (skim * 9000) / Constants.BPS; // 0.001 eth
        assertEq(ref.balance, protocolLeg, "referral takes the whole protocol leg");
        assertEq(protocolR.balance - p0, 0, "protocol leg exhausted by the referral");
    }

    /// A pool launches with referrals off: the referrer is ignored and the
    /// protocol leg keeps its full share.
    function test_referral_defaultOff_paysNothing() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        assertEq(hook.skimConfig(key.toId()).referralBps, 0);
        address ref = makeAddr("offRef");
        uint256 p0 = protocolR.balance;
        _swap(key, true, -1 ether, 0, _referral(ref));
        assertEq(ref.balance, 0, "no referral leg");
        (, uint256 protocol) = _legs((1 ether * uint256(BASELINE)) / D, BASELINE);
        assertEq(protocolR.balance - p0, protocol, "protocol keeps the full share");
    }

    /// The coin admin sets the rate in both directions. It applies from the
    /// next swap and is capped at the protocol leg.
    function test_setReferralBps_adminSetsAndClears() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        PoolId pid = key.toId();
        address ref = makeAddr("rateRef");
        uint256 skim = (1 ether * uint256(BASELINE)) / D;

        vm.expectEmit(true, false, false, true, address(hook));
        emit IArtCoinsHookV2.ReferralBpsSet(pid, 0, 25);
        hook.setReferralBps(pid, 25);
        assertEq(hook.skimConfig(pid).referralBps, 25);
        uint256 p0 = protocolR.balance;
        _swap(key, true, -1 ether, 0, _referral(ref));
        uint256 referral = ((1 ether - skim) * 25) / D;
        assertEq(ref.balance, referral, "25 bps of volume");
        (, uint256 protocol) = _legs(skim, BASELINE);
        assertEq(protocolR.balance - p0, protocol - referral, "carved from the protocol leg");

        vm.expectEmit(true, false, false, true, address(hook));
        emit IArtCoinsHookV2.ReferralBpsSet(pid, 25, 0);
        hook.setReferralBps(pid, 0);
        _swap(key, true, -1 ether, 0, _referral(ref));
        assertEq(ref.balance, referral, "rate 0 pays no further referral");
    }

    function test_setReferralBps_revertsForNonAdmin() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IArtCoinsHookV2.NotCoinAdmin.selector);
        hook.setReferralBps(key.toId(), 1);
        // the hook owner has no authority over a pool's rate
        vm.prank(hook.owner());
        if (hook.owner() != address(this)) {
            vm.expectRevert(IArtCoinsHookV2.NotCoinAdmin.selector);
            hook.setReferralBps(key.toId(), 1);
        }
    }

    function test_setReferralBps_revertsAboveCap() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        uint24 max = Constants.MAX_REFERRAL_CAP_OF_VOLUME;
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.ReferralBpsTooHigh.selector, max + 1, max)
        );
        hook.setReferralBps(key.toId(), max + 1);
        hook.setReferralBps(key.toId(), max);
        assertEq(hook.skimConfig(key.toId()).referralBps, max);
    }

    function test_setReferralBps_revertsAfterLock() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(_defaults(bountyEoa));
        hook.setReferralBps(key.toId(), 10);
        token.lock();
        vm.expectRevert(IArtCoinsHookV2.CoinLocked.selector);
        hook.setReferralBps(key.toId(), 20);
        assertEq(hook.skimConfig(key.toId()).referralBps, 10, "frozen at the locked value");
    }

    function test_setReferralBps_unknownPool_reverts() public onlyFork {
        vm.expectRevert(IArtCoinsHookV2.UnknownPool.selector);
        hook.setReferralBps(PoolId.wrap(bytes32(uint256(1))), 1);
    }

    /// A rate in the launch config pays from the first swap.
    function test_referral_launchConfigRate_paysFromFirstSwap() public onlyFork {
        Launch memory l = _defaults(bountyEoa);
        l.referralBps = 50;
        (PoolKey memory key,) = _launch(l);
        assertEq(hook.skimConfig(key.toId()).referralBps, 50);
        address ref = makeAddr("cfgRef");
        _swap(key, true, -1 ether, 0, _referral(ref));
        uint256 skim = (1 ether * uint256(BASELINE)) / D;
        assertEq(ref.balance, ((1 ether - skim) * 50) / D, "50 bps from the first swap");
    }

    function test_initializePool_referralAboveCap_reverts() public onlyFork {
        Launch memory l = _defaults(bountyEoa);
        uint24 max = Constants.MAX_REFERRAL_CAP_OF_VOLUME;
        l.referralBps = max + 1;
        ArtCoinsTokenV2 t = _newToken(false, bountyEoa, address(hook));
        IArtCoinsHookV2.PoolInitParams memory p = _params(l, address(t));
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.ReferralBpsTooHigh.selector, max + 1, max)
        );
        hook.initializePool(p);
    }

    function test_referral_selfReferralByCaller_refused() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        hook.setReferralBps(key.toId(), REFERRAL_BPS);
        uint256 p0 = protocolR.balance;
        uint256 r0 = address(swapRouter).balance;
        _swap(key, true, -1 ether, 0, _referral(address(swapRouter)));
        assertEq(address(swapRouter).balance, r0, "caller cannot name itself");
        (, uint256 protocol) = _legs((1 ether * uint256(BASELINE)) / D, BASELINE);
        assertEq(protocolR.balance - p0, protocol, "protocol leg intact");
    }

    /// D16 under D41: a referrer that cannot take a stipend push is credited
    /// in escrow, not folded into protocol.
    function test_referral_rejectingReferrer_escrowed() public onlyFork {
        PoolKey memory key = _launchSimple(bountyEoa);
        hook.setReferralBps(key.toId(), REFERRAL_BPS);
        HV2Rejecter ref = new HV2Rejecter();
        _swap(key, true, -1 ether, 0, _referral(address(ref)));
        uint256 skim = (1 ether * uint256(BASELINE)) / D;
        assertEq(_escrowed(address(ref)), ((1 ether - skim) * uint256(REFERRAL_BPS)) / D);
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
        bytes memory hd = _referral(makeAddr("ref"));
        hd = abi.encode(
            IArtCoinsHook.PoolSwapData({
                mevModuleSwapData: abi.encode(address(seq)),
                poolExtensionSwapData: abi.decode(hd, (IArtCoinsHook.PoolSwapData))
                .poolExtensionSwapData
            })
        );
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
        _swapNet(key, true, -50 ether, TickMath.getSqrtPriceAtTick(-60), _refundData(address(seq)));
        _swapNet(key, false, 50 ether, TickMath.getSqrtPriceAtTick(60), _refundData(address(seq)));
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
        emit IArtCoinsHookV2.BountyRecipientSet(pid, bountyEoa, newBounty);
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
        vm.expectRevert(IArtCoinsHookV2.NotCoinAdmin.selector);
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
                abi.encodeWithSelector(IArtCoinsHookV2.RecipientCannotReceive.selector, bad[i])
            );
            hook.setBountyRecipient(pid, payable(bad[i]));
        }
        vm.expectRevert(IArtCoinsHookV2.BountyRecipientZero.selector);
        hook.setBountyRecipient(pid, payable(address(0)));
    }

    function test_setBountyRecipient_extensionsRevert() public onlyFork {
        HV2Extension poolExt = new HV2Extension(address(hook));
        allowlist.setPoolExtension(address(poolExt), true);
        Launch memory l = _defaults(bountyEoa);
        l.extension = address(poolExt);
        (PoolKey memory key,) = _launch(l);
        PoolId pid = key.toId();

        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsHookV2.RecipientCannotReceive.selector, address(poolExt)
            )
        );
        hook.setBountyRecipient(pid, payable(address(poolExt)));

        address enabled = makeAddr("enabledLaunchExtension");
        this.setLaunchExtension(enabled, true);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.RecipientCannotReceive.selector, enabled)
        );
        hook.setBountyRecipient(pid, payable(enabled));

        this.setLaunchExtension(enabled, false);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.RecipientCannotReceive.selector, enabled)
        );
        hook.setBountyRecipient(pid, payable(enabled));
    }

    function test_initializePool_escrowMustListHookAsCoreDepositor() public {
        vm.mockCall(
            address(escrow),
            abi.encodeCall(escrow.isCoreDepositor, (address(hook))),
            abi.encode(false)
        );
        IArtCoinsHookV2.PoolInitParams memory p = _params(_defaults(bountyEoa), address(1));
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.EscrowNotCoreDepositor.selector, address(escrow))
        );
        hook.initializePool(p);
    }

    function test_initializeMevModule_noModule_emitsPoolStarted() public onlyFork {
        ArtCoinsTokenV2 token = _newToken(false, bountyEoa, address(hook));
        PoolKey memory key = hook.initializePool(_params(_defaults(bountyEoa), address(token)));
        _modify(key, FULL_LO, FULL_HI, int256(LIQ), 0);
        vm.expectEmit(true, false, false, false, address(hook));
        emit IArtCoinsHookV2.PoolStarted(key.toId());
        hook.initializeMevModule(key, "");
    }

    function test_setBountyRecipient_unknownPoolReverts() public {
        PoolKey memory fake;
        fake.tickSpacing = 1;
        vm.expectRevert(IArtCoinsHookV2.UnknownPool.selector);
        hook.setBountyRecipient(fake.toId(), payable(bountyEoa));
    }

    // ─── coin admin: lower the baseline skim ──────────────────────────────

    /// the coin admin lowers the skim; the next swap pays the lower rate and
    /// every leg scales with it. Raising, equal, zero on a skim only pool,
    /// strangers, unknown pools and a locked coin are refused.
    function test_lowerBaselineSkim_lowerOnly() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(_defaults(bountyEoa));
        PoolId pid = key.toId();
        uint24 half = BASELINE / 2;

        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.SkimNotLower.selector, BASELINE, BASELINE)
        );
        hook.lowerBaselineSkim(pid, BASELINE);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.SkimNotLower.selector, BASELINE, BASELINE + 1)
        );
        hook.lowerBaselineSkim(pid, BASELINE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.SkimNotLower.selector, BASELINE, uint24(0))
        );
        hook.lowerBaselineSkim(pid, 0);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IArtCoinsHookV2.NotCoinAdmin.selector);
        hook.lowerBaselineSkim(pid, half);
        PoolKey memory fake = PoolKey(key.currency0, key.currency1, key.fee, int24(1), key.hooks);
        vm.expectRevert(IArtCoinsHookV2.UnknownPool.selector);
        hook.lowerBaselineSkim(fake.toId(), half);

        vm.expectEmit(true, false, false, true, address(hook));
        emit IArtCoinsHookV2.BaselineSkimLowered(pid, BASELINE, half);
        hook.lowerBaselineSkim(pid, half);
        assertEq(hook.skimConfig(pid).baselineSkimBps, half);

        uint256 b0 = _paid(bountyEoa);
        uint256 p0 = protocolR.balance;
        _swap(key, true, -1 ether, 0, "");
        uint256 skim = (1 ether * uint256(half)) / D; // no window: skim == baseline
        uint256 bounty = (skim * BOUNTY_BPS) / Constants.BPS;
        assertEq(_paid(bountyEoa) - b0, bounty, "bounty at the lower skim");
        assertEq(protocolR.balance - p0, skim - bounty, "protocol at the lower skim");

        // never back up
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.SkimNotLower.selector, half, BASELINE)
        );
        hook.lowerBaselineSkim(pid, BASELINE);
        // the lock freezes it
        token.lock();
        vm.expectRevert(IArtCoinsHookV2.CoinLocked.selector);
        hook.lowerBaselineSkim(pid, 1);
    }

    /// the skim never reaches zero: every pool keeps a nonzero baseline.
    function test_lowerBaselineSkim_zeroRefused() public onlyFork {
        (PoolKey memory k,) = _launch(_defaults(bountyEoa));
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.SkimNotLower.selector, BASELINE, uint24(0))
        );
        hook.lowerBaselineSkim(k.toId(), 0);
        hook.lowerBaselineSkim(k.toId(), 1);
        assertEq(hook.skimConfig(k.toId()).baselineSkimBps, 1);
    }

    function test_setBountyRecipient_lockFreezes() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(_defaults(bountyEoa));
        token.lock();
        assertTrue(token.locked());
        vm.expectRevert(IArtCoinsHookV2.CoinLocked.selector);
        hook.setBountyRecipient(key.toId(), payable(makeAddr("x")));
    }

    function test_setBountyRecipient_renounceFreezes() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(_defaults(bountyEoa));
        token.renounceAdmin();
        vm.expectRevert(IArtCoinsHookV2.NotCoinAdmin.selector);
        hook.setBountyRecipient(key.toId(), payable(makeAddr("x")));
    }

    // ─── coin admin: pool extension ───────────────────────────────────────

    /// the coin admin swaps the pool's extension; the new one is set up in the
    /// call and sees the next swap, the old one sees nothing more.
    function test_setPoolExtension_replacesAndSetsUp() public onlyFork {
        HV2Extension first = new HV2Extension(address(hook));
        HV2Extension second = new HV2Extension(address(hook));
        allowlist.setPoolExtension(address(first), true);
        allowlist.setPoolExtension(address(second), true);
        Launch memory l = _defaults(bountyEoa);
        l.extension = address(first);
        (PoolKey memory key,) = _launch(l);
        PoolId pid = key.toId();
        _swap(key, true, -0.1 ether, 0, "");
        assertEq(first.swaps(), 1, "first extension saw the launch swap");

        vm.expectEmit(true, true, true, true, address(hook));
        emit IArtCoinsHookV2.PoolExtensionSet(pid, address(first), address(second));
        hook.setPoolExtension(key, address(second), hex"c0ffee");
        assertEq(hook.poolInfo(pid).extension, address(second), "info updated");
        assertEq(second.preSetups(), 1, "pre locker setup ran");
        assertEq(second.postSetups(), 1, "post locker setup ran");

        _swap(key, true, -0.1 ether, 0, "");
        assertEq(second.swaps(), 1, "second extension sees the next swap");
        assertEq(first.swaps(), 1, "first extension sees nothing more");

        // zero clears it; no setup call to make
        hook.setPoolExtension(key, address(0), "");
        assertEq(hook.poolInfo(pid).extension, address(0));
        _swap(key, true, -0.1 ether, 0, "");
        assertEq(second.swaps(), 1, "cleared extension is not called");
    }

    function test_setPoolExtension_rejectsBountyRecipient() public onlyFork {
        (PoolKey memory key,) = _launch(_defaults(bountyEoa));
        HV2Extension ext = new HV2Extension(address(hook));
        allowlist.setPoolExtension(address(ext), true);
        hook.setBountyRecipient(key.toId(), payable(address(ext)));
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.RecipientCannotReceive.selector, address(ext))
        );
        hook.setPoolExtension(key, address(ext), "");
    }

    function test_setPoolExtension_guards() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launch(_defaults(bountyEoa));
        HV2Extension ext = new HV2Extension(address(hook));

        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.ExtensionNotAllowed.selector, address(ext))
        );
        hook.setPoolExtension(key, address(ext), "");
        allowlist.setPoolExtension(address(ext), true);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IArtCoinsHookV2.NotCoinAdmin.selector);
        hook.setPoolExtension(key, address(ext), "");

        // a fresh struct: a memory to memory assignment would alias `key`
        PoolKey memory fake = PoolKey(key.currency0, key.currency1, key.fee, int24(1), key.hooks);
        vm.expectRevert(IArtCoinsHookV2.UnknownPool.selector);
        hook.setPoolExtension(fake, address(ext), "");

        hook.setPoolExtension(key, address(ext), "");
        assertEq(hook.poolInfo(key.toId()).extension, address(ext));

        // closed until the launch completes (initializeMevModule)
        ArtCoinsTokenV2 t2 = _newToken(false, bountyEoa, address(hook));
        PoolKey memory k2 = hook.initializePool(_params(_defaults(bountyEoa), address(t2)));
        vm.expectRevert(IArtCoinsHookV2.PoolNotStarted.selector);
        hook.setPoolExtension(k2, address(ext), "");

        token.lock();
        vm.expectRevert(IArtCoinsHookV2.CoinLocked.selector);
        hook.setPoolExtension(key, address(0), "");
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
            abi.encodeWithSelector(IArtCoinsHookV2.EscrowNotCoreDepositor.selector, address(e2))
        );
        hook.setFeeEscrow(address(e2));
        e2.addDepositor(address(hook), false);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.EscrowNotCoreDepositor.selector, address(e2))
        );
        hook.setFeeEscrow(address(e2));
        ArtCoinsFeeEscrowV2 e3 = new ArtCoinsFeeEscrowV2(address(this));
        e3.addDepositor(address(hook), true);
        vm.expectEmit(address(hook));
        emit IArtCoinsHookV2.FeeEscrowSet(address(escrow), address(e3));
        hook.setFeeEscrow(address(e3));
        assertEq(hook.globals().feeEscrow, address(e3));
        assertTrue(hook.everFeeEscrow(address(escrow)), "constructor escrow recorded");
        assertTrue(hook.everFeeEscrow(address(e3)), "current escrow recorded");
        assertFalse(hook.everFeeEscrow(address(e2)), "rejected escrow not recorded");
        vm.expectRevert(IArtCoinsHookV2.ZeroAddress.selector);
        hook.setLauncher(address(0), true);
    }

    /// @dev A former fee escrow stays rejected as a bounty recipient after rotation.
    function test_setBountyRecipient_rejectsFormerEscrow() public onlyFork {
        (PoolKey memory key,) = _launch(_defaults(bountyEoa));
        ArtCoinsFeeEscrowV2 e2 = new ArtCoinsFeeEscrowV2(address(this));
        e2.addDepositor(address(hook), true);
        hook.setFeeEscrow(address(e2));
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsHookV2.RecipientCannotReceive.selector, address(escrow))
        );
        hook.setBountyRecipient(key.toId(), payable(address(escrow)));
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

    function test_calldata_decodesReferrer() public {
        HV2CalldataHarness h = new HV2CalldataHarness();
        address ref = makeAddr("ref");
        bytes memory hd = _referral(ref);
        (bytes memory ext, address referrer) = h.decode(hd);
        assertEq(referrer, ref);
        assertEq(
            keccak256(ext),
            keccak256(abi.decode(hd, (IArtCoinsHook.PoolSwapData)).poolExtensionSwapData)
        );
        // a dirty referrer word yields no referrer, the extension slice is kept
        bytes memory dirtyInner = abi.encode(uint256(uint160(ref)) | (uint256(1) << 200), bytes(""));
        (ext, referrer) = h.decode(
            abi.encode(
                IArtCoinsHook.PoolSwapData({
                    mevModuleSwapData: "", poolExtensionSwapData: dirtyInner
                })
            )
        );
        assertEq(referrer, address(0), "dirty high bits: no referrer");
        assertEq(keccak256(ext), keccak256(dirtyInner));
        // an older (struct, bytes) layout starts with an offset word: no referrer
        bytes memory oldShape =
            abi.encode(abi.encode(bytes32("src"), ref, bytes16("cmp"), uint24(25)), bytes(""));
        (ext, referrer) = h.decode(
            abi.encode(
                IArtCoinsHook.PoolSwapData({mevModuleSwapData: "", poolExtensionSwapData: oldShape})
            )
        );
        assertEq(referrer, address(0), "offset word is not a referrer");
        assertEq(keccak256(ext), keccak256(oldShape), "extension slice kept");
        (ext, referrer) = h.decode("");
        assertEq(ext.length, 0);
        assertEq(referrer, address(0));
    }

    function test_calldata_refundTo() public {
        HV2CalldataHarness h = new HV2CalldataHarness();
        address me = makeAddr("me");
        assertEq(h.refundTo(_refundData(me)), me);
        assertEq(h.refundTo(_referral(me)), address(0), "empty mev data");
        assertEq(h.refundTo(""), address(0));
        bytes memory dirty = abi.encode(
            IArtCoinsHook.PoolSwapData({
                mevModuleSwapData: abi.encode(type(uint256).max), poolExtensionSwapData: ""
            })
        );
        assertEq(h.refundTo(dirty), address(0), "dirty high bits");
        assertEq(h.refundTo(abi.encode(me)), address(0), "raw 32 byte word");
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
/// Permit2. A restricted coin: the allowlisted locker places, and
/// a non allowlisted third party add reverts. An unrestricted coin keeps lp open.
contract HookV2RealLockerTest is HookV2ForkBase {
    address internal constant POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    int24 internal constant START = -200_000;

    function _realLaunch(bool restricted)
        internal
        returns (PoolKey memory k, ArtCoinsTokenV2 t, ArtCoinsLpLockerV2 rl)
    {
        rl = new ArtCoinsLpLockerV2(address(this), POSM, PERMIT2);
        rl.setLauncher(address(this), true);
        Launch memory l = _defaults(bountyEoa);
        l.restricted = restricted;
        t = _newToken(restricted, bountyEoa, address(hook));
        // the real locker places and collects coin; allowlist it (the factory
        // seeds the stack locker the same way at launch).
        if (restricted) t.setAllowed(address(rl), true);
        IArtCoinsHookV2.PoolInitParams memory p = _params(l, address(t));
        p.locker = address(rl);
        p.tickIfToken0IsCoin = START;
        k = hook.initializePool(p);

        IArtCoinsFactoryV2.LockerConfigV2 memory lc;
        lc.locker = address(rl);
        lc.tickLower = new int24[](1);
        lc.tickUpper = new int24[](1);
        lc.positionBps = new uint16[](1);
        lc.tickLower[0] = START;
        lc.tickUpper[0] = -120_000;
        lc.positionBps[0] = 10_000;
        IArtCoinsFactoryV2.PoolConfigV2 memory pc;
        pc.hook = address(hook);
        pc.tickIfToken0IsCoin = START;
        pc.tickSpacing = TS;
        uint256 supply = 500_000_000e18;
        t.approve(address(rl), supply);
        rl.placeLiquidity(lc, pc, k, supply, address(t)); // through the PositionManager
        hook.initializeMevModule(k, "");

        // trade both ways through the placed position
        uint256 b0 = t.balanceOf(address(this));
        _swap(k, true, -1 ether, 0, "");
        uint256 bought = t.balanceOf(address(this)) - b0;
        _swap(k, false, -int256(bought / 2), 0, "");
    }

    /// The allowlisted real locker places coin on a restricted
    /// coin (the launch path). The non allowlisted third party add is proven to
    /// revert in `HookV2ForkTest.test_restricted_thirdPartyLpAdd_reverts`, which
    /// launches with no prior swap, so no leftover same tx allowance covers it.
    function test_realLocker_restricted_place_pass() public onlyFork {
        (, ArtCoinsTokenV2 t, ArtCoinsLpLockerV2 rl) = _realLaunch(true);
        assertEq(rl.lockedLiquidity(address(t)).numPositions, 1);
        assertEq(t.balanceOf(address(rl)), 0, "locker holds no coin");
    }

    function test_realLocker_unrestricted_lpOpen() public onlyFork {
        (PoolKey memory k, ArtCoinsTokenV2 t, ArtCoinsLpLockerV2 rl) = _realLaunch(false);
        assertEq(rl.lockedLiquidity(address(t)).numPositions, 1);
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
