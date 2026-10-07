// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// package i1, part 4: fee flow end to end on a credits engine coin whose 80%
// locker slot is a FeeAutoSwapperV2 (endRecipient = the treasury). swaps
// accrue skim and lp fees; ArtCoinsKeeperV2.collectAndForward collects,
// flushes and converts the swapper slot to the treasury; the protocol fee
// controller splits to the protocol treasury and the burn router; the burn
// router buys and burns (one per block); keepers are paid. every wei of eth
// is accounted per phase and in total:
//   sum of recipient deltas + escrow credits + eth burned == fees taken
// where fees taken = skim legs + skim refunds + lp eth collected + convert
// proceeds, all read from the contracts' own events.

import {IntegrationV2Base} from "./IntegrationV2Base.sol";
import {I1EmptyTreasury} from "./mocks/I1Mocks.sol";

import {FeeAutoSwapperV2} from "../../../src/v2/FeeAutoSwapperV2.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IBurnRouterV2} from "../../../src/v2/interfaces/IBurnRouterV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

contract FeeFlowV2ForkTest is IntegrationV2Base {
    bytes32 internal constant REWARDS_COLLECTED_SIG =
        keccak256("RewardsCollected(address,uint256,uint256)");
    bytes32 internal constant CONVERTED_SIG =
        keccak256("Converted(address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant BURNED_SIG = keccak256("Burned(address,uint256,uint256,uint256)");

    I1EmptyTreasury internal treasury;
    FeeAutoSwapperV2 internal sw;
    address internal coin;
    PoolKey internal key;
    address internal protocolTreasury = makeAddr("i1.protocolTreasury");
    address internal burnCaller = makeAddr("i1.burnCaller");

    function setUp() public override {
        super.setUp();
        if (!onFork) return;
        treasury = new I1EmptyTreasury();
        sw = _newSwapper(address(treasury));
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _creditsConfig(address(treasury));
        c.locker.rewardRecipients[0] = address(sw);
        coin = _ownerLaunch(c);
        sw.setup(coin);
        key = _key(coin);
        vm.startPrank(LIVE_OWNER);
        v2.controller.setTreasury(protocolTreasury);
        v2.locker.setKeeperRewardBps(100); // 1%, so the keeper reward path is live
        v2.burnRouter.initialize(coin, key);
        vm.stopPrank();
        _pastWindow();
    }

    /// eth held by every party a fee can reach, plus every escrow credit.
    function _actorsEth() internal view returns (uint256) {
        return address(treasury).balance + address(v2.controller).balance + protocolTreasury.balance
            + address(v2.burnRouter).balance + address(sw).balance + address(v2.keeper).balance
            + keeperCaller.balance + burnCaller.balance + address(v2.locker).balance
            + address(v2.hook).balance + _owed();
    }

    function _coinOf(address a) internal view returns (uint256) {
        return IERC20(coin).balanceOf(a);
    }

    function _skimTotal(Legs memory l) internal pure returns (uint256) {
        return l.bounty + l.protocol + l.referral + l.refunded;
    }

    function test_i1_feeFlow_keeperCollectFlushConvert_controllerSplit_burn_everyWeiAccounted()
        public
        onlyFork
    {
        uint256 start = _actorsEth();

        // ── phase 1: trading accrues skim (now) and lp fees (in the pool) ──
        vm.recordLogs();
        for (uint256 i; i < 5; ++i) {
            _buyAndSell(key, 3 ether);
        }
        Legs memory l1 = _legs(vm.getRecordedLogs());
        uint256 fees1 = _skimTotal(l1);
        assertEq(l1.splits, 10);
        assertEq(address(treasury).balance, l1.bounty, "bounty legs to the treasury");
        assertEq(address(v2.controller).balance, l1.protocol, "protocol legs to the controller");
        assertEq(_actorsEth() - start, fees1, "phase 1: every skim wei delivered");

        // ── phase 2: keeper collects, flushes and converts the swapper slot ──
        vm.roll(vm.getBlockNumber() + 1);
        uint256 a = _actorsEth();
        uint256 swCoin0 = _coinOf(address(sw));
        uint256 ctrlCoin0 = _coinOf(address(v2.controller));
        uint256 treasury0 = address(treasury).balance;
        vm.recordLogs();
        vm.prank(keeperCaller);
        v2.keeper.collectAndForward(coin, true, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Legs memory l2 = _legs(logs);
        (uint256 lpEth, uint256 lpCoin, uint256 coinIn, uint256 convOut) = _phase2(logs);
        assertGt(lpEth, 0, "eth lp fees collected");
        assertGt(lpCoin, 0, "coin lp fees collected");
        assertGt(convOut, 0, "converted");
        uint256 fees2 = lpEth + convOut + _skimTotal(l2);
        assertEq(
            _actorsEth() - a, fees2, "phase 2: lp eth + convert proceeds + its skim, all delivered"
        );
        assertEq(address(sw).balance, 0, "swapper slot flushed");
        assertGt(address(treasury).balance - treasury0, 0, "treasury paid by the swapper");
        assertGt(keeperCaller.balance, 0, "keeper rewards forwarded to the caller");
        assertEq(address(v2.keeper).balance, 0, "keeper holds nothing");
        assertEq(address(v2.locker).balance, 0, "locker holds nothing");
        assertEq(
            lpCoin,
            (_coinOf(address(sw)) - swCoin0) + coinIn
                + (_coinOf(address(v2.controller)) - ctrlCoin0) + _coinOf(address(v2.keeper))
                + _coinOf(keeperCaller) + v2.escrow.totalOwed(coin),
            "coin lp fees: swapper slot (held + converted) + protocol slot"
        );

        // ── phase 3: the protocol fee controller splits, anyone can call ──
        a = _actorsEth();
        uint256 ctrlEth = address(v2.controller).balance;
        uint256 router0 = address(v2.burnRouter).balance;
        uint256 pt0 = protocolTreasury.balance;
        vm.prank(stranger);
        v2.controller.processFees(address(0));
        uint256 burnShare = ctrlEth - (ctrlEth * v2.controller.treasuryBps()) / 10_000;
        assertEq(address(v2.controller).balance, 0, "controller emptied");
        assertEq(protocolTreasury.balance - pt0, ctrlEth - burnShare, "treasury share");
        assertEq(address(v2.burnRouter).balance - router0, burnShare, "burn share");
        assertEq(_actorsEth(), a, "phase 3: an internal move");
        uint256 ctrlCoin = _coinOf(address(v2.controller));
        uint256 supply0 = IERC20(coin).totalSupply();
        vm.prank(stranger);
        v2.controller.processFees(coin);
        uint256 coinBurn = ctrlCoin - (ctrlCoin * v2.controller.treasuryBps()) / 10_000;
        assertEq(supply0 - IERC20(coin).totalSupply(), coinBurn, "coin burn share burned");
        assertEq(_coinOf(protocolTreasury), ctrlCoin - coinBurn, "coin treasury share");

        // ── phase 4: the burn router buys and burns, one per block ──
        vm.roll(vm.getBlockNumber() + 1);
        assertGe(
            address(v2.burnRouter).balance, v2.burnRouter.minProcessThreshold(), "router funded"
        );
        a = _actorsEth();
        supply0 = IERC20(coin).totalSupply();
        vm.recordLogs();
        vm.prank(burnCaller);
        (uint256 ethIn, uint256 burned) = v2.burnRouter.processBurn(0);
        logs = vm.getRecordedLogs();
        Legs memory l4 = _legs(logs);
        uint256 reward = _burnReward(logs);
        uint256 paid = ethIn + l4.refunded; // eth the router settled into the pool
        assertGt(burned, 0);
        assertEq(supply0 - IERC20(coin).totalSupply(), burned, "coin burned");
        assertEq(burnCaller.balance, reward, "burn keeper paid");
        assertGt(reward, 0, "burn keeper reward");
        assertEq(
            _actorsEth() + paid, a + _skimTotal(l4), "phase 4: eth in = eth burned, skim delivered"
        );
        vm.prank(burnCaller);
        vm.expectRevert(IBurnRouterV2.AlreadyBurnedThisBlock.selector);
        v2.burnRouter.processBurn(0);

        // ── total ──
        uint256 feesTaken = fees1 + fees2 + _skimTotal(l4);
        uint256 delivered = _actorsEth() - start;
        assertEq(
            delivered + paid,
            feesTaken,
            "recipient deltas + escrow credits + eth burned == fees taken"
        );
        console2.log("i1 fee flow: fees taken (wei)", feesTaken);
        console2.log("  skim legs and refunds", fees1 + _skimTotal(l2) + _skimTotal(l4));
        console2.log("  lp eth collected", lpEth);
        console2.log("  convert proceeds", convOut);
        console2.log("  eth burned (router paid in)", paid);
        console2.log("  held by recipients and escrow", delivered);
        console2.log("  coin burned by router / controller", burned, coinBurn);
        _assertHookHoldsNothing(key);
    }

    function _phase2(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 lpEth, uint256 lpCoin, uint256 coinIn, uint256 convOut)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory g = logs[i];
            if (g.topics.length == 0) continue;
            if (g.emitter == address(v2.locker) && g.topics[0] == REWARDS_COLLECTED_SIG) {
                (uint256 x, uint256 y) = abi.decode(g.data, (uint256, uint256));
                lpEth += x;
                lpCoin += y;
            } else if (g.emitter == address(sw) && g.topics[0] == CONVERTED_SIG) {
                (uint256 cin, uint256 out,,) =
                    abi.decode(g.data, (uint256, uint256, uint256, uint256));
                coinIn += cin;
                convOut += out;
            }
        }
    }

    function _burnReward(Vm.Log[] memory logs) internal view returns (uint256 reward) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory g = logs[i];
            if (
                g.emitter == address(v2.burnRouter) && g.topics.length != 0
                    && g.topics[0] == BURNED_SIG
            ) {
                (,, reward) = abi.decode(g.data, (uint256, uint256, uint256));
            }
        }
    }
}
