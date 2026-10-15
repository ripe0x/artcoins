// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// package i1, part 4: fee flow end to end on a credits engine coin. swaps
// accrue skim (eth side) and the hook pushes the bounty and protocol legs; the
// protocol fee controller splits to the protocol treasury and the burn router;
// the burn router buys and burns (one per block); the burn keeper is paid.
// every wei of eth is accounted per phase and in total:
//   sum of recipient deltas + escrow credits + eth burned == fees taken
// where fees taken = skim legs + skim refunds, read from the hook's own events.

import {IntegrationV2Base} from "./IntegrationV2Base.sol";

import {Addresses} from "../../../script/Addresses.sol";
import {I1EmptyTreasury} from "./mocks/I1Mocks.sol";

import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IBurnRouterV2} from "../../../src/v2/interfaces/IBurnRouterV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

contract FeeFlowV2ForkTest is IntegrationV2Base {
    bytes32 internal constant BURNED_SIG = keccak256("Burned(address,uint256,uint256,uint256)");

    I1EmptyTreasury internal treasury;
    address internal coin;
    PoolKey internal key;
    address internal protocolTreasury = makeAddr("i1.protocolTreasury");
    address internal burnCaller = makeAddr("i1.burnCaller");
    address internal constant LAYER = Addresses.COIN_LAYER;

    function setUp() public override {
        super.setUp();
        if (!onFork) return;
        treasury = new I1EmptyTreasury();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _creditsConfig(address(treasury));
        coin = _ownerLaunch(c);
        key = _key(coin);
        vm.prank(LIVE_OWNER);
        v2.controller.setTreasury(protocolTreasury);
        _pastWindow();
    }

    /// eth held by every party a fee can reach (the router's weth included), plus every escrow credit.
    function _actorsEth() internal view returns (uint256) {
        return address(treasury).balance + address(v2.controller).balance + protocolTreasury.balance
            + address(v2.burnRouter).balance + IERC20(WETH).balanceOf(address(v2.burnRouter))
            + burnCaller.balance + address(v2.hook).balance + _owed();
    }

    function _skimTotal(Legs memory l) internal pure returns (uint256) {
        return l.bounty + l.protocol + l.referral + l.refunded;
    }

    function test_i1_feeFlow_controllerSplit_burn_everyWeiAccounted() public onlyFork {
        uint256 start = _actorsEth();

        // ── phase 1: trading accrues skim, the hook pushes the legs ──
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

        // ── phase 2: the protocol fee controller splits, anyone can call ──
        uint256 a = _actorsEth();
        uint256 ctrlEth = address(v2.controller).balance;
        uint256 router0 = address(v2.burnRouter).balance;
        uint256 pt0 = protocolTreasury.balance;
        vm.prank(stranger);
        v2.controller.processFees();
        uint256 burnShare = ctrlEth - (ctrlEth * v2.controller.treasuryBps()) / 10_000;
        assertEq(address(v2.controller).balance, 0, "controller emptied");
        assertEq(protocolTreasury.balance - pt0, ctrlEth - burnShare, "treasury share");
        assertEq(address(v2.burnRouter).balance - router0, burnShare, "burn share");
        assertEq(_actorsEth(), a, "phase 2: an internal move");

        // ── phase 3: the burn router buys and burns LAYER, one per block ──
        vm.roll(vm.getBlockNumber() + 1);
        vm.fee(0.5 gwei); // under the router's REWARD_MAX_BASEFEE, so the keeper is paid
        assertGt(address(v2.burnRouter).balance, 0, "router funded");
        a = _actorsEth();
        uint256 supply0 = IERC20(LAYER).totalSupply();
        vm.recordLogs();
        vm.prank(burnCaller);
        (uint256 ethIn, uint256 burned) = v2.burnRouter.processBurn(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Legs memory l4 = _legs(logs);
        uint256 reward = _burnReward(logs);
        uint256 paid = ethIn; // eth the router wrapped and settled into the LAYER pool
        assertGt(burned, 0);
        assertEq(supply0 - IERC20(LAYER).totalSupply(), burned, "LAYER burned");
        assertEq(burnCaller.balance, reward, "burn keeper paid");
        assertGt(reward, 0, "burn keeper reward");
        assertEq(
            _actorsEth() + paid, a + _skimTotal(l4), "phase 3: eth in = eth burned, skim delivered"
        );
        vm.prank(burnCaller);
        vm.expectRevert(IBurnRouterV2.AlreadyBurnedThisBlock.selector);
        v2.burnRouter.processBurn(0);

        // ── total ──
        uint256 feesTaken = fees1 + _skimTotal(l4);
        uint256 delivered = _actorsEth() - start;
        assertEq(
            delivered + paid,
            feesTaken,
            "recipient deltas + escrow credits + eth burned == fees taken"
        );
        console2.log("i1 fee flow: fees taken (wei)", feesTaken);
        console2.log("  eth burned (router paid in)", paid);
        console2.log("  held by recipients and escrow", delivered);
        console2.log("  LAYER burned by the router", burned);
        _assertHookHoldsNothing(key);
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
