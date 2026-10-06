// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {P1Coin, P1Rejector, P1Sink, P1Stray} from "./p1/P1Base.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsFeeEscrowV2} from "../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {IProtocolFeeControllerV2} from "../../src/v2/interfaces/IProtocolFeeControllerV2.sol";
import {ProtocolFeeControllerV2} from "../../src/v2/protocol-fee/ProtocolFeeControllerV2.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Router stand in that reports its coin and accepts eth.
contract P1MockRouter {
    address public coin;

    constructor(address coin_) {
        coin = coin_;
    }

    receive() external payable {}
}

/// @notice Router stand in without `coin()` (a legacy or broken router).
contract P1NoCoinRouter {
    receive() external payable {}
}

/// @title  ProtocolFeeControllerV2Test
/// @notice Review LF-10 and DESIGN section 2. No pool needed, so plain unit tests.
/// Run: /tmp/claude-0/forge.sh test --match-path test/v2/ProtocolFeeControllerV2.t.sol -vv
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
        router = new P1MockRouter(address(coin));
        treasury = new P1Sink();
        pfc = _deploy(address(treasury), address(router), SPLIT);
        escrow.addDepositor(address(pfc), false);
    }

    function _deploy(address t, address r, uint16 bps) internal returns (ProtocolFeeControllerV2) {
        return new ProtocolFeeControllerV2(address(this), address(escrow), t, r, bps);
    }

    // ── split math ────────────────────────────────────────────────────────

    function test_pfcV2_nativeSplit_math() public {
        uint256 total = 1 ether + 7;
        vm.deal(address(pfc), total);
        pfc.processFees(address(0));
        uint256 t = total * SPLIT / Constants.BPS;
        assertEq(address(treasury).balance, t, "treasury share rounds down");
        assertEq(address(router).balance, total - t, "burn absorbs dust");
        assertEq(address(pfc).balance, 0);
    }

    function testFuzz_pfcV2_nativeSplit_sumsToTotal(uint96 total, uint16 bps) public {
        bps = uint16(bound(bps, Constants.PFC_MIN_TREASURY_BPS, Constants.BPS - Constants.PFC_MIN_BURN_BPS));
        vm.assume(total > 0);
        pfc.setSplit(bps);
        vm.deal(address(pfc), total);
        pfc.processFees(address(0));
        assertEq(address(treasury).balance + address(router).balance, total);
        assertGe(address(treasury).balance, uint256(total) * Constants.PFC_MIN_TREASURY_BPS / Constants.BPS);
    }

    function test_pfcV2_receive_withGas_splitsImmediately() public {
        (bool ok,) = address(pfc).call{value: 1 ether, gas: 1_000_000}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, 0.6 ether);
        assertEq(address(router).balance, 0.4 ether);
    }

    /// @notice The hook and locker push with a small gas cap; the push must succeed.
    function test_pfcV2_receive_lowGas_holds_neverReverts() public {
        (bool ok,) = address(pfc).call{value: 1 ether, gas: Constants.PUSH_GAS_MIN}("");
        assertTrue(ok, "push with 10k gas succeeds");
        (ok,) = address(pfc).call{value: 1 ether, gas: Constants.PUSH_GAS_DEFAULT}("");
        assertTrue(ok, "push with 50k gas succeeds");
        assertEq(address(pfc).balance, 2 ether, "held");
        pfc.processFees(address(0));
        assertEq(address(treasury).balance, 1.2 ether);
    }

    function test_pfcV2_receive_neverReverts_evenIfDeliveryCannotComplete() public {
        // reverting treasury and NOT an escrow depositor: processFees would revert
        ProtocolFeeControllerV2 p = _deploy(address(new P1Rejector()), address(router), SPLIT);
        (bool ok,) = address(p).call{value: 1 ether, gas: 2_000_000}("");
        assertTrue(ok, "receive swallowed the failed split");
        assertEq(address(p).balance, 1 ether, "held for retry");
        vm.expectRevert(ArtCoinsFeeEscrowV2.NotDepositor.selector);
        p.processFees(address(0));
    }

    function test_pfcV2_revertingTreasury_fallsBackToEscrow() public {
        address rej = address(new P1Rejector());
        ProtocolFeeControllerV2 p = _deploy(rej, address(router), SPLIT);
        escrow.addDepositor(address(p), false);
        vm.deal(address(p), 1 ether);
        p.processFees(address(0));
        assertEq(escrow.balances(rej, address(0)), 0.6 ether, "treasury credited");
        assertEq(address(router).balance, 0.4 ether, "burn share pushed");
        assertEq(address(p).balance, 0);
    }

    function test_pfcV2_revertingRouter_fallsBackToEscrow() public {
        address rej = address(new P1Rejector());
        pfc.setBurnRouter(rej);
        vm.deal(address(pfc), 1 ether);
        pfc.processFees(address(0));
        assertEq(escrow.balances(rej, address(0)), 0.4 ether);
        assertEq(address(treasury).balance, 0.6 ether);
    }

    function test_pfcV2_nothingToProcess_reverts() public {
        vm.expectRevert(IProtocolFeeControllerV2.NothingToProcess.selector);
        pfc.processFees(address(0));
        vm.expectRevert(IProtocolFeeControllerV2.NothingToProcess.selector);
        pfc.processFees(address(coin));
    }

    // ── erc20 ─────────────────────────────────────────────────────────────

    function test_pfcV2_routerCoin_burnShareBurned() public {
        coin.mint(address(pfc), 1000e18);
        uint256 supply = coin.totalSupply();
        pfc.processFees(address(coin));
        assertEq(coin.balanceOf(address(treasury)), 600e18);
        assertEq(coin.totalSupply(), supply - 400e18, "burn share burned");
        assertEq(coin.balanceOf(address(pfc)), 0);
    }

    function test_pfcV2_otherErc20_allToTreasury() public {
        P1Stray other = new P1Stray();
        other.transfer(address(pfc), 1000e18);
        pfc.processFees(address(other));
        assertEq(other.balanceOf(address(treasury)), 1000e18, "not parked at the router");
        assertEq(other.balanceOf(address(router)), 0);
    }

    function test_pfcV2_routerWithoutCoin_erc20AllToTreasury() public {
        pfc.setBurnRouter(address(new P1NoCoinRouter()));
        coin.mint(address(pfc), 10e18);
        pfc.processFees(address(coin));
        assertEq(coin.balanceOf(address(treasury)), 10e18);
        pfc.setBurnRouter(makeAddr("eoaRouter"));
        coin.mint(address(pfc), 10e18);
        pfc.processFees(address(coin));
        assertEq(coin.balanceOf(address(treasury)), 20e18);
    }

    // ── bounds and owner ──────────────────────────────────────────────────

    function test_pfcV2_split_bounds() public {
        uint16 minT = Constants.PFC_MIN_TREASURY_BPS;
        uint16 minB = Constants.PFC_MIN_BURN_BPS;
        vm.expectRevert(
            abi.encodeWithSelector(IProtocolFeeControllerV2.TreasuryShareTooLow.selector, minT - 1, minT)
        );
        pfc.setSplit(minT - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IProtocolFeeControllerV2.BurnShareTooLow.selector, minB - 1, minB)
        );
        pfc.setSplit(uint16(Constants.BPS - minB + 1));
        vm.expectRevert(abi.encodeWithSelector(IProtocolFeeControllerV2.BurnShareTooLow.selector, 0, minB));
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        pfc.setSplit(5000);
    }

    function test_pfcV2_rotation_noOldRouterCall() public {
        pfc.setBurnRouter(address(new P1NoCoinRouter()));
        pfc.setBurnRouter(makeAddr("eoa"));
        pfc.setBurnRouter(address(router)); // rotate back from an eoa
        assertEq(pfc.burnRouter(), address(router));
        vm.expectRevert(IProtocolFeeControllerV2.ZeroAddress.selector);
        pfc.setBurnRouter(address(0));
        vm.expectRevert(IProtocolFeeControllerV2.ZeroAddress.selector);
        pfc.setTreasury(address(0));
        pfc.setTreasury(attacker);
        assertEq(pfc.treasury(), attacker);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        pfc.setTreasury(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        pfc.setBurnRouter(attacker);
        vm.stopPrank();
    }

    function test_pfcV2_rescue() public {
        vm.deal(address(pfc), 1 ether);
        coin.mint(address(pfc), 5e18);
        address to = makeAddr("to");
        pfc.rescue(address(0), to, 1 ether);
        pfc.rescue(address(coin), to, 5e18);
        assertEq(to.balance, 1 ether);
        assertEq(coin.balanceOf(to), 5e18);

        vm.expectRevert(IProtocolFeeControllerV2.ZeroAddress.selector);
        pfc.rescue(address(0), address(0), 0);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        pfc.rescue(address(0), attacker, 0);
    }

    function test_pfcV2_ownable2Step() public {
        pfc.transferOwnership(attacker);
        assertEq(pfc.owner(), address(this), "pending only");
        vm.prank(attacker);
        pfc.acceptOwnership();
        assertEq(pfc.owner(), attacker);
        assertEq(pfc.constantsHash(), Constants.hash());
    }
}
