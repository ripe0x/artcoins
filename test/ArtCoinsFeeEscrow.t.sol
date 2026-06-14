// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {IArtCoinsFeeEscrow} from "../src/interfaces/IArtCoinsFeeEscrow.sol";
import {IArtCoinsFeeLocker} from "../src/interfaces/IArtCoinsFeeLocker.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @dev Recipient that reverts on receive(). Used to confirm the native claim
///      surfaces a `NativeTransferFailed` revert when the feeOwner refuses ETH.
contract RejectingRecipient {
    receive() external payable {
        revert("nope");
    }
}

/// @dev Reentrant attacker that tries to claim again from inside receive().
contract ReentrantClaimer {
    IArtCoinsFeeEscrow public escrow;
    bool public reentered;

    constructor(IArtCoinsFeeEscrow _escrow) {
        escrow = _escrow;
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            try escrow.claim(address(this), address(0)) {} catch {}
        }
    }

    function claim() external {
        escrow.claim(address(this), address(0));
    }
}

contract ArtCoinsFeeEscrowTest is Test {
    ArtCoinsFeeEscrow public escrow;
    MockToken public token;

    address public owner = address(0xCAFE);
    address public depositor = address(0xDEEEEE);
    address public depositor2 = address(0xDDDDDD);
    // Non-precompile addresses. (0xA..0x12 are Cancun precompiles — they
    // reject ETH transfers.)
    address public feeOwnerA = makeAddr("feeOwnerA");
    address public feeOwnerB = makeAddr("feeOwnerB");
    address public nonAllowed = address(0xBADBAD);

    function setUp() public {
        vm.prank(owner);
        escrow = new ArtCoinsFeeEscrow(owner);

        vm.prank(owner);
        escrow.addDepositor(depositor);

        token = new MockToken();
        token.transfer(depositor, 100_000e18);
    }

    // ─── ownership / allowlist ──────────────────────────────────────────

    function test_constructor_setsOwner() public view {
        assertEq(escrow.owner(), owner);
    }

    function test_addDepositor_setsAllowed() public {
        assertTrue(escrow.allowedDepositors(depositor));
        assertFalse(escrow.allowedDepositors(nonAllowed));
    }

    function test_addDepositor_revertsIfNotOwner() public {
        vm.prank(nonAllowed);
        vm.expectRevert();
        escrow.addDepositor(nonAllowed);
    }

    // ─── ERC20 path (regression — must match ArtCoinsFeeLocker behavior) ───

    function test_storeFees_credits() public {
        vm.startPrank(depositor);
        token.approve(address(escrow), 100e18);
        escrow.storeFees(feeOwnerA, address(token), 100e18);
        vm.stopPrank();

        assertEq(escrow.availableFees(feeOwnerA, address(token)), 100e18);
        assertEq(token.balanceOf(address(escrow)), 100e18);
    }

    function test_storeFees_revertsIfNotAllowed() public {
        vm.startPrank(nonAllowed);
        vm.expectRevert(IArtCoinsFeeLocker.Unauthorized.selector);
        escrow.storeFees(feeOwnerA, address(token), 100e18);
        vm.stopPrank();
    }

    function test_claim_erc20_sendsTokens() public {
        vm.startPrank(depositor);
        token.approve(address(escrow), 100e18);
        escrow.storeFees(feeOwnerA, address(token), 100e18);
        vm.stopPrank();

        uint256 balBefore = token.balanceOf(feeOwnerA);
        escrow.claim(feeOwnerA, address(token));
        assertEq(token.balanceOf(feeOwnerA), balBefore + 100e18);
        assertEq(escrow.availableFees(feeOwnerA, address(token)), 0);
    }

    function test_claim_revertsWhenNoBalance() public {
        vm.expectRevert(IArtCoinsFeeLocker.NoFeesToClaim.selector);
        escrow.claim(feeOwnerA, address(token));
    }

    // ─── native-ETH path (the new surface) ─────────────────────────────

    function test_storeFeesNative_credits() public {
        vm.deal(depositor, 10 ether);
        vm.prank(depositor);
        escrow.storeFeesNative{value: 5 ether}(feeOwnerA);

        assertEq(escrow.availableFees(feeOwnerA, address(0)), 5 ether);
        assertEq(address(escrow).balance, 5 ether);
    }

    function test_storeFeesNative_revertsIfNotAllowed() public {
        vm.deal(nonAllowed, 1 ether);
        vm.prank(nonAllowed);
        vm.expectRevert(IArtCoinsFeeLocker.Unauthorized.selector);
        escrow.storeFeesNative{value: 1 ether}(feeOwnerA);
    }

    function test_storeFeesNative_revertsOnZeroValue() public {
        vm.prank(depositor);
        vm.expectRevert(IArtCoinsFeeEscrow.ZeroNativeDeposit.selector);
        escrow.storeFeesNative{value: 0}(feeOwnerA);
    }

    function test_storeFeesNative_accumulates() public {
        vm.deal(depositor, 10 ether);
        vm.startPrank(depositor);
        escrow.storeFeesNative{value: 3 ether}(feeOwnerA);
        escrow.storeFeesNative{value: 2 ether}(feeOwnerA);
        vm.stopPrank();

        assertEq(escrow.availableFees(feeOwnerA, address(0)), 5 ether);
    }

    function test_claim_native_sendsETH() public {
        vm.deal(depositor, 10 ether);
        vm.prank(depositor);
        escrow.storeFeesNative{value: 5 ether}(feeOwnerA);

        uint256 balBefore = feeOwnerA.balance;
        escrow.claim(feeOwnerA, address(0));
        assertEq(feeOwnerA.balance, balBefore + 5 ether);
        assertEq(escrow.availableFees(feeOwnerA, address(0)), 0);
        assertEq(address(escrow).balance, 0);
    }

    function test_claim_native_revertsWhenNoBalance() public {
        vm.expectRevert(IArtCoinsFeeLocker.NoFeesToClaim.selector);
        escrow.claim(feeOwnerA, address(0));
    }

    function test_claim_native_revertsWhenRecipientRejects() public {
        RejectingRecipient bad = new RejectingRecipient();

        vm.deal(depositor, 10 ether);
        vm.prank(depositor);
        escrow.storeFeesNative{value: 1 ether}(address(bad));

        vm.expectRevert(IArtCoinsFeeEscrow.NativeTransferFailed.selector);
        escrow.claim(address(bad), address(0));

        // Balance still credited (no debit happens on revert — nonReentrant
        // restores state).
        assertEq(escrow.availableFees(address(bad), address(0)), 1 ether);
    }

    // ─── reentrancy ─────────────────────────────────────────────────────

    function test_claim_native_blocksReentrancy() public {
        ReentrantClaimer attacker = new ReentrantClaimer(escrow);
        // Track delta rather than absolute balance — on a fork run, a freshly
        // CREATE'd address may collide with an existing mainnet account that
        // holds dust ETH. Delta-based asserts are fork-safe.
        uint256 attackerBalBefore = address(attacker).balance;

        vm.deal(depositor, 10 ether);
        vm.prank(depositor);
        escrow.storeFeesNative{value: 2 ether}(address(attacker));

        // The reentrant `claim` from inside `receive()` should fail under the
        // outer claim's nonReentrant guard. Either outer succeeds (attacker
        // gets exactly 2 ether, no more) or outer reverts (balance preserved
        // in escrow).
        try escrow.claim(address(attacker), address(0)) {
            assertEq(address(attacker).balance - attackerBalBefore, 2 ether);
            assertEq(escrow.availableFees(address(attacker), address(0)), 0);
        } catch {
            assertEq(escrow.availableFees(address(attacker), address(0)), 2 ether);
        }
    }

    // ─── isolation between recipients & currencies ──────────────────────

    function test_native_and_erc20_isolated() public {
        vm.deal(depositor, 10 ether);
        vm.startPrank(depositor);
        token.approve(address(escrow), 100e18);
        escrow.storeFees(feeOwnerA, address(token), 100e18);
        escrow.storeFeesNative{value: 2 ether}(feeOwnerA);
        vm.stopPrank();

        assertEq(escrow.availableFees(feeOwnerA, address(token)), 100e18);
        assertEq(escrow.availableFees(feeOwnerA, address(0)), 2 ether);

        escrow.claim(feeOwnerA, address(token));
        assertEq(escrow.availableFees(feeOwnerA, address(0)), 2 ether); // unchanged
    }

    function test_recipients_isolated() public {
        vm.deal(depositor, 10 ether);
        vm.startPrank(depositor);
        escrow.storeFeesNative{value: 3 ether}(feeOwnerA);
        escrow.storeFeesNative{value: 1 ether}(feeOwnerB);
        vm.stopPrank();

        assertEq(escrow.availableFees(feeOwnerA, address(0)), 3 ether);
        assertEq(escrow.availableFees(feeOwnerB, address(0)), 1 ether);

        escrow.claim(feeOwnerA, address(0));
        assertEq(escrow.availableFees(feeOwnerB, address(0)), 1 ether); // unchanged
    }

    // ─── ERC-165 ────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(escrow.supportsInterface(type(IArtCoinsFeeLocker).interfaceId));
        assertTrue(escrow.supportsInterface(type(IArtCoinsFeeEscrow).interfaceId));
        assertFalse(escrow.supportsInterface(0xdeadbeef));
    }

    // ─── L-02 audit fix: claimTo (feeOwner redirects balance) ──────────

    function test_claimTo_native_redirectsToRecipient() public {
        vm.deal(depositor, 10 ether);
        vm.prank(depositor);
        escrow.storeFeesNative{value: 3 ether}(feeOwnerA);

        address payable recipient = payable(makeAddr("claimToRecipient"));
        uint256 recipientBefore = recipient.balance;

        vm.prank(feeOwnerA);
        escrow.claimTo(feeOwnerA, address(0), recipient);

        assertEq(recipient.balance - recipientBefore, 3 ether, "recipient receives ETH");
        assertEq(escrow.availableFees(feeOwnerA, address(0)), 0, "balance zeroed");
    }

    function test_claimTo_erc20_redirectsToRecipient() public {
        vm.startPrank(depositor);
        token.approve(address(escrow), 100e18);
        escrow.storeFees(feeOwnerA, address(token), 100e18);
        vm.stopPrank();

        address recipient = makeAddr("erc20recipient");

        vm.prank(feeOwnerA);
        escrow.claimTo(feeOwnerA, address(token), payable(recipient));

        assertEq(token.balanceOf(recipient), 100e18, "recipient receives tokens");
        assertEq(escrow.availableFees(feeOwnerA, address(token)), 0);
    }

    function test_claimTo_revertsIfNotFeeOwner() public {
        vm.deal(depositor, 10 ether);
        vm.prank(depositor);
        escrow.storeFeesNative{value: 1 ether}(feeOwnerA);

        // Anyone OTHER than feeOwnerA can't redirect feeOwnerA's balance.
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(IArtCoinsFeeLocker.Unauthorized.selector);
        escrow.claimTo(feeOwnerA, address(0), payable(makeAddr("recipient")));
    }

    function test_claimTo_revertsOnZeroRecipient() public {
        vm.deal(depositor, 10 ether);
        vm.prank(depositor);
        escrow.storeFeesNative{value: 1 ether}(feeOwnerA);

        vm.prank(feeOwnerA);
        vm.expectRevert(IArtCoinsFeeEscrow.ZeroRecipient.selector);
        escrow.claimTo(feeOwnerA, address(0), payable(address(0)));
    }

    function test_claimTo_revertsWhenNoBalance() public {
        vm.prank(feeOwnerA);
        vm.expectRevert(IArtCoinsFeeLocker.NoFeesToClaim.selector);
        escrow.claimTo(feeOwnerA, address(0), payable(makeAddr("recipient")));
    }

    /// @dev The whole point of L-02: a non-payable feeOwner can still
    ///      recover its credited balance by redirecting (as itself, via
    ///      `vm.prank` simulating the contract's own call) to a payable
    ///      recipient. Solves the stuck-balance audit finding.
    function test_claimTo_unblocksNonPayableFeeOwner() public {
        RejectingRecipient feeOwner = new RejectingRecipient();

        vm.deal(depositor, 10 ether);
        vm.prank(depositor);
        escrow.storeFeesNative{value: 2 ether}(address(feeOwner));

        // Standard claim reverts because feeOwner rejects ETH on receive.
        vm.expectRevert(IArtCoinsFeeEscrow.NativeTransferFailed.selector);
        escrow.claim(address(feeOwner), address(0));
        // Balance preserved (nonReentrant + revert rolled back the debit).
        assertEq(escrow.availableFees(address(feeOwner), address(0)), 2 ether);

        // But the feeOwner itself can redirect to a payable recipient.
        // (Simulated via vm.prank — in production, the non-payable contract
        // would need a function that calls claimTo, or the credit would
        // need to be assigned to a contract that exposes one.)
        address payable rescueRecipient = payable(makeAddr("rescue"));
        vm.prank(address(feeOwner));
        escrow.claimTo(address(feeOwner), address(0), rescueRecipient);

        assertEq(rescueRecipient.balance, 2 ether, "rescued via claimTo");
        assertEq(escrow.availableFees(address(feeOwner), address(0)), 0);
    }

    // ─── direct ETH send rejection (no receive on the escrow) ──────────

    function test_directEthSendReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(escrow).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ─── invariant: balance == sum of credited ───────────────────────────

    function test_balance_matches_creditedSum() public {
        vm.deal(depositor, 100 ether);
        vm.startPrank(depositor);

        escrow.storeFeesNative{value: 5 ether}(feeOwnerA);
        escrow.storeFeesNative{value: 7 ether}(feeOwnerB);
        escrow.storeFeesNative{value: 3 ether}(feeOwnerA);

        vm.stopPrank();

        uint256 totalCredited = escrow.availableFees(feeOwnerA, address(0))
            + escrow.availableFees(feeOwnerB, address(0));

        assertEq(totalCredited, 15 ether);
        assertEq(address(escrow).balance, totalCredited);

        escrow.claim(feeOwnerA, address(0));
        assertEq(address(escrow).balance, escrow.availableFees(feeOwnerB, address(0)));
    }
}
