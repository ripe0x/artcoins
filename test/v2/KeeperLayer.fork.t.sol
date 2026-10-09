// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Addresses} from "../../script/Addresses.sol";
import {RunKeeperLayer} from "../../script/v2/RunKeeperLayer.s.sol";
import {IArtCoinsFeeLocker} from "../../src/interfaces/IArtCoinsFeeLocker.sol";
import {IArtCoinsLpLocker} from "../../src/interfaces/IArtCoinsLpLocker.sol";
import {CollectFlushKeeperLayer} from "../../src/legacy/keepers/CollectFlushKeeperLayer.sol";
import {ForkBase} from "./harness/ForkBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Vm, console2} from "forge-std/Test.sol";

interface IRouterView {
    function owner() external view returns (address);
    function minProcessThreshold() external view returns (uint256);
    function minLayerOutPerWeth() external view returns (uint256);
    function setMinLayerOutPerWeth(uint256) external;
}

interface IControllerView {
    function burnRouter() external view returns (address);
    function treasury() external view returns (address);
    function treasuryBps() external view returns (uint16);
    function burnBps() external view returns (uint16);
}

/// @notice Fork proofs for `CollectFlushKeeperLayer` against the live LAYER fee path (legacy stack).
/// @dev Pinned block 26_130_269 (ForkBase). Skips when the rpc is unreachable or `SKIP_FORK_TESTS=true`.
///      Live router floors do not block a burn at the pin (0x2eDB 5e24 and 0xE600 1.035e25 LAYER per weth,
///      spot 1.62e25), so no floor is pranked except in the two tests that prove the floor guards.
contract KeeperLayer_ForkTest is ForkBase {
    address internal constant LOCKER = Addresses.LEGACY_LOCKER;
    address internal constant LAYER = Addresses.COIN_LAYER;
    address internal constant FEE_LOCKER = Addresses.LEGACY_FEE_LOCKER;
    address internal constant PFC = Addresses.LEGACY_PROTOCOL_FEE_CONTROLLER;
    address internal constant R0 = Addresses.LEGACY_BURN_ROUTER;
    address internal constant R1 = Addresses.OPEN_BURN_ROUTER;
    address internal constant R2 = Addresses.CURRENT_BURN_ROUTER;
    address internal constant CALLER = address(0xBEEF);
    address internal constant GRIEFER = address(0xBAD);

    CollectFlushKeeperLayer internal keeper;
    PoolKey internal key;

    function setUp() public {
        if (!forkMainnet()) return;
        keeper = new CollectFlushKeeperLayer(LOCKER, LAYER, WETH, FEE_LOCKER, PFC, [R0, R1, R2]);
        vm.deal(address(keeper), 0); // create addresses can carry real mainnet dust
        key = IArtCoinsLpLocker(LOCKER).tokenRewards(LAYER).poolKey;
        vm.label(LOCKER, "layerLocker");
        vm.label(FEE_LOCKER, "feeLocker");
        vm.label(PFC, "pfc");
        vm.label(R0, "router0x2eDB");
        vm.label(R1, "router0xE600");
        vm.label(R2, "router0x0EB2");
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    /// @dev buy LAYER with `wethIn` (weth is currency1), sell the bag back, buy again with a third. fees are
    ///      taken in the input currency. each swap runs the hook's own collect for the previous one (and the
    ///      autoforward extension one pipeline stage), so the last buy's weth fee is what stays pending.
    function _makeFees(uint256 wethIn) internal {
        dealWeth(address(this), wethIn + wethIn / 3);
        (, uint256 bag) = swapExactIn(key, false, wethIn, address(this), "");
        swapExactIn(key, true, bag, address(this), "");
        swapExactIn(key, false, wethIn / 3, address(this), "");
    }

    function _fl(address owner, address token) internal view returns (uint256) {
        return IArtCoinsFeeLocker(FEE_LOCKER).availableFees(owner, token);
    }

    function _routerWeth(address r) internal view returns (uint256) {
        return IERC20(WETH).balanceOf(r) + r.balance;
    }

    function _assertKeeperEmpty() internal view {
        assertEq(address(keeper).balance, 0, "keeper eth");
        assertEq(IERC20(WETH).balanceOf(address(keeper)), 0, "keeper weth");
        assertEq(IERC20(LAYER).balanceOf(address(keeper)), 0, "keeper LAYER");
    }

    function _skips(Vm.Log[] memory logs, uint8 step, address target)
        internal
        view
        returns (uint256 n, bytes memory last)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(keeper)
                    && logs[i].topics[0] == CollectFlushKeeperLayer.StepSkipped.selector
                    && uint256(logs[i].topics[1]) == step
                    && address(uint160(uint256(logs[i].topics[2]))) == target
            ) {
                ++n;
                last = abi.decode(logs[i].data, (bytes));
            }
        }
    }

    // ─── tests ───────────────────────────────────────────────────────────

    /// @dev the fee path the keeper is built on, read at the pin.
    function test_layerKeeper_liveReadings() public onlyFork {
        IArtCoinsLpLocker.TokenRewardInfo memory info =
            IArtCoinsLpLocker(LOCKER).tokenRewards(LAYER);
        assertEq(Currency.unwrap(key.currency0), LAYER, "LAYER is currency0");
        assertEq(Currency.unwrap(key.currency1), WETH, "weth is currency1");
        assertEq(info.numPositions, 12);
        assertEq(info.rewardRecipients.length, 3);
        assertEq(info.rewardRecipients[0], LIVE_OWNER);
        assertEq(info.rewardRecipients[1], R0);
        assertEq(info.rewardRecipients[2], PFC);
        assertEq(info.rewardBps[0], 3800);
        assertEq(info.rewardBps[1], 4200);
        assertEq(info.rewardBps[2], 2000);
        assertEq(IControllerView(PFC).burnRouter(), R0, "controller burns at 0x2eDB");
        assertEq(IControllerView(PFC).treasury(), UI_DEFAULT_REFERRER);
        assertEq(IControllerView(PFC).treasuryBps(), 6000);
        assertEq(IControllerView(PFC).burnBps(), 4000);
        assertEq(IRouterView(R0).minLayerOutPerWeth(), 5e24);
        assertEq(IRouterView(R0).minProcessThreshold(), 0.01 ether);
        assertEq(IRouterView(R1).minProcessThreshold(), 0.01 ether);
        assertEq(IRouterView(R2).minProcessThreshold(), 0.01 ether);
        (, uint256 uw, uint256[4] memory c, uint256[3] memory rw, uint256[3] memory rt) =
            keeper.preview();
        console2.log("pin: uncollected weth", uw);
        console2.log("pin: pfc LAYER, pfc weth", c[0], c[1]);
        console2.log("pin: router LAYER, router weth", c[2], c[3]);
        console2.log("pin: router weth+eth 0x2eDB 0xE600 0x0EB2", rw[0], rw[1], rw[2]);
        for (uint256 i; i < 3; ++i) {
            assertLt(rw[i], rt[i], "every router below its threshold at the pin");
        }
    }

    /// @dev full path: collect, claim router and controller slots, split, burn LAYER and weth at 0x2eDB.
    function test_layerKeeper_collectClaimBurn_fork() public onlyFork {
        _makeFees(3 ether);
        (uint256 ul, uint256 uw, uint256[4] memory c,,) = keeper.preview();
        // the hook collects on every swap, so only the last swap's fee is pending, in its input currency
        assertEq(ul, 0, "last swap was a buy: no LAYER fee pending");
        assertGt(uw, 0, "preview sees uncollected weth fees");
        uint256 supplyBefore = IERC20(LAYER).totalSupply();
        uint256 ownerLayerBefore = _fl(LIVE_OWNER, LAYER);
        uint256 ownerWethBefore = _fl(LIVE_OWNER, WETH);
        uint256 treasuryWethBefore = IERC20(WETH).balanceOf(UI_DEFAULT_REFERRER);
        uint256 r0Before = _routerWeth(R0);
        console2.log("router0 weth before, slot weth, pfc slot weth", r0Before, c[3], c[1]);

        vm.recordLogs();
        uint256 g = gasleft();
        vm.prank(CALLER);
        (uint256 lc, uint256 wc, uint256 lbd, uint256 wb, uint256 lb) = keeper.run(true, 0, false);
        console2.log("run(true,0,false) gas", g - gasleft());
        console2.log("collected LAYER, weth", lc, wc);
        console2.log("burned LAYER direct, weth, LAYER bought", lbd, wb, lb);
        assertGt(lbd, 0, "LAYER side fees burned directly");
        (uint256 nSkip,) = _skips(vm.getRecordedLogs(), 5, R0);
        assertEq(nSkip, 0, "router0 weth burn not skipped");

        assertApproxEqAbs(lc, ul, 2, "collected what preview showed (LAYER)");
        assertApproxEqAbs(wc, uw, 2, "collected what preview showed (weth)");
        // live split: owner slot keeps its 38% credit (never claimed by the keeper)
        assertApproxEqAbs(_fl(LIVE_OWNER, LAYER) - ownerLayerBefore, lc * 3800 / 10_000, 2);
        assertApproxEqAbs(_fl(LIVE_OWNER, WETH) - ownerWethBefore, wc * 3800 / 10_000, 2);
        // router and controller slots pushed out (the burn swap's own fee stays pending in the positions)
        assertEq(_fl(R0, WETH), 0, "router weth slot claimed");
        assertEq(_fl(PFC, WETH), 0, "pfc weth slot claimed");
        assertEq(_fl(PFC, LAYER), 0, "pfc LAYER slot claimed");
        assertEq(IERC20(WETH).balanceOf(PFC), 0, "controller split its weth");
        assertGt(
            IERC20(WETH).balanceOf(UI_DEFAULT_REFERRER), treasuryWethBefore, "treasury got 60%"
        );
        // router burned the weth it held
        assertGt(wb, 0.01 ether, "weth burned at 0x2eDB");
        assertGt(lb, 0, "LAYER burned");
        assertEq(_routerWeth(R0), 0, "router0 drained");
        assertEq(IERC20(LAYER).balanceOf(R0), 0, "router0 holds no LAYER");
        assertLt(IERC20(LAYER).totalSupply(), supplyBefore, "supply burned");
        assertGe(
            lb * 1e18 / wb, IRouterView(R0).minLayerOutPerWeth(), "realized rate above owner floor"
        );
        _assertKeeperEmpty();
    }

    /// @dev reward routers (0xE600 open stack, 0x0EB2 current stack) pay 0.5% of the weth they burn to
    ///      msg.sender; the keeper forwards it to its caller. 0x2eDB pays nothing. Router balances topped up
    ///      with eth to stand in for their own inflows (111 protocol leg for 0x0EB2).
    function test_layerKeeper_callerGetsRouterRewards() public onlyFork {
        vm.deal(R1, R1.balance + 0.02 ether);
        vm.deal(R2, R2.balance + 0.02 ether);
        uint256 b1 = _routerWeth(R1);
        uint256 b2 = _routerWeth(R2);
        uint256 callerBefore = CALLER.balance;
        uint256 g = gasleft();
        vm.prank(CALLER);
        (,,, uint256 wb, uint256 lb) = keeper.run(true, 0, false);
        console2.log("two reward router burns gas", g - gasleft());
        assertGt(lb, 0);
        uint256 reward = CALLER.balance - callerBefore;
        console2.log("caller reward (wei)", reward);
        assertEq(reward, b1 * 50 / 10_000 + b2 * 50 / 10_000, "0.5% of each router balance");
        assertApproxEqAbs(wb + reward, b1 + b2, 1e15, "burned the rest (0x0EB2 may fill partially)");
        _assertKeeperEmpty();
    }

    /// @dev an owner floor above spot blocks the weth burn: reported, the rest of the run completes.
    ///      floor 0 (paused) is the router's own `SlippageFloorNotSet`, reported.
    function test_layerKeeper_ownerFloorGuards() public onlyFork {
        _makeFees(3 ether);
        uint256 snap = vm.snapshotState();
        vm.prank(IRouterView(R0).owner());
        IRouterView(R0).setMinLayerOutPerWeth(1e27); // ~60x spot
        vm.recordLogs();
        vm.prank(CALLER);
        (, uint256 wc,, uint256 wb,) = keeper.run(true, 0, false);
        (uint256 n, bytes memory reason) = _skips(vm.getRecordedLogs(), 5, R0);
        assertEq(n, 1, "burn reported as skipped");
        assertGt(reason.length, 0, "with the router's revert data");
        assertGt(wc, 0, "collect still ran");
        assertEq(wb, 0, "nothing burned");
        assertGt(_routerWeth(R0), 0.01 ether, "weth stays at the router");
        _assertKeeperEmpty();

        vm.revertToState(snap);
        vm.prank(IRouterView(R0).owner());
        IRouterView(R0).setMinLayerOutPerWeth(0);
        vm.recordLogs();
        vm.prank(CALLER);
        keeper.run(true, 0, false);
        (n, reason) = _skips(vm.getRecordedLogs(), 5, R0);
        assertEq(n, 1);
        assertEq(
            bytes4(reason), bytes4(keccak256("SlippageFloorNotSet()")), "router guard reported"
        );
    }

    /// @dev the caller's rate only tightens: an impossible rate makes the burn skip, not the run revert.
    function test_layerKeeper_callerRate_tightensOnly() public onlyFork {
        _makeFees(3 ether);
        vm.prank(CALLER);
        (, uint256 wc, uint256 lbd, uint256 wb,) = keeper.run(true, type(uint128).max, false);
        assertGt(lbd, 0, "LAYER burned even when the weth burn skips");
        assertGt(wc, 0);
        assertEq(wb, 0, "impossible rate: burn skipped");
        // doBurn false leaves weth for later, still claims and burns LAYER
        vm.prank(CALLER);
        (,,, uint256 wb2,) = keeper.run(false, 0, false);
        assertEq(wb2, 0, "doBurn false: no weth burn");
        assertGt(_routerWeth(R0), 0.01 ether);
    }

    function test_layerKeeper_nothingPending_noRevert() public onlyFork {
        vm.prank(CALLER);
        keeper.run(true, 0, false); // drain whatever the pin holds
        uint256 callerBefore = CALLER.balance;
        uint256 g = gasleft();
        vm.prank(CALLER);
        (uint256 lc, uint256 wc, uint256 lbd, uint256 wb, uint256 lb) = keeper.run(true, 0, true);
        console2.log("idle run gas", g - gasleft());
        assertEq(lc, 0);
        assertEq(wc, 0);
        assertEq(lbd, 0);
        assertEq(wb, 0);
        assertEq(lb, 0);
        assertEq(CALLER.balance, callerBefore, "no reward when nothing happened");
        _assertKeeperEmpty();
    }

    /// @dev weth and LAYER dust sent to the keeper leaves with the caller, unwrapped only on request.
    function test_layerKeeper_forwardsDust_unwrapOnRequest() public onlyFork {
        dealWeth(address(keeper), 1e15);
        deal(LAYER, address(keeper), 5e18);
        uint256 snap = vm.snapshotState();
        vm.prank(CALLER);
        keeper.run(false, 0, false);
        assertEq(IERC20(WETH).balanceOf(CALLER), 1e15, "weth forwarded as weth");
        assertEq(IERC20(LAYER).balanceOf(CALLER), 5e18);
        _assertKeeperEmpty();
        vm.revertToState(snap);
        uint256 eth0 = CALLER.balance;
        vm.prank(CALLER);
        keeper.run(false, 0, true);
        assertEq(CALLER.balance - eth0, 1e15, "weth unwrapped");
        _assertKeeperEmpty();
    }

    /// @dev D49: a collect revert for a reason other than gas bubbles.
    function test_layerKeeper_collectRevert_bubbles() public onlyFork {
        vm.mockCallRevert(
            LOCKER,
            abi.encodeCall(IArtCoinsLpLocker.collectRewards, (LAYER)),
            bytes("collect broke")
        );
        vm.prank(CALLER);
        vm.expectRevert(bytes("collect broke"));
        keeper.run(true, 0, false);
    }

    /// @dev gas limits from 2.6M down to 0.3M with fees pending and router0 above threshold: every run
    ///      either reverts or does the whole job (collect, claims, burn). none succeeds with a step dropped.
    function test_layerKeeper_lowGas_neverSilentlySkips() public onlyFork {
        _makeFees(3 ether);
        uint256 snap = vm.snapshotState();
        uint256 reverted;
        uint256 succeeded;
        uint256 lowest;
        for (uint256 limit = 2_600_000; limit >= 300_000; limit -= 50_000) {
            (bool ok, bytes memory ret) = address(keeper).call{gas: limit}(
                abi.encodeCall(CollectFlushKeeperLayer.run, (true, 0, false))
            );
            if (ok) {
                (, uint256 wc,, uint256 wb, uint256 lb) =
                    abi.decode(ret, (uint256, uint256, uint256, uint256, uint256));
                assertGt(wc, 0, "succeeded without collecting");
                assertGt(wb, 0, "succeeded without burning weth");
                assertGt(lb, 0);
                assertEq(_fl(R0, WETH), 0, "succeeded without claiming");
                assertEq(_fl(PFC, WETH), 0);
                ++succeeded;
                lowest = limit;
            } else {
                ++reverted;
            }
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
        console2.log("sweep succeeded", succeeded);
        console2.log("sweep reverted", reverted);
        console2.log("lowest limit that completed", lowest);
        assertGt(succeeded, 0);
        assertGt(reverted, 0);
    }

    /// @dev LF-02 shape check. `feeLocker.claim` is permissionless and pushes erc20 to the slot owner. on the
    ///      111 swapper that strands eth (the swapper books by ledger). here both pushed recipients book by
    ///      balance (`processBurnWeth`, `processBurnLayer`, `processFees` read balanceOf), so a third party
    ///      claim strands nothing: the keeper still burns and splits it. documents the absence of the shape.
    function test_layerKeeper_thirdPartyClaim_doesNotStrand() public onlyFork {
        _makeFees(3 ether);
        IArtCoinsLpLocker(LOCKER).collectRewards(LAYER);
        uint256 slotWeth = _fl(R0, WETH);
        assertGt(slotWeth, 0, "router weth slot credited");
        assertGt(_fl(PFC, WETH), 0, "pfc weth slot credited");
        assertGt(_fl(PFC, LAYER), 0, "pfc LAYER slot credited");
        uint256 r0Before = _routerWeth(R0);
        vm.startPrank(GRIEFER);
        IArtCoinsFeeLocker(FEE_LOCKER).claim(R0, WETH);
        IArtCoinsFeeLocker(FEE_LOCKER).claim(PFC, WETH);
        IArtCoinsFeeLocker(FEE_LOCKER).claim(PFC, LAYER);
        vm.stopPrank();
        assertEq(_routerWeth(R0), r0Before + slotWeth, "router holds the pushed weth as balance");
        assertGt(IERC20(WETH).balanceOf(PFC), 0, "controller holds the pushed weth as balance");
        // the owner slot can also be pushed by anyone, it only ever pays the owner
        uint256 ownerLayer = IERC20(LAYER).balanceOf(LIVE_OWNER);
        uint256 credit = _fl(LIVE_OWNER, LAYER);
        vm.prank(GRIEFER);
        IArtCoinsFeeLocker(FEE_LOCKER).claim(LIVE_OWNER, LAYER);
        assertEq(IERC20(LAYER).balanceOf(LIVE_OWNER), ownerLayer + credit, "paid to the owner only");

        vm.prank(CALLER);
        (,,, uint256 wb,) = keeper.run(true, 0, false);
        assertGe(wb, r0Before + slotWeth, "pushed weth burned, nothing stranded");
        assertEq(IERC20(WETH).balanceOf(PFC), 0, "controller balance split");
        _assertKeeperEmpty();
    }

    /// @dev the runner script's quote: simulate with rate 0 (router floors), take the realized rate minus
    ///      slippage. the quoted rate burns; it sits above the router floor.
    function test_layerKeeper_scriptQuote_burnsAtDefaultSlippage() public onlyFork {
        _makeFees(3 ether);
        RunKeeperLayer script = new RunKeeperLayer();
        uint256 rate = script.quoteRate(keeper, 200);
        console2.log("quoted rate (LAYER per weth)", rate);
        assertGt(rate, IRouterView(R0).minLayerOutPerWeth(), "quote tighter than the owner floor");
        vm.prank(CALLER);
        (,,, uint256 wb, uint256 lb) = keeper.run(true, rate, false);
        assertGt(wb, 0);
        assertGe(lb * 1e18 / wb, rate);
    }
}
