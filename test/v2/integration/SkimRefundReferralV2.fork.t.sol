// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// package i1, parts 5 to 7 on factory launched coins:
//   5 anti sniper: the skim decays linearly from the starting value to the
//     baseline over the window; a module that keeps reporting an open window
//     is treated as expired at createdAt + MAX_MEV_WINDOW (skim and add lock).
//   6 price limited partial fills, both quote specified shapes (exact in buy,
//     exact out sell), through the live universal router and through a
//     currencyDelta settling router: the swapper pays (or receives) exactly
//     realized plus (minus) the fair skim, nothing is left in the escrow, the
//     hook holds nothing (D42, D51).
//   7 referral: a referred swap pays the referrer (escrow on failure, D16,
//     D57) without taking the protocol leg below its floor (D52).

import {IntegrationV2Base} from "./IntegrationV2Base.sol";
import {I1EmptyTreasury, I1LyingMevModule, I1RevertingTreasury} from "./mocks/I1Mocks.sol";

import {Constants} from "../../../src/Constants.sol";
import {ArtCoinsFactoryV2} from "../../../src/v2/ArtCoinsFactoryV2.sol";
import {ArtCoinsHookV2} from "../../../src/v2/hooks/ArtCoinsHookV2.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// v4 periphery single hop params as the live universal router decodes them.
struct I1ExactInSingle {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

struct I1ExactOutSingle {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountOut;
    uint128 amountInMaximum;
    bytes hookData;
}

interface II1UniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

contract SkimRefundReferralV2ForkTest is IntegrationV2Base {
    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWEEP = 0x04;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    // ══════════════════════════════════════════════════════════════════════
    // 5. anti sniper
    // ══════════════════════════════════════════════════════════════════════

    /// skim charged on a full fill exact in buy of `a` (exact: s = a * bps / D).
    function _skimOfBuy(PoolKey memory key, uint256 a) internal returns (uint256 s) {
        vm.recordLogs();
        _buy(key, a);
        Legs memory l = _legs(vm.getRecordedLogs());
        assertEq(l.refunded, 0);
        s = l.bounty + l.protocol + l.referral;
    }

    function _ethOnlyAdd(PoolKey memory key, bytes32 salt) internal returns (bool ok, bytes memory err) {
        (, int24 tc,,) = readSlot0(key);
        int24 lo = (tc / 200) * 200 + 400;
        try liqRouter.modifyLiquidity{value: 1 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: lo + 2000, liquidityDelta: 1e15, salt: salt}),
            ""
        ) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    function test_i1_antiSniper_skimDecaysLinearlyToBaseline() public onlyFork {
        address coin = _ownerLaunch(_noneConfig(address(new I1EmptyTreasury())));
        PoolKey memory key = _key(coin);
        PoolId pid = _pid(coin);
        uint256 t0 = vm.getBlockTimestamp();
        assertEq(v2.mev.windowEnd(pid), t0 + WINDOW, "window frozen at launch");
        assertEq(v2.mev.schedule(pid).endSkimBps, BASELINE, "decays to the pool baseline");

        uint256 a = 0.01 ether;
        uint32[7] memory dts = [uint32(0), WINDOW / 4, WINDOW / 2, (3 * WINDOW) / 4, WINDOW - 1, WINDOW, WINDOW + 3600];
        for (uint256 i; i < dts.length; ++i) {
            vm.warp(t0 + dts[i]);
            uint256 bps = dts[i] < WINDOW
                ? uint256(START_SKIM) - ((uint256(START_SKIM) - BASELINE) * dts[i]) / WINDOW
                : BASELINE;
            (uint24 modBps, bool active) = v2.mev.currentSkimBps(pid);
            assertEq(modBps, bps, "module schedule");
            assertEq(active, dts[i] < WINDOW, "module active flag");
            assertEq(_skimOfBuy(key, a), (a * bps) / D, "hook charges the decayed skim");
        }
        assertEq(_skimOfBuy(key, a), (a * BASELINE) / D, "baseline after the window");

        // add lock (NONE pool): closed inside the window, open after
        vm.warp(t0 + WINDOW - 1);
        (bool ok, bytes memory err) = _ethOnlyAdd(key, bytes32(uint256(1)));
        assertFalse(ok, "add locked in the window");
        assertTrue(_contains(err, IArtCoinsHookV2.MevWindowActive.selector), "MevWindowActive");
        vm.warp(t0 + WINDOW);
        (ok,) = _ethOnlyAdd(key, bytes32(uint256(1)));
        assertTrue(ok, "add open after the window");
    }

