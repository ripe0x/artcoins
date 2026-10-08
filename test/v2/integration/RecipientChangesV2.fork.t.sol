// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// D76: the coin admin changes a coin's locker reward recipients after launch,
// the change takes effect on the next collect, the protocol slot stays frozen,
// and a lock or a renounce freezes the setter. Also D76(2): a launch with lp
// fee 0 works and the protocol skim floor still pays. Full v2 stack on a
// mainnet fork; skips cleanly without an rpc.

import {IntegrationV2Base} from "./IntegrationV2Base.sol";

import {Constants} from "../../../src/Constants.sol";
import {ArtCoinsFeeEscrowV2} from "../../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {ArtCoinsHookV2} from "../../../src/v2/hooks/ArtCoinsHookV2.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsLpLockerV2} from "../../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {ArtCoinsLpLockerV2} from "../../../src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {console2} from "forge-std/console2.sol";

contract RecipientChangesV2ForkTest is IntegrationV2Base {
    using PoolIdLibrary for PoolKey;

    address internal treasury = makeAddr("rc.treasury");

    function _launchCredits() internal returns (address coin, PoolKey memory key) {
        coin = _ownerLaunch(_creditsConfig(treasury));
        key = _key(coin);
        // reward slots: [0] project (treasury), [1] protocol (controller).
        address[] memory rr = v2.locker.rewardRecipients(coin);
        assertEq(rr.length, 2, "project + protocol slot");
        assertEq(rr[0], treasury, "project slot");
        assertEq(rr[1], address(v2.controller), "protocol slot");
    }

    // ── locker reward recipient ──────────────────────────────────────────

    /// accrued lp fees go to the old recipient (the change collects first); only
    /// fees after the change reach the new recipient.
    function test_locker_setRewardRecipient_accruedToOld_newAfterChange() public onlyFork {
        (address coin, PoolKey memory key) = _launchCredits();
        address payable newArtist = payable(makeAddr("rc.newArtist"));

        // accrue lp fees on both sides.
        _buyAndSell(key, 0.5 ether);

        // the change collects the accrued fees to the current (old) recipient.
        uint256 oldEth0 = treasury.balance;
        uint256 oldCoin0 = IERC20(coin).balanceOf(treasury);
        vm.expectEmit(true, true, false, true, address(v2.locker));
        emit IArtCoinsLpLockerV2.RewardRecipientSet(coin, 0, treasury, newArtist);
        vm.prank(admin);
        v2.locker.setRewardRecipient(coin, 0, newArtist);
        assertEq(v2.locker.rewardRecipients(coin)[0], newArtist, "project slot repointed");
        uint256 toOld = (treasury.balance - oldEth0) + (IERC20(coin).balanceOf(treasury) - oldCoin0);
        assertGt(toOld, 0, "accrued share paid to the old recipient at the change");
        assertEq(newArtist.balance, 0, "new recipient no eth from accrued fees");
        assertEq(IERC20(coin).balanceOf(newArtist), 0, "new recipient no coin from accrued fees");

        // fees accrued after the change reach the new recipient.
        _buyAndSell(key, 0.5 ether);
        uint256 nEth0 = newArtist.balance;
        uint256 nCoin0 = IERC20(coin).balanceOf(newArtist);
        v2.locker.collectRewards(coin);
        uint256 toNew = (newArtist.balance - nEth0) + (IERC20(coin).balanceOf(newArtist) - nCoin0);
        assertGt(toNew, 0, "post-change fees paid to the new recipient");
    }

    function test_locker_setRewardRecipient_protocolSlotFrozen() public onlyFork {
        (address coin,) = _launchCredits();
        vm.prank(admin);
        vm.expectRevert(ArtCoinsLpLockerV2.ProtocolSlotFrozen.selector);
        v2.locker.setRewardRecipient(coin, 1, makeAddr("rc.x"));
    }

    function test_locker_setRewardRecipient_nonAdminReverts() public onlyFork {
        (address coin,) = _launchCredits();
        vm.prank(stranger);
        vm.expectRevert(ArtCoinsLpLockerV2.NotCoinAdmin.selector);
        v2.locker.setRewardRecipient(coin, 0, makeAddr("rc.x"));
    }

    function test_locker_setRewardRecipient_rejectedAddressesRevert() public onlyFork {
        (address coin, PoolKey memory key) = _launchCredits();
        // parity with the factory launch checks the locker can look up.
        address[9] memory bad = [
            coin,
            address(v2.locker),
            v2.locker.feeEscrow(),
            address(key.hooks),
            POOL_MANAGER,
            POSITION_MANAGER,
            address(v2.mev),
            address(v2.factory),
            address(v2.tokenDeployer)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(
                abi.encodeWithSelector(ArtCoinsLpLockerV2.RecipientCannotReceive.selector, bad[i])
            );
            v2.locker.setRewardRecipient(coin, 0, bad[i]);
        }
        vm.prank(admin);
        vm.expectRevert(IArtCoinsLpLockerV2.ZeroAddress.selector);
        v2.locker.setRewardRecipient(coin, 0, address(0));
    }

    /// both setters reject both escrows, even when the hook and locker run on
    /// distinct escrows (each setter reads the sibling's escrow).
    function test_recipientSetters_rejectBothEscrows() public onlyFork {
        (address coin, PoolKey memory key) = _launchCredits();
        PoolId pid = key.toId();
        address hookEscrow = address(v2.escrow);

        // give the locker a distinct escrow (owner only; new escrow lists the
        // locker as a core depositor and matches constantsHash).
        ArtCoinsFeeEscrowV2 escrow2 = new ArtCoinsFeeEscrowV2(LIVE_OWNER);
        vm.prank(LIVE_OWNER);
        escrow2.addDepositor(address(v2.locker), true);
        vm.prank(LIVE_OWNER);
        v2.locker.setFeeEscrow(address(escrow2));
        assertTrue(address(escrow2) != hookEscrow, "distinct escrows");
        assertEq(v2.locker.feeEscrow(), address(escrow2), "locker on escrow2");
        assertEq(v2.hook.globals().feeEscrow, hookEscrow, "hook on the stack escrow");

        // the hook setter rejects its own escrow and the locker's escrow.
        for (uint256 i; i < 2; ++i) {
            address esc = i == 0 ? hookEscrow : address(escrow2);
            vm.prank(admin);
            vm.expectRevert(
                abi.encodeWithSelector(ArtCoinsHookV2.RecipientCannotReceive.selector, esc)
            );
            v2.hook.setBountyRecipient(pid, payable(esc));
        }
        // the locker setter rejects its own escrow and the hook's escrow.
        for (uint256 i; i < 2; ++i) {
            address esc = i == 0 ? address(escrow2) : hookEscrow;
            vm.prank(admin);
            vm.expectRevert(
                abi.encodeWithSelector(ArtCoinsLpLockerV2.RecipientCannotReceive.selector, esc)
            );
            v2.locker.setRewardRecipient(coin, 0, esc);
        }
    }

    function test_hook_setBountyRecipient_rejectedAddressesRevert() public onlyFork {
        (address coin, PoolKey memory key) = _launchCredits();
        PoolId pid = key.toId();
        address[9] memory bad = [
            coin,
            address(v2.hook),
            POOL_MANAGER,
            address(v2.escrow),
            address(v2.mev),
            address(v2.locker),
            address(v2.factory),
            address(v2.tokenDeployer),
            POSITION_MANAGER
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(
                abi.encodeWithSelector(ArtCoinsHookV2.RecipientCannotReceive.selector, bad[i])
            );
            v2.hook.setBountyRecipient(pid, payable(bad[i]));
        }
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHookV2.BountyRecipientZero.selector);
        v2.hook.setBountyRecipient(pid, payable(address(0)));
    }

    /// a project slot whose recipient equals the protocol recipient is still
    /// editable; only the recorded protocol slot index is frozen.
    function test_locker_setRewardRecipient_projectSlotEqualProtocolRecipientEditable()
        public
        onlyFork
    {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _creditsConfig(treasury);
        address[] memory rr = new address[](1);
        rr[0] = address(v2.controller); // a project recipient equal to the protocol recipient
        uint16[] memory bps = new uint16[](1);
        bps[0] = 8000;
        c.locker.rewardRecipients = rr;
        c.locker.rewardBps = bps;
        address coin = _ownerLaunch(c);

        address[] memory got = v2.locker.rewardRecipients(coin);
        assertEq(got[0], address(v2.controller), "project slot is the controller");
        assertEq(got[1], address(v2.controller), "protocol slot is the controller");

        // the recorded protocol slot (index 1) is frozen
        vm.prank(admin);
        vm.expectRevert(ArtCoinsLpLockerV2.ProtocolSlotFrozen.selector);
        v2.locker.setRewardRecipient(coin, 1, makeAddr("rc.x"));

        // the project slot (index 0) is editable despite equalling the protocol recipient
        address newR = makeAddr("rc.newProject");
        vm.prank(admin);
        v2.locker.setRewardRecipient(coin, 0, newR);
        assertEq(v2.locker.rewardRecipients(coin)[0], newR, "project slot editable");
    }

    function test_locker_setRewardRecipient_outOfRangeReverts() public onlyFork {
        (address coin,) = _launchCredits();
        vm.prank(admin);
        vm.expectRevert(ArtCoinsLpLockerV2.RewardIndexOutOfRange.selector);
        v2.locker.setRewardRecipient(coin, 2, makeAddr("rc.x"));
    }

    function test_locker_protocolSlotIndex_view() public onlyFork {
        (address coin,) = _launchCredits();
        (bool exists, uint256 index) = v2.locker.protocolSlotIndex(coin);
        assertTrue(exists, "credits launch reserves a protocol slot");
        assertEq(index, 1, "protocol slot is the appended last index");
    }

    function test_locker_setRewardRecipient_lockFreezes() public onlyFork {
        (address coin,) = _launchCredits();
        vm.prank(admin);
        _token(coin).lockRecipients();
        vm.prank(admin);
        vm.expectRevert(ArtCoinsLpLockerV2.RecipientsLocked.selector);
        v2.locker.setRewardRecipient(coin, 0, makeAddr("rc.x"));
    }

    function test_locker_setRewardRecipient_renounceFreezes() public onlyFork {
        (address coin,) = _launchCredits();
        vm.prank(admin);
        _token(coin).renounceAdmin();
        vm.prank(admin);
        vm.expectRevert(ArtCoinsLpLockerV2.NotCoinAdmin.selector);
        v2.locker.setRewardRecipient(coin, 0, makeAddr("rc.x"));
    }

    /// one call freezes both the hook bounty and the locker reward setters.
    function test_lockRecipients_freezesHookAndLocker() public onlyFork {
        (address coin, PoolKey memory key) = _launchCredits();
        vm.prank(admin);
        _token(coin).lockRecipients();
        vm.prank(admin);
        vm.expectRevert();
        v2.hook.setBountyRecipient(key.toId(), payable(makeAddr("rc.b")));
        vm.prank(admin);
        vm.expectRevert(ArtCoinsLpLockerV2.RecipientsLocked.selector);
        v2.locker.setRewardRecipient(coin, 0, makeAddr("rc.x"));
    }

    // ── D76(2): lp fee 0 launch, protocol skim floor still pays ───────────

    function test_lpFeeZero_launch_skimProtocolStillPays() public onlyFork {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _creditsConfig(treasury);
        c.fee.lpFee = 0; // pure skim, no lp fee
        address coin = _ownerLaunch(c);
        PoolKey memory key = _key(coin);
        assertEq(v2.hook.skimConfig(key.toId()).lpFee, 0, "lp fee 0 frozen");
        (,,, uint24 poolFee) = readSlot0(key);
        assertEq(poolFee, 0, "pool runs with 0 lp fee");

        _pastWindow();
        vm.recordLogs();
        _buy(key, 0.5 ether);
        Legs memory l = _legs(vm.getRecordedLogs());
        assertGt(l.protocol, 0, "D52 protocol skim floor still pays");
        assertGt(l.bounty, 0, "bounty leg paid");
    }

    /// D76(7): during the anti sniper window the skim above the baseline goes
    /// entirely to the bounty recipient. A buy in the window: the protocol leg
    /// equals the baseline share net of the bounty cut; the whole extra is
    /// bounty.
    function test_antiSniperWindow_extraSkimAllToBounty() public onlyFork {
        (, PoolKey memory key) = _launchCredits();
        // buy inside the window (setUp just launched, module active).
        vm.recordLogs();
        _buy(key, 0.1 ether);
        Legs memory l = _legs(vm.getRecordedLogs());
        assertEq(l.splits, 1, "one skim");
        assertEq(l.referral, 0, "no referrer");

        uint256 total = l.bounty + l.protocol;
        // the protocol leg is a pure share of the baseline skim:
        //   protocol = base * (BPS - bountyBps) / BPS, so base reconstructs from it.
        uint256 base = l.protocol * Constants.BPS / (Constants.BPS - BOUNTY_BPS);
        assertGt(total, base, "in window: total skim above the baseline");
        uint256 extra = total - base; // the anti sniper amount
        // bounty = baseline bounty cut + the whole extra.
        uint256 bountyFromBase = base * BOUNTY_BPS / Constants.BPS;
        assertApproxEqAbs(l.bounty, bountyFromBase + extra, 3, "extra all to bounty");

        console2.log("anti sniper window split for a 0.1 eth in-window buy:");
        console2.log("  total skim        ", total);
        console2.log("  baseline portion  ", base);
        console2.log("  bounty leg        ", l.bounty);
        console2.log("  protocol leg      ", l.protocol);
        console2.log("  extra to bounty   ", extra);
    }
}
