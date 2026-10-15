// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {P1Coin, P1Rejector, P1Sink, P1Stray} from "./p1/P1Base.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsFeeEscrowV2} from "../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {IArtCoinsFeeEscrowV2} from "../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";
import {IProtocolFeeControllerV2} from "../../src/v2/interfaces/IProtocolFeeControllerV2.sol";
import {ProtocolFeeControllerV2} from "../../src/v2/protocol-fee/ProtocolFeeControllerV2.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Router stand in: accepts eth and carries a matching constants hash.
contract P1MockRouter is IConstantsBound {
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    function coin() external pure returns (address) {
        return address(0xC01);
    }

    function poolManager() external pure returns (address) {
        return address(0xB01);
    }

    receive() external payable {}
}

/// @notice A contract built against a different `Constants` set.
contract P1WrongHashRouter is IConstantsBound {
    function constantsHash() external pure returns (bytes32) {
        return keccak256("wrong");
    }

    receive() external payable {}
}

/// @notice A valid hash router with a zero `coin()` or `poolManager()`.
contract P1UnboundRouter is IConstantsBound {
    bool internal immutable ZERO_COIN;

    constructor(bool zeroCoin) {
        ZERO_COIN = zeroCoin;
    }

    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    function coin() external view returns (address) {
        return ZERO_COIN ? address(0) : address(0xC01);
    }

    function poolManager() external view returns (address) {
        return ZERO_COIN ? address(0xB01) : address(0);
    }

    receive() external payable {}
}

/// @notice A valid hash router that reverts on eth receipt (push fails).
contract P1RejectingRouter is IConstantsBound {
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    function coin() external pure returns (address) {
        return address(0xC01);
    }

    function poolManager() external pure returns (address) {
        return address(0xB01);
    }

    receive() external payable {
        revert("no eth");
    }
}

