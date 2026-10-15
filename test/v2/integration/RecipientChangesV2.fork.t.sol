// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// D76: the coin admin changes a coin's bounty recipient after launch, the
// protocol recipient is fixed at launch, and lock() or a renounce freezes the
// setter. Also D76(2): the protocol skim floor pays on every swap. Full v2
// stack on a mainnet fork; skips cleanly without an rpc.

import {IntegrationV2Base} from "./IntegrationV2Base.sol";

import {Constants} from "../../../src/Constants.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {console2} from "forge-std/console2.sol";

contract RecipientChangesV2ForkTest is IntegrationV2Base {
    using PoolIdLibrary for PoolKey;

    address internal treasury = makeAddr("rc.treasury");

    function _launchCredits() internal returns (address coin, PoolKey memory key) {
        coin = _ownerLaunch(_creditsConfig(treasury));
        key = _key(coin);
        assertEq(v2.hook.skimConfig(key.toId()).bountyRecipient, treasury, "bounty recipient");
    }

    // ── hook bounty recipient ────────────────────────────────────────────

    /// the change applies to later swaps: the new recipient takes the bounty leg.
    function test_hook_setBountyRecipient_newRecipientGetsLegs() public onlyFork {
        (, PoolKey memory key) = _launchCredits();
        address payable newArtist = payable(makeAddr("rc.newArtist"));
        vm.expectEmit(true, false, false, true, address(v2.hook));
        emit IArtCoinsHookV2.BountyRecipientSet(key.toId(), treasury, newArtist);
        vm.prank(admin);
        v2.hook.setBountyRecipient(key.toId(), newArtist);
        assertEq(v2.hook.skimConfig(key.toId()).bountyRecipient, newArtist, "repointed");

        uint256 t0 = treasury.balance;
        vm.recordLogs();
        _buy(key, 0.5 ether);
        Legs memory l = _legs(vm.getRecordedLogs());
        assertGt(l.bounty, 0, "bounty leg paid");
        assertEq(newArtist.balance, l.bounty, "new recipient takes the bounty leg");
        assertEq(treasury.balance, t0, "old recipient takes nothing");
    }

    function test_hook_setBountyRecipient_nonAdminReverts() public onlyFork {
        (, PoolKey memory key) = _launchCredits();
        vm.prank(stranger);
        vm.expectRevert(IArtCoinsHookV2.NotCoinAdmin.selector);
        v2.hook.setBountyRecipient(key.toId(), payable(makeAddr("rc.x")));
    }

    /// fail closed: when a reject-set lookup reverts, the setter refuses.
    function test_hook_setBountyRecipient_failsClosedOnBadRead() public onlyFork {
        (, PoolKey memory key) = _launchCredits();
        PoolId pid = key.toId();
        address ok = makeAddr("rc.okHook");

        bytes[2] memory reads = [
            abi.encodeWithSignature("tokenDeployer()"), abi.encodeWithSignature("positionManager()")
        ];
        address[2] memory on = [address(v2.factory), address(v2.locker)];
        for (uint256 i; i < 2; ++i) {
            vm.mockCallRevert(on[i], reads[i], "");
            vm.prank(admin);
            vm.expectRevert(IArtCoinsHookV2.RecipientCheckFailed.selector);
            v2.hook.setBountyRecipient(pid, payable(ok));
            vm.clearMockedCalls();
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
                abi.encodeWithSelector(IArtCoinsHookV2.RecipientCannotReceive.selector, bad[i])
            );
            v2.hook.setBountyRecipient(pid, payable(bad[i]));
        }
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHookV2.BountyRecipientZero.selector);
        v2.hook.setBountyRecipient(pid, payable(address(0)));
    }

    function test_hook_setBountyRecipient_lockFreezes() public onlyFork {
        (address coin, PoolKey memory key) = _launchCredits();
        vm.prank(admin);
        _token(coin).lock();
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHookV2.CoinLocked.selector);
        v2.hook.setBountyRecipient(key.toId(), payable(makeAddr("rc.x")));
    }

    function test_hook_setBountyRecipient_renounceFreezes() public onlyFork {
        (address coin, PoolKey memory key) = _launchCredits();
        vm.prank(admin);
        _token(coin).renounceAdmin();
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHookV2.NotCoinAdmin.selector);
        v2.hook.setBountyRecipient(key.toId(), payable(makeAddr("rc.x")));
    }

    // ── D76(2): protocol skim floor pays ──────────────────────────────────

    function test_poolLpFeeZero_skimProtocolStillPays() public onlyFork {
        (, PoolKey memory key) = _launchCredits();
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
