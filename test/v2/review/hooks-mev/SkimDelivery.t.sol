// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    HMArt,
    HMEmptyFallback,
    HMEthSink,
    HMReferralPayout,
    HMRejecter,
    HooksMevBase
} from "./HooksMevBase.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// H1 / H2 / H3: recipient-side behaviour that reverts every swap on a skim pool.
contract SkimDeliveryTest is HooksMevBase {
    HMArt internal art;
    HMReferralPayout internal payout;

    function setUp() public override {
        super.setUp();
        art = _newArt();
        payout = new HMReferralPayout();
    }

    function _pool(address bounty, address referralPayout) internal returns (PoolKey memory key) {
        key = _skimPool(
            address(art),
            _skimFeeData(5000, 5000, 1000, bounty, referralPayout),
            address(0x10C),
            address(0)
        );
        _addLiquidity(key, -6000, 6000, 1000 ether);
    }

    // ─── H1: IPreSwapStream probe, return decode is outside try/catch ──────

    /// an EOA bounty recipient is fine until its balance reaches 0.01 eth.
    /// the pool's own bounty pushes get it there, after which EVERY swap
    /// (buys and sells) reverts: the hook calls streamForward() on the EOA,
    /// gets success + 0 bytes, and the uint256 return decode reverts in the
    /// hook, outside the catch.
    function test_bug_H1_eoaBountyRecipientSelfBricksPool() public {
        address eoa = makeAddr("bountyEOA");
        PoolKey memory key = _pool(eoa, address(payout));

        _swap(key, true, -0.5 ether, 0, "", 0.5 ether); // bounty 0.0125 eth pushed
        assertGe(eoa.balance, 0.01 ether, "pool pushed the recipient over the probe floor");

        vm.expectRevert();
        _swap(key, true, -0.1 ether, 0, "", 0.1 ether); // buy bricked
        vm.expectRevert();
        _swap(key, false, -1 ether, 0, "", 0); // sell bricked

        // drains below the floor -> works again -> the next push re-bricks it
        vm.deal(eoa, 0);
        _swap(key, true, -0.5 ether, 0, "", 0.5 ether);
        vm.expectRevert();
        _swap(key, true, -0.1 ether, 0, "", 0.1 ether);
    }

    /// a contract with an empty payable fallback (Safe without a fallback
    /// handler has the same shape) and no withdraw path bricks the pool
    /// permanently: bountyRecipient is frozen at init, there is no setter.
    function test_bug_H1_emptyFallbackRecipientBricksForever() public {
        HMEmptyFallback r = new HMEmptyFallback();
        PoolKey memory key = _pool(address(r), address(payout));
        _swap(key, true, -0.5 ether, 0, "", 0.5 ether);
        assertGe(address(r).balance, 0.01 ether);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert();
        _swap(key, true, -0.1 ether, 0, "", 0.1 ether);
    }

    /// control: a recipient without the selector and without a fallback
    /// reverts inside the call, which the catch DOES absorb.
    function test_control_H1_noSelectorRecipientIsCaught() public {
        HMEthSink r = new HMEthSink();
        PoolKey memory key = _pool(address(r), address(payout));
        vm.deal(address(r), 1 ether);
        _swap(key, true, -0.5 ether, 0, "", 0.5 ether);
        _swap(key, false, -0.2 ether, 0, "", 0);
    }

    // ─── H2: bid leg push reverts the swap ─────────────────────────────────

    function test_bug_H2_rejectingBountyRecipientBricksAllSwaps() public {
        HMRejecter r = new HMRejecter();
        PoolKey memory key = _pool(address(r), address(payout));
        vm.expectRevert();
        _swap(key, true, -0.1 ether, 0, "", 0.1 ether);
        vm.expectRevert();
        _swap(key, false, -0.1 ether, 0, "", 0);
    }

    // ─── H3: referral payout with no code ──────────────────────────────────

    /// referralPayout is only checked != 0 at init. if it has no code, any
    /// swap that names a referrer reverts: notify() has no return values, so
    /// solidity emits an extcodesize check before the call, and that revert
    /// is raised in the hook, outside the try. the "fold into protocol escrow"
    /// fallback never runs.
    function test_bug_H3_codelessReferralPayoutRevertsReferredSwaps() public {
        address eoaPayout = makeAddr("payoutEOA");
        PoolKey memory key = _pool(address(new HMEthSink()), eoaPayout);
        _swap(key, true, -0.1 ether, 0, "", 0.1 ether); // no referrer: fine
        bytes memory hd = _attributionData(makeAddr("ref"), 1000);
        vm.expectRevert();
        _swap(key, true, -0.1 ether, 0, hd, 0.1 ether);
    }
}