    function test_i1_antiSniper_moduleTreatedAsExpiredAfterMaxWindow() public onlyFork {
        I1LyingMevModule lying = new I1LyingMevModule(address(v2.hook), 50_000);
        vm.prank(LIVE_OWNER);
        v2.factory.setMevModule(address(lying), true);
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _noneConfig(address(new I1EmptyTreasury()));
        c.mev.module = address(lying);
        address coin = _ownerLaunch(c);
        PoolKey memory key = _key(coin);
        uint256 t0 = vm.getBlockTimestamp();
        uint256 a = 0.01 ether;

        assertEq(_skimOfBuy(key, a), (a * 50_000) / D, "module value used inside the cap");
        vm.warp(t0 + WINDOW + 1); // past the configured window, the module still claims active
        (, bool active) = lying.currentSkimBps(_pid(coin));
        assertTrue(active);
        assertEq(_skimOfBuy(key, a), (a * 50_000) / D, "still trusted before MAX_MEV_WINDOW");
        vm.warp(t0 + Constants.MAX_MEV_WINDOW - 1);
        (bool ok,) = _ethOnlyAdd(key, bytes32(uint256(2)));
        assertFalse(ok, "add lock holds until the cap");

        vm.warp(t0 + Constants.MAX_MEV_WINDOW);
        (, active) = lying.currentSkimBps(_pid(coin));
        assertTrue(active, "module still lies");
        assertEq(_skimOfBuy(key, a), (a * BASELINE) / D, "expired at createdAt + MAX_MEV_WINDOW: baseline");
        (ok,) = _ethOnlyAdd(key, bytes32(uint256(2)));
        assertTrue(ok, "add lock ends at the cap");
    }

    // ══════════════════════════════════════════════════════════════════════
    // 6. price limited partial fills
    // ══════════════════════════════════════════════════════════════════════

    /// NONE coin whose whole pool supply sits in one narrow range (about 2.2
    /// eth buys it out), past the anti sniper window.
    function _narrowLaunch() internal returns (address coin, PoolKey memory key) {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _noneConfig(address(new I1EmptyTreasury()));
        _narrow(c);
        coin = _ownerLaunch(c);
        key = _key(coin);
        _pastWindow();
    }

    /// the D51 contract for a partial quote specified fill: the swapper's eth
    /// moves by exactly the realized pool amount plus (buy) or minus (sell)
    /// the fair skim; no refund is left in the escrow; the hook holds nothing.
    function _assertFairPartial(
        Legs memory l,
        uint256 ethMoved,
        bool buy,
        uint256 requested,
        address swapper,
        address router,
        PoolKey memory key
    ) internal view {
        uint256 fair = l.bounty + l.protocol + l.referral;
        assertEq(l.splits, 1);
        assertGt(l.volume, 0, "filled");
        assertLt(l.volume, requested, "partial fill");
        // exact in buy: fair = r * b / (D - b); exact out sell: fair = r * b / D
        assertApproxEqRel(fair * (buy ? D - BASELINE : D), l.volume * BASELINE, 1e15, "fair skim on the realized fill");
        // h1 refunds the over charge through the escrow (SkimRefunded), not inside the swap: D42/D51 not implemented
        assertEq(ethMoved, buy ? l.volume + fair : l.volume - fair, "swapper moved realized +/- fair skim (D51)");
        assertEq(l.refunded, 0, "no escrow refund (D51)");
        assertEq(_escrowed(swapper), 0, "no escrow residue for the swapper");
        assertEq(_escrowed(router), 0, "no escrow residue for the router");
        _assertHookHoldsNothing(key);
    }

    // BUG: h1 D42/D51 over charge on a partial fill is escrowed, not refunded in the swap (fails by charged - fair)
    function test_i1_partialFill_exactInBuy_deltaRouter() public onlyFork {
        (, PoolKey memory key) = _narrowLaunch();
        vm.deal(address(deltaRouter), 100 ether);
        uint256 a = 10 ether;
        uint160 limit = TickMath.getSqrtPriceAtTick(199_400); // inside the narrow range
        uint256 e0 = address(deltaRouter).balance;
        vm.recordLogs();
        deltaRouter.swap(key, true, -int256(a), limit, "");
        Legs memory l = _legs(vm.getRecordedLogs());
        assertEq(deltaRouter.lastReturned0(), deltaRouter.lastNet0(), "returned delta == transient delta");
        (uint160 sqrtAfter,,,) = readSlot0(key);
        assertEq(sqrtAfter, limit, "stopped at the price limit");
        _assertFairPartial(l, e0 - address(deltaRouter).balance, true, a, address(deltaRouter), address(deltaRouter), key);
    }