/// @title  ProtocolFeeControllerV2Test
/// @notice Eth split, escrow claim, delivery fallback, owner bounds. No pool
///         needed, so plain unit tests.
/// Run: forge test --match-path test/v2/ProtocolFeeControllerV2.t.sol -vv
contract ProtocolFeeControllerV2Test is Test {
    ArtCoinsFeeEscrowV2 internal escrow;
    P1Coin internal coin;
    P1MockRouter internal router;
    P1Sink internal treasury;
    ProtocolFeeControllerV2 internal pfc;
    address internal attacker = makeAddr("attacker");

    uint16 internal constant SPLIT = 6000;

    function setUp() public {
        escrow = new ArtCoinsFeeEscrowV2(address(this));
        coin = new P1Coin();
        router = new P1MockRouter();
        treasury = new P1Sink();
        pfc = _deploy(address(treasury), address(router), SPLIT);
        escrow.addDepositor(address(pfc), false);
        // the test itself credits the controller in the escrow (the hook's role)
        escrow.addDepositor(address(this), false);
    }

    function _deploy(address t, address r, uint16 bps) internal returns (ProtocolFeeControllerV2) {
        return new ProtocolFeeControllerV2(address(this), address(escrow), t, r, bps);
    }

    // ── split math ────────────────────────────────────────────────────────

    function test_pfcV2_split_math() public {
        uint256 total = 1 ether + 7;
        vm.deal(address(pfc), total);
        vm.expectEmit(false, false, false, true, address(pfc));
        uint256 t = total * SPLIT / Constants.BPS;
        emit IProtocolFeeControllerV2.FeesProcessed(total, t, total - t);
        pfc.processFees();
        assertEq(address(treasury).balance, t, "treasury share rounds down");
        assertEq(address(router).balance, total - t, "burn absorbs dust");
        assertEq(address(pfc).balance, 0);
    }

    function testFuzz_pfcV2_split_sumsToTotal(uint96 total, uint16 bps) public {
        bps = uint16(
            bound(bps, Constants.PFC_MIN_TREASURY_BPS, Constants.BPS - Constants.PFC_MIN_BURN_BPS)
        );
        vm.assume(total > 0);
        pfc.setSplit(bps);
        vm.deal(address(pfc), total);
        pfc.processFees();
        assertEq(address(treasury).balance + address(router).balance, total);
        assertGe(
            address(treasury).balance,
            uint256(total) * Constants.PFC_MIN_TREASURY_BPS / Constants.BPS
        );
        assertEq(pfc.burnBps(), Constants.BPS - bps);
    }

    // ── receive and escrow claim ──────────────────────────────────────────

    /// @notice The hook pushes with the 2,300 gas stipend; `receive` must fit it.
    function test_pfcV2_receive_fitsStipend_holds() public {
        (bool ok,) = address(pfc).call{value: 1 ether, gas: 2300}("");
        assertTrue(ok, "stipend push lands");
        assertEq(address(pfc).balance, 1 ether, "held until processFees");
        assertEq(pfc.pending(), 1 ether);
    }

    /// @notice A failed hook push lands in the escrow; `processFees` claims it first.
    function test_pfcV2_processFees_claimsEscrowCredit() public {
        escrow.storeFeesNative{value: 0.4 ether}(address(pfc));
        vm.deal(address(pfc), 0.6 ether);
        assertEq(pfc.pending(), 1 ether, "balance plus credit");

        pfc.processFees();
        assertEq(escrow.balances(address(pfc), address(0)), 0, "credit claimed");
        assertEq(address(treasury).balance, 0.6 ether, "split over the claimed total");
        assertEq(address(router).balance, 0.4 ether);
        assertEq(pfc.pending(), 0);
    }

    function test_pfcV2_processFees_creditOnly() public {
        escrow.storeFeesNative{value: 1 ether}(address(pfc));
        pfc.processFees();
        assertEq(address(treasury).balance, 0.6 ether);
        assertEq(address(router).balance, 0.4 ether);
    }

    function test_pfcV2_nothingToProcess_reverts() public {
        vm.expectRevert(IProtocolFeeControllerV2.NothingToProcess.selector);
        pfc.processFees();
    }

    // ── delivery fallback ─────────────────────────────────────────────────

    function test_pfcV2_revertingTreasury_fallsBackToEscrow() public {
        address rej = address(new P1Rejector());
        ProtocolFeeControllerV2 p = _deploy(rej, address(router), SPLIT);
        escrow.addDepositor(address(p), false);
        vm.deal(address(p), 1 ether);
        p.processFees();
        assertEq(escrow.balances(rej, address(0)), 0.6 ether, "treasury credited");
        assertEq(address(router).balance, 0.4 ether, "burn share pushed");
        assertEq(address(p).balance, 0);
    }

    function test_pfcV2_revertingRouter_fallsBackToEscrow() public {
        address rej = address(new P1RejectingRouter());
        pfc.setBurnRouter(rej);
        vm.deal(address(pfc), 1 ether);
        pfc.processFees();
        assertEq(escrow.balances(rej, address(0)), 0.4 ether);
        assertEq(address(treasury).balance, 0.6 ether);
    }

    /// @notice Until the controller is an escrow depositor a failed push reverts
    ///         and the eth stays for a retry.
    function test_pfcV2_notDepositor_failedPushReverts_fundsStay() public {
        ProtocolFeeControllerV2 p = _deploy(address(new P1Rejector()), address(router), SPLIT);
        vm.deal(address(p), 1 ether);
        vm.expectRevert(IArtCoinsFeeEscrowV2.NotDepositor.selector);
        p.processFees();
        assertEq(address(p).balance, 1 ether, "held for retry");
    }

    // ── bounds and owner ──────────────────────────────────────────────────

    function test_pfcV2_split_bounds() public {
        uint16 minT = Constants.PFC_MIN_TREASURY_BPS;
        uint16 minB = Constants.PFC_MIN_BURN_BPS;
        vm.expectRevert(
            abi.encodeWithSelector(
                IProtocolFeeControllerV2.TreasuryShareTooLow.selector, minT - 1, minT
            )
        );
        pfc.setSplit(minT - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IProtocolFeeControllerV2.BurnShareTooLow.selector, minB - 1, minB
            )
        );
        pfc.setSplit(uint16(Constants.BPS - minB + 1));
        vm.expectRevert(
            abi.encodeWithSelector(IProtocolFeeControllerV2.BurnShareTooLow.selector, 0, minB)
        );
        pfc.setSplit(10_001);

        pfc.setSplit(minT);
        assertEq(pfc.treasuryBps(), minT);
        assertEq(pfc.burnBps(), Constants.BPS - minT);
        pfc.setSplit(uint16(Constants.BPS - minB));
        assertEq(pfc.burnBps(), minB);

        vm.expectRevert(
            abi.encodeWithSelector(IProtocolFeeControllerV2.TreasuryShareTooLow.selector, 100, minT)
        );
        _deploy(address(treasury), address(router), 100);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        pfc.setSplit(5000);
    }

    function test_pfcV2_rotation_noOldRouterCall() public {
        pfc.setBurnRouter(address(new P1MockRouter()));
        pfc.setBurnRouter(address(router)); // rotate back; the old router is never called
        assertEq(pfc.burnRouter(), address(router));
        vm.expectRevert(IProtocolFeeControllerV2.ZeroAddress.selector);
        pfc.setBurnRouter(address(0));
        vm.expectRevert(IProtocolFeeControllerV2.ZeroAddress.selector);
        pfc.setTreasury(address(0));
        pfc.setTreasury(attacker);
        assertEq(pfc.treasury(), attacker);

        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        pfc.setTreasury(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        pfc.setBurnRouter(attacker);
        vm.stopPrank();
    }

    /// @notice `setBurnRouter` rejects a router built against other Constants or
    ///         one with no code.
    function test_pfcV2_setBurnRouter_checksConstants() public {
        address wrong = address(new P1WrongHashRouter());
        vm.expectRevert(abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, wrong));
        pfc.setBurnRouter(wrong);

        address eoa = makeAddr("eoaRouter");
        vm.expectRevert(abi.encodeWithSelector(IConstantsBound.ConstantsMismatch.selector, eoa));
        pfc.setBurnRouter(eoa);
    }

    function test_pfcV2_rescue() public {
        vm.deal(address(pfc), 1 ether);
        coin.mint(address(pfc), 5e18);
        P1Stray stray = new P1Stray();
        stray.transfer(address(pfc), 3e18);
        address to = makeAddr("to");
        pfc.rescue(address(coin), to, 5e18);
        pfc.rescue(address(stray), to, 3e18);
        assertEq(coin.balanceOf(to), 5e18);
        assertEq(stray.balanceOf(to), 3e18);

        vm.expectRevert(IProtocolFeeControllerV2.ZeroAddress.selector);
        pfc.rescue(address(0), address(0), 0);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        pfc.rescue(address(0), attacker, 0);
    }

    /// @notice Eth is never rescued: pending eth stays split by `processFees`.
    function test_pfcV2_rescue_nativeRefused() public {
        vm.deal(address(pfc), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IProtocolFeeControllerV2.CannotRescue.selector, address(0))
        );
        pfc.rescue(address(0), makeAddr("to"), 1 ether);
        assertEq(address(pfc).balance, 1 ether);
        assertEq(pfc.pending(), 1 ether);
        pfc.processFees();
        assertEq(address(treasury).balance, 0.6 ether);
        assertEq(address(router).balance, 0.4 ether);
    }

    function test_pfcV2_recipients_rejectSelfAndEqual() public {
        bytes4 sel = IProtocolFeeControllerV2.InvalidRecipient.selector;
        address self = address(pfc);

        vm.expectRevert(abi.encodeWithSelector(sel, self));
        pfc.setTreasury(self);
        vm.expectRevert(abi.encodeWithSelector(sel, address(router)));
        pfc.setTreasury(address(router));
        vm.expectRevert(abi.encodeWithSelector(sel, self));
        pfc.setBurnRouter(self);
        vm.expectRevert(abi.encodeWithSelector(sel, address(treasury)));
        pfc.setBurnRouter(address(treasury));

        // constructor: treasury equal to router
        vm.expectRevert(abi.encodeWithSelector(sel, address(router)));
        _deploy(address(router), address(router), SPLIT);
    }

    function test_pfcV2_setBurnRouter_requiresIdentity() public {
        bytes4 sel = IProtocolFeeControllerV2.InvalidRecipient.selector;
        address noCoin = address(new P1UnboundRouter(true));
        vm.expectRevert(abi.encodeWithSelector(sel, noCoin));
        pfc.setBurnRouter(noCoin);
        address noPm = address(new P1UnboundRouter(false));
        vm.expectRevert(abi.encodeWithSelector(sel, noPm));
        pfc.setBurnRouter(noPm);
        vm.expectRevert(abi.encodeWithSelector(sel, noCoin));
        _deploy(address(treasury), noCoin, SPLIT);
    }

    function test_pfcV2_ownable2Step() public {
        pfc.transferOwnership(attacker);
        assertEq(pfc.owner(), address(this), "pending only");
        vm.prank(attacker);
        pfc.acceptOwnership();
        assertEq(pfc.owner(), attacker);
        assertEq(pfc.constantsHash(), Constants.hash());
        assertEq(pfc.STACK_VERSION(), Constants.STACK_VERSION);
        assertEq(pfc.PUSH_GAS(), Constants.PUSH_GAS_MAX);
    }
}
