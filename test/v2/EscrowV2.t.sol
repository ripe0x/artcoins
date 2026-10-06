// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsFeeEscrowV2} from "../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {IArtCoinsFeeEscrowV2} from "../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {MockToken, PayableRecipient, RevertingRecipient} from "./FeeDelivery.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev A contract fee owner that cannot move erc20s (the FT-11 / LF-02 shape).
contract StuckOwner {
    function optIn(IArtCoinsFeeEscrowV2 e) external {
        e.setSelfClaimOnly(true);
    }

    function claimTo(IArtCoinsFeeEscrowV2 e, address token, address payable to) external {
        e.claimTo(address(this), token, to);
    }
}

contract EscrowV2Test is Test {
    ArtCoinsFeeEscrowV2 escrow;
    MockToken token;
    address owner = makeAddr("owner");
    address core = makeAddr("core");
    address plain = makeAddr("plain");
    address alice = makeAddr("alice");
    address griefer = makeAddr("griefer");

    function setUp() public {
        escrow = new ArtCoinsFeeEscrowV2(owner);
        token = new MockToken();
        vm.startPrank(owner);
        escrow.addDepositor(core, true);
        escrow.addDepositor(plain, false);
        vm.stopPrank();
        vm.deal(core, 100 ether);
        token.mint(core, 1_000e18);
        vm.prank(core);
        token.approve(address(escrow), type(uint256).max);
    }

    function _storeNative(address feeOwner, uint256 amount) internal {
        vm.prank(core);
        escrow.storeFeesNative{value: amount}(feeOwner);
    }

    function _storeErc20(address feeOwner, uint256 amount) internal {
        vm.prank(core);
        escrow.storeFees(feeOwner, address(token), amount);
    }

    function test_escrowV2_constantsHash() public view {
        assertEq(escrow.constantsHash(), Constants.hash());
    }

    // ── deposits ──────────────────────────────────────────────────────────

    function test_escrowV2_store_creditsAndOwed() public {
        vm.expectEmit(true, true, true, true);
        emit IArtCoinsFeeEscrowV2.FeesStored(core, alice, address(0), 1 ether, 1 ether);
        _storeNative(alice, 1 ether);
        _storeErc20(alice, 5e18);
        _storeErc20(alice, 1e18);
        assertEq(escrow.balances(alice, address(0)), 1 ether);
        assertEq(escrow.balances(alice, address(token)), 6e18);
        assertEq(escrow.totalOwed(address(0)), 1 ether);
        assertEq(escrow.totalOwed(address(token)), 6e18);
    }

    function test_escrowV2_store_notDepositor_reverts() public {
        vm.deal(griefer, 1 ether);
        vm.prank(griefer);
        vm.expectRevert(IArtCoinsFeeEscrowV2.NotDepositor.selector);
        escrow.storeFeesNative{value: 1 ether}(alice);
        vm.prank(griefer);
        vm.expectRevert(IArtCoinsFeeEscrowV2.NotDepositor.selector);
        escrow.storeFees(alice, address(token), 1);
    }

    function test_escrowV2_store_zeroOwnerOrValue_reverts() public {
        vm.prank(core);
        vm.expectRevert(IArtCoinsFeeEscrowV2.ZeroRecipient.selector);
        escrow.storeFeesNative{value: 1}(address(0));
        vm.prank(core);
        vm.expectRevert(IArtCoinsFeeEscrowV2.ZeroNativeDeposit.selector);
        escrow.storeFeesNative(alice);
        vm.prank(core);
        vm.expectRevert(IArtCoinsFeeEscrowV2.ZeroAddress.selector);
        escrow.storeFees(alice, address(0), 1);
    }

    function test_escrowV2_storeErc20_zeroAmount_noop() public {
        _storeErc20(alice, 0);
        assertEq(escrow.totalOwed(address(token)), 0);
    }

    // ── claims ────────────────────────────────────────────────────────────

    function test_escrowV2_claim_permissionlessPush() public {
        _storeNative(alice, 1 ether);
        _storeErc20(alice, 5e18);
        vm.startPrank(griefer);
        escrow.claim(alice, address(0));
        escrow.claim(alice, address(token));
        vm.stopPrank();
        assertEq(alice.balance, 1 ether);
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(escrow.totalOwed(address(0)), 0);
        assertEq(escrow.totalOwed(address(token)), 0);
        vm.expectRevert(IArtCoinsFeeEscrowV2.NoFeesToClaim.selector);
        escrow.claim(alice, address(0));
    }

    /// @dev FT-11 / LF-02: a contract fee owner opts in, a third party claim reverts,
    ///      and the owner's own claimTo still works.
    function test_escrowV2_selfClaimOnly_blocksThirdParty() public {
        StuckOwner stuck = new StuckOwner();
        vm.expectEmit(true, true, true, true);
        emit IArtCoinsFeeEscrowV2.SelfClaimOnlySet(address(stuck), true);
        stuck.optIn(escrow);
        assertTrue(escrow.selfClaimOnly(address(stuck)));
        _storeErc20(address(stuck), 5e18);

        vm.prank(griefer);
        vm.expectRevert(IArtCoinsFeeEscrowV2.Unauthorized.selector);
        escrow.claim(address(stuck), address(token));

        // balance untouched, owner redirects it
        assertEq(escrow.balances(address(stuck), address(token)), 5e18);
        stuck.claimTo(escrow, address(token), payable(alice));
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(escrow.totalOwed(address(token)), 0);
    }

    function test_escrowV2_selfClaimOnly_ownerCanClaimItself() public {
        vm.prank(alice);
        escrow.setSelfClaimOnly(true);
        _storeNative(alice, 1 ether);
        vm.prank(alice);
        escrow.claim(alice, address(0));
        assertEq(alice.balance, 1 ether);
    }

    function test_escrowV2_claim_revertingNative_noLoss() public {
        RevertingRecipient r = new RevertingRecipient();
        _storeNative(address(r), 1 ether);
        vm.expectRevert(IArtCoinsFeeEscrowV2.NativeTransferFailed.selector);
        escrow.claim(address(r), address(0));
        assertEq(escrow.balances(address(r), address(0)), 1 ether);
    }

    function test_escrowV2_claimTo_onlyFeeOwner() public {
        _storeNative(alice, 1 ether);
        vm.prank(griefer);
        vm.expectRevert(IArtCoinsFeeEscrowV2.Unauthorized.selector);
        escrow.claimTo(alice, address(0), payable(griefer));
        vm.prank(alice);
        vm.expectRevert(IArtCoinsFeeEscrowV2.ZeroRecipient.selector);
        escrow.claimTo(alice, address(0), payable(address(0)));

        PayableRecipient r = new PayableRecipient();
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IArtCoinsFeeEscrowV2.FeesClaimed(alice, address(0), address(r), 1 ether);
        escrow.claimTo(alice, address(0), payable(address(r)));
        assertEq(address(r).balance, 1 ether);
    }

    // ── depositors ────────────────────────────────────────────────────────

    function test_escrowV2_coreDepositor_cannotBeRemoved() public {
        assertTrue(escrow.isCoreDepositor(core));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsFeeEscrowV2.CoreDepositor.selector, core));
        escrow.removeDepositor(core);
        // nor downgraded to non core (which would open a remove path)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsFeeEscrowV2.CoreDepositor.selector, core));
        escrow.addDepositor(core, false);
        assertTrue(escrow.isDepositor(core));
    }

    function test_escrowV2_plainDepositor_removable() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IArtCoinsFeeEscrowV2.DepositorRemoved(plain);
        escrow.removeDepositor(plain);
        assertFalse(escrow.isDepositor(plain));
        vm.prank(owner);
        vm.expectRevert(IArtCoinsFeeEscrowV2.NotDepositor.selector);
        escrow.removeDepositor(plain);
    }

    function test_escrowV2_depositorAdmin_onlyOwner() public {
        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, griefer));
        escrow.addDepositor(griefer, false);
        vm.prank(owner);
        vm.expectRevert(IArtCoinsFeeEscrowV2.ZeroAddress.selector);
        escrow.addDepositor(address(0), true);
    }

    function test_escrowV2_ownable2Step() public {
        address next = makeAddr("next");
        vm.prank(owner);
        escrow.transferOwnership(next);
        assertEq(escrow.owner(), owner);
        vm.prank(next);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), next);
    }

    // ── rescue ────────────────────────────────────────────────────────────

    function test_escrowV2_rescue_boundedByTotalOwed() public {
        _storeNative(alice, 1 ether);
        _storeErc20(alice, 5e18);
        // stray funds on top of owed balances
        vm.deal(address(escrow), address(escrow).balance + 0.5 ether);
        token.mint(address(escrow), 2e18);

        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsFeeEscrowV2.RescueExceedsExcess.selector, 0.5 ether + 1, 0.5 ether
            )
        );
        escrow.rescue(address(0), owner, 0.5 ether + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsFeeEscrowV2.RescueExceedsExcess.selector, 2e18 + 1, 2e18)
        );
        escrow.rescue(address(token), owner, 2e18 + 1);

        escrow.rescue(address(0), owner, 0.5 ether);
        escrow.rescue(address(token), owner, 2e18);
        vm.stopPrank();

        assertEq(owner.balance, 0.5 ether);
        assertEq(token.balanceOf(owner), 2e18);
        // owed funds intact and claimable
        escrow.claim(alice, address(0));
        escrow.claim(alice, address(token));
        assertEq(alice.balance, 1 ether);
        assertEq(token.balanceOf(alice), 5e18);
    }

    function test_escrowV2_rescue_nothingStray_reverts() public {
        _storeNative(alice, 1 ether);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsFeeEscrowV2.RescueExceedsExcess.selector, 1, 0)
        );
        escrow.rescue(address(0), owner, 1);
        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, griefer));
        escrow.rescue(address(0), griefer, 0);
    }

    function testFuzz_escrowV2_owedInvariant(uint96 a, uint96 b, uint96 stray) public {
        vm.deal(core, uint256(a) + b);
        if (a > 0) _storeNative(alice, a);
        if (b > 0) _storeNative(griefer, b);
        vm.deal(address(escrow), address(escrow).balance + stray);
        assertEq(escrow.totalOwed(address(0)), uint256(a) + b);
        vm.prank(owner);
        escrow.rescue(address(0), owner, stray);
        assertEq(address(escrow).balance, escrow.totalOwed(address(0)));
        if (a > 0) escrow.claim(alice, address(0));
        if (b > 0) escrow.claim(griefer, address(0));
        assertEq(address(escrow).balance, 0);
        assertEq(escrow.totalOwed(address(0)), 0);
    }
}