    // BUG: h1 D42/D51 over charge on a partial fill is escrowed, not refunded in the swap (fails by charged - fair)
    function test_i1_partialFill_exactOutSell_deltaRouter() public onlyFork {
        (address coin, PoolKey memory key) = _narrowLaunch();
        uint256 got = _buy(key, 1 ether); // full fill: the pool now holds about 1 eth
        IERC20(coin).transfer(address(deltaRouter), got);
        uint256 a = 5 ether; // more eth than the pool holds
        (, int24 tick,,) = readSlot0(key);
        uint160 limit = TickMath.getSqrtPriceAtTick(tick + 200); // well short of the fill
        uint256 e0 = address(deltaRouter).balance;
        vm.recordLogs();
        deltaRouter.swap(key, false, int256(a), limit, "");
        Legs memory l = _legs(vm.getRecordedLogs());
        assertEq(deltaRouter.lastReturned0(), deltaRouter.lastNet0(), "returned delta == transient delta");
        // l.volume is the gross pool output; requested gross = a + charged
        _assertFairPartial(l, address(deltaRouter).balance - e0, false, a, address(deltaRouter), address(deltaRouter), key);
    }

    function _ur() internal pure returns (II1UniversalRouter) {
        return II1UniversalRouter(UNIVERSAL_ROUTER);
    }

    /// exact in buy of `a` eth through the live universal router (V4Router
    /// settles the full debt, sweeps the rest back). returns the eth spent.
    function _urBuy(PoolKey memory key, uint256 a, bytes memory hd) internal returns (uint256 spent, Legs memory l) {
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(I1ExactInSingle(key, true, uint128(a), 0, hd));
        params[1] = abi.encode(key.currency0, a);
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(address(0), address(this), uint256(0)); // sweep leftover eth
        vm.deal(address(this), address(this).balance + a);
        uint256 e0 = address(this).balance;
        vm.recordLogs();
        _ur().execute{value: a}(abi.encodePacked(V4_SWAP, SWEEP), inputs, vm.getBlockTimestamp());
        l = _legs(vm.getRecordedLogs());
        spent = e0 - address(this).balance;
        assertEq(UNIVERSAL_ROUTER.balance, 0, "router holds no eth");
    }

