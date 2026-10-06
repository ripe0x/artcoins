// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ArtCoinsFeeEscrow} from "../../../../src/ArtCoinsFeeEscrow.sol";
import {FeeAutoSwapper} from "../../../../src/FeeAutoSwapper.sol";
import {IFeeAutoSwapper} from "../../../../src/interfaces/IFeeAutoSwapper.sol";

import {ReviewToken, ReviewWETH} from "./LockerFeesStubs.sol";

/// no pool needed: flushPaired never touches the PoolManager, so the manager
/// address is a placeholder. the escrow is the real ArtCoinsFeeEscrow; this
/// test contract is the allowlisted depositor (stands in for the LP locker).
contract FeeAutoSwapperReviewTest is Test {
    ArtCoinsFeeEscrow internal escrow;
    ReviewToken internal coin;
    ReviewWETH internal weth;
    address internal owner = makeAddr("owner");
    address internal endRecipient = makeAddr("endRecipient");
    address internal griefer = makeAddr("griefer");

    function setUp() public {
        escrow = new ArtCoinsFeeEscrow(owner);
        vm.prank(owner);
        escrow.addDepositor(address(this));
        coin = new ReviewToken("COIN");
        weth = new ReviewWETH();
    }

    function _swapper(address paired) internal returns (FeeAutoSwapper s) {
        s = new FeeAutoSwapper(
            FeeAutoSwapper.Config({
                poolManager: address(0xdead),
                feeLocker: address(escrow),
                pairedToken: paired,
                poolFee: 0x800000,
                poolTickSpacing: 200,
                hook: address(0),
                endRecipient: endRecipient,
                depositToLocker: false,
                maxSlippageBps: 300,
                minBlocksBetweenConverts: 1,
                maxStepIn: 1e30
            })
        );
        s.setup(address(coin));
    }

    /// LF-02a: native pool (the 111 shape). a third party calls
    /// escrow.claim(swapper, ETH); the escrow pushes the eth into the swapper,
    /// whose flushPaired only reads the escrow ledger, so the eth is stranded
    /// forever (no sweep, no owner).
    function test_bug_LF02_third_party_claim_strands_native_fees_in_swapper() public {
        FeeAutoSwapper s = _swapper(address(0));
        vm.deal(address(this), 3 ether);
        escrow.storeFeesNative{value: 3 ether}(address(s));
        assertEq(s.accruedPaired(), 3 ether);

        vm.prank(griefer);
        escrow.claim(address(s), address(0)); // permissionless push

        assertEq(address(s).balance, 3 ether, "eth now sits in the swapper");
        assertEq(s.accruedPaired(), 0, "ledger says nothing to flush");
        vm.expectRevert(IFeeAutoSwapper.NothingToFlush.selector);
        s.flushPaired();
        // convert cannot reach it either: it pays out only the swap's own `received`
        vm.expectRevert(IFeeAutoSwapper.NothingToConvert.selector);
        s.convert(0);
        assertEq(endRecipient.balance, 0, "end recipient never paid");

        // later honest fees still flow, but the stranded 3 eth never does
        vm.deal(address(this), 1 ether);
        escrow.storeFeesNative{value: 1 ether}(address(s));
        s.flushPaired();
        assertEq(address(s).balance, 3 ether, "stranded balance unchanged");
    }

    /// LF-02b: same for the weth-paired shape.
    function test_bug_LF02_third_party_claim_strands_weth_fees_in_swapper() public {
        FeeAutoSwapper s = _swapper(address(weth));
        vm.deal(address(this), 2 ether);
        weth.deposit{value: 2 ether}();
        weth.approve(address(escrow), 2 ether);
        escrow.storeFees(address(s), address(weth), 2 ether);

        vm.prank(griefer);
        escrow.claim(address(s), address(weth));

        assertEq(weth.balanceOf(address(s)), 2 ether);
        vm.expectRevert(IFeeAutoSwapper.NothingToFlush.selector);
        s.flushPaired();
        assertEq(weth.balanceOf(endRecipient), 0);
    }

    /// LF-02c (holds): the artcoin side is NOT strandable this way, convert
    /// reads artCoin.balanceOf(this), so a third-party push is harmless.
    function test_holds_LF02_artcoin_side_push_is_not_stranded() public {
        FeeAutoSwapper s = _swapper(address(0));
        coin.mint(address(this), 5e18);
        coin.approve(address(escrow), 5e18);
        escrow.storeFees(address(s), address(coin), 5e18);
        vm.prank(griefer);
        escrow.claim(address(s), address(coin));
        assertEq(s.accruedArtCoin(), 5e18, "still counted as convertible");
    }

    /// LF-08: native + depositToLocker mode cannot deposit a zero net, and any
    /// payout failure (non-payable endRecipient in push mode, or the swapper
    /// not allowlisted at the escrow in deposit mode) reverts the whole
    /// flush, with no owner path to fix it.
    function test_bug_LF08_unpayable_end_recipient_bricks_flush_forever() public {
        RejectEth rej = new RejectEth();
        FeeAutoSwapper s = new FeeAutoSwapper(
            FeeAutoSwapper.Config({
                poolManager: address(0xdead),
                feeLocker: address(escrow),
                pairedToken: address(0),
                poolFee: 0x800000,
                poolTickSpacing: 200,
                hook: address(0),
                endRecipient: address(rej),
                depositToLocker: false,
                maxSlippageBps: 300,
                minBlocksBetweenConverts: 1,
                maxStepIn: 1e30
            })
        );
        s.setup(address(coin));
        vm.deal(address(this), 1 ether);
        escrow.storeFeesNative{value: 1 ether}(address(s));
        vm.expectRevert(IFeeAutoSwapper.NativeSendFailed.selector);
        s.flushPaired();
        assertEq(s.accruedPaired(), 1 ether, "stuck in escrow under the swapper");
    }
}

contract RejectEth {
    receive() external payable {
        revert("no eth");
    }
}