    /// exact out sell for `a` eth through the live universal router, paying
    /// coin via permit2 up to the caller's whole balance. returns eth received.
    function _urSellExactOut(PoolKey memory key, uint256 a, bytes memory hd)
        internal
        returns (uint256 received, Legs memory l)
    {
        address coin = Currency.unwrap(key.currency1);
        // draining the pool's eth needs more coin than the buys returned (lp fee)
        uint256 bal = 3 * IERC20(coin).balanceOf(address(this)) + 1e24;
        deal(coin, address(this), bal);
        IPermit2(PERMIT2).approve(coin, UNIVERSAL_ROUTER, type(uint160).max, uint48(vm.getBlockTimestamp() + 1 days));
        bytes memory actions = abi.encodePacked(SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(I1ExactOutSingle(key, false, uint128(a), type(uint128).max, hd));
        params[1] = abi.encode(key.currency1, bal);
        params[2] = abi.encode(key.currency0, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 e0 = address(this).balance;
        vm.recordLogs();
        _ur().execute(abi.encodePacked(V4_SWAP), inputs, vm.getBlockTimestamp());
        l = _legs(vm.getRecordedLogs());
        received = address(this).balance - e0;
        assertLt(IERC20(coin).balanceOf(address(this)), bal, "sold");
    }

    // BUG: h1 D42/D51 over charge on a partial fill is escrowed, not refunded in the swap (fails by charged - fair)
    function test_i1_partialFill_exactInBuy_universalRouter() public onlyFork {
        (address coin, PoolKey memory key) = _narrowLaunch();
        uint256 a = 10 ether; // the narrow range sells out near 2.2 eth
        (uint256 spent, Legs memory l) = _urBuy(key, a, "");
        assertGt(IERC20(coin).balanceOf(address(this)), 0, "bought");
        _assertFairPartial(l, spent, true, a, address(this), UNIVERSAL_ROUTER, key);
    }

    // BUG: h1 D42/D51 over charge on a partial fill is escrowed, not refunded in the swap (fails by charged - fair)
    function test_i1_partialFill_exactOutSell_universalRouter() public onlyFork {
        (, PoolKey memory key) = _narrowLaunch();
        _buy(key, 1 ether);
        uint256 a = 5 ether; // more eth than the pool holds
        (uint256 received, Legs memory l) = _urSellExactOut(key, a, "");
        _assertFairPartial(l, received, false, a, address(this), UNIVERSAL_ROUTER, key);
    }

    /// claims `who`'s escrowed refund (anyone may) and returns it.
    function _claimRefund(address who) internal returns (uint256 refund) {
        refund = _escrowed(who);
        if (refund != 0) {
            vm.prank(stranger);
            v2.escrow.claim(who, address(0));
        }
    }

    /// what holds today (escrow refund, b3, V2H-03) and after D51 alike: net
    /// of the refund it can claim, the swapper paid (received) exactly the
    /// realized pool amount plus (minus) the fair skim; with a refund address
    /// in hookData nothing is stranded under the universal router; a
    /// currencyDelta router is made whole by a permissionless claim.
    function test_i1_partialFill_netOfClaimableRefund_isFair_bothShapesBothRouters() public onlyFork {
        (address coin, PoolKey memory key) = _narrowLaunch();
        vm.deal(address(deltaRouter), 100 ether);
        uint256 fair;

        // 1. delta router, exact in buy, price limited
        uint256 e0 = address(deltaRouter).balance;
        vm.recordLogs();
        deltaRouter.swap(key, true, -10 ether, TickMath.getSqrtPriceAtTick(199_400), "");
        Legs memory l = _legs(vm.getRecordedLogs());
        uint256 refund = _claimRefund(address(deltaRouter));
        assertEq(refund, l.refunded, "refund credited to the PoolManager caller");
        fair = l.bounty + l.protocol + l.referral;
        assertEq(e0 - address(deltaRouter).balance, l.volume + fair, "delta router buy: net = realized + fair");
        _assertHookHoldsNothing(key);

        // 2. delta router, exact out sell, price limited
        (, int24 tick,,) = readSlot0(key);
        e0 = address(deltaRouter).balance;
        vm.recordLogs();
        deltaRouter.swap(key, false, 1 ether, TickMath.getSqrtPriceAtTick(tick + 200), "");
        l = _legs(vm.getRecordedLogs());
        refund = _claimRefund(address(deltaRouter));
        assertEq(refund, l.refunded);
        fair = l.bounty + l.protocol + l.referral;
        assertEq(address(deltaRouter).balance - e0, l.volume - fair, "delta router sell: net = realized - fair");
        _assertHookHoldsNothing(key);

        // 3. universal router, exact in buy past the range, refund address = the user
        uint256 spent;
        (spent, l) = _urBuy(key, 10 ether, _refundData(address(this)));
        refund = _claimRefund(address(this));
        assertEq(refund, l.refunded, "refund credited to the named address");
        assertEq(_escrowed(UNIVERSAL_ROUTER), 0, "nothing stranded under the router");
        fair = l.bounty + l.protocol + l.referral;
        assertEq(spent - refund, l.volume + fair, "ur buy: net = realized + fair");
        assertGt(IERC20(coin).balanceOf(address(this)), 0);
        _assertHookHoldsNothing(key);

        // 4. universal router, exact out sell past the range
        uint256 received;
        (received, l) = _urSellExactOut(key, 5 ether, _refundData(address(this)));
        refund = _claimRefund(address(this));
        assertEq(refund, l.refunded);
        assertEq(_escrowed(UNIVERSAL_ROUTER), 0, "nothing stranded under the router");
        fair = l.bounty + l.protocol + l.referral;
        assertEq(received + refund, l.volume - fair, "ur sell: net = realized - fair");
        assertEq(_owed(), 0, "escrow empty");
        _assertHookHoldsNothing(key);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 7. referral
    // ══════════════════════════════════════════════════════════════════════

    /// the factory's own bound: maxRef * BPS <= baseline * (BPS - bounty - minShare).
    function _refCapAtBound() internal view returns (uint24) {
        uint256 minShare = v2.factory.minProtocolSkimShareBps();
        return uint24((uint256(BASELINE) * (10_000 - BOUNTY_BPS - minShare)) / 10_000);
    }

    function _checkReferred(Legs memory l, address referrer, uint256 paidBefore) internal view {
        uint256 minShare = v2.factory.minProtocolSkimShareBps();
        uint256 base = l.bounty + l.protocol + l.referral; // past the window: skim == baseline skim
        uint256 floor = (base * minShare) / 10_000;
        uint256 protocolBefore = base - (base * BOUNTY_BPS) / 10_000;
        uint256 capped = (l.volume * _refCapAtBound()) / D;
        uint256 room = protocolBefore - floor;
        assertGt(l.referral, 0, "referrer paid");
        assertEq(l.referral, capped < room ? capped : room, "referral = min(cap, protocol - floor)");
        assertGe(l.protocol, floor, "protocol leg never below the floor (D52)");
        assertEq(l.protocol + l.referral, protocolBefore, "referral carved from the protocol leg only");
        assertEq(referrer.balance + _escrowed(referrer) - paidBefore, l.referral, "referral delivered");
    }

    function test_i1_referral_paysReferrer_protocolNeverBelowFloor() public onlyFork {
        // a launch above the floor bound is refused
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _creditsConfig(address(new I1EmptyTreasury()));
        uint24 cap = _refCapAtBound();
        assertEq(v2.factory.minProtocolSkimShareBps(), 1000, "deploy script floor (D52)");
        c.fee.maxReferralBpsOfVolume = cap + 1;
        vm.deal(LIVE_OWNER, LIVE_OWNER.balance + 1 ether);
        vm.prank(LIVE_OWNER);
        vm.expectRevert(ArtCoinsFactoryV2.ReferralCapAboveProtocolFloor.selector);
        v2.factory.deployTokenAsOwner{value: 0.069 ether}(c, PROTOCOL_BPS);

        // at the bound, a referral asking for more (1%) is capped and the floor holds
        c.fee.maxReferralBpsOfVolume = cap;
        address coin = _ownerLaunch(c);
        PoolKey memory key = _key(coin);
        _pastWindow();
        address referrer = makeAddr("i1.referrer");
        bytes memory hd = _attribution(referrer, 1000);

        uint256 p0 = referrer.balance + _escrowed(referrer);
        vm.recordLogs();
        (, uint256 got) = swapExactIn(key, true, 1 ether, address(this), hd);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Legs memory l = _legs(logs);
        _checkReferred(l, referrer, p0);
        (uint256 pushed, uint256 escrowed) = _delivered(logs, referrer);
        assertEq(pushed, l.referral, "eoa referrer: stipend push lands");
        assertEq(escrowed, 0);

        p0 = referrer.balance + _escrowed(referrer);
        vm.recordLogs();
        swapExactIn(key, false, got / 2, address(this), hd);
        _checkReferred(_legs(vm.getRecordedLogs()), referrer, p0);

        // a referrer that cannot take a stipend push is credited in the escrow
        // (D16; the factory's referral payout is the escrow, D57) and pulls it
        I1RevertingTreasury rref = new I1RevertingTreasury();
        vm.recordLogs();
        swapExactIn(key, true, 1 ether, address(this), _attribution(address(rref), 1000));
        logs = vm.getRecordedLogs();
        l = _legs(logs);
        _checkReferred(l, address(rref), 0);
        (pushed, escrowed) = _delivered(logs, address(rref));
        assertEq(escrowed, l.referral, "referral escrowed for the referrer");
        address payable target = payable(makeAddr("i1.refTarget"));
        rref.pull(v2.escrow, target);
        assertEq(target.balance, l.referral, "referrer pulled it");
        assertEq(v2.hook.skimConfig(_pid(coin)).referralPayout, address(v2.escrow), "payout = escrow (D57)");
    }

    /// D52: the pool's protocol floor is frozen into the hook at launch, so the
    /// hook enforces it per swap (not only the factory's launch time bound).
    function test_i1_referral_protocolFloorFrozenIntoHook() public onlyFork {
        address coin = _ownerLaunch(_creditsConfig(address(new I1EmptyTreasury())));
        // f1 passed 0 here until the D52 wiring landed (TODO(D52) in _initializePool); fixed in tree.
        assertEq(
            uint256(v2.hook.minProtocolShareBps(_pid(coin))),
            uint256(v2.factory.minProtocolSkimShareBps()),
            "hook floor == factory minProtocolSkimShareBps"
        );
    }
}
