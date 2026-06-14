// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFeeController} from "../../src/protocol-fee/legacy/ProtocolFeeController.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock burn router that just exposes a `layerToken()` setter so the
///      controller's sanity check on `setBurnRouter` can be exercised.
contract MockBurnRouter {
    address public layerToken;

    constructor(address layer_) {
        layerToken = layer_;
    }
}

contract ProtocolFeeControllerTest is Test {
    ProtocolFeeController internal controller;
    MockToken internal token;
    MockToken internal layer;
    MockBurnRouter internal router;
    address internal admin = address(0xA1);
    address internal treasury = address(0xB1);
    address internal stranger = address(0xDEAD);

    function setUp() public {
        token = new MockToken();
        layer = new MockToken();
        router = new MockBurnRouter(address(layer));
        controller = new ProtocolFeeController(admin, treasury, address(router));
    }

    // ─── construction ───────────────────────────────────────────────────

    function test_initialState() public view {
        assertEq(controller.treasury(), treasury);
        assertEq(controller.burnRouter(), address(router));
        assertEq(controller.rewardsReceiver(), address(0));
        assertEq(controller.treasuryBps(), 6000);
        assertEq(controller.burnBps(), 4000);
        assertEq(controller.rewardsBps(), 0);
    }

    function test_constructorRejectsZeros() public {
        // Zero owner reverts at the OZ Ownable layer before our ZeroAddress check.
        vm.expectRevert();
        new ProtocolFeeController(address(0), treasury, address(router));
        // Zero treasury / burnRouter hit our explicit ZeroAddress check.
        vm.expectRevert(ProtocolFeeController.ZeroAddress.selector);
        new ProtocolFeeController(admin, address(0), address(router));
        vm.expectRevert(ProtocolFeeController.ZeroAddress.selector);
        new ProtocolFeeController(admin, treasury, address(0));
    }

    // ─── split bounds ───────────────────────────────────────────────────

    function test_setSplit_validShape() public {
        // Set rewards receiver first so non-zero rewards bps is allowed.
        vm.prank(admin);
        controller.setRewardsReceiver(address(0x1234));
        vm.prank(admin);
        controller.setSplit(5000, 3500, 1500);
        assertEq(controller.treasuryBps(), 5000);
        assertEq(controller.burnBps(), 3500);
        assertEq(controller.rewardsBps(), 1500);
    }

    function test_setSplit_revertsIfSumNot100() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolFeeController.InvalidSplit.selector, 5000, 3000, 1000)
        );
        controller.setSplit(5000, 3000, 1000);
    }

    function test_setSplit_revertsIfTreasuryTooLow() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolFeeController.TreasuryShareTooLow.selector, 3000, 4000)
        );
        controller.setSplit(3000, 7000, 0);
    }

    function test_setSplit_revertsIfBurnTooLow() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolFeeController.BurnShareTooLow.selector, 1000, 2000)
        );
        controller.setSplit(9000, 1000, 0);
    }

    function test_setSplit_revertsIfRewardsTooHigh() public {
        vm.prank(admin);
        controller.setRewardsReceiver(address(0x9999));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolFeeController.RewardsShareTooHigh.selector, 3000, 2500)
        );
        controller.setSplit(5000, 2000, 3000);
    }

    function test_setSplit_revertsIfRewardsBpsButNoReceiver() public {
        vm.prank(admin);
        vm.expectRevert(ProtocolFeeController.RewardsReceiverNotSet.selector);
        controller.setSplit(5000, 3500, 1500);
    }

    function test_setSplit_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        controller.setSplit(6000, 4000, 0);
    }

    // ─── downstream wiring ──────────────────────────────────────────────

    function test_setTreasury() public {
        address newT = address(0xCAFE);
        vm.prank(admin);
        controller.setTreasury(newT);
        assertEq(controller.treasury(), newT);
    }

    function test_setBurnRouter_sanityCheck() public {
        // New router with same layer token: ok.
        MockBurnRouter newRouter = new MockBurnRouter(address(layer));
        vm.prank(admin);
        controller.setBurnRouter(address(newRouter));
        assertEq(controller.burnRouter(), address(newRouter));

        // New router with DIFFERENT layer token: rejected.
        MockToken otherLayer = new MockToken();
        MockBurnRouter wrongRouter = new MockBurnRouter(address(otherLayer));
        vm.prank(admin);
        vm.expectRevert(ProtocolFeeController.ZeroAddress.selector);
        controller.setBurnRouter(address(wrongRouter));
    }

    function test_setRewardsReceiver_clearsBpsToTreasury() public {
        // First set a valid split with rewards.
        vm.startPrank(admin);
        controller.setRewardsReceiver(address(0x9999));
        controller.setSplit(5000, 3500, 1500);
        assertEq(controller.rewardsBps(), 1500);

        // Setting receiver to address(0) should zero rewardsBps and re-allocate to treasury.
        controller.setRewardsReceiver(address(0));
        assertEq(controller.rewardsReceiver(), address(0));
        assertEq(controller.rewardsBps(), 0);
        assertEq(controller.treasuryBps(), 6500);
        assertEq(controller.burnBps(), 3500);
        vm.stopPrank();
    }

    // ─── processFees ─────────────────────────────────────────────────────

    function test_processFees_default60_40() public {
        token.mint(address(controller), 1_000_000);
        controller.processFees(address(token));
        // 60% / 40% / 0 split.
        assertEq(token.balanceOf(treasury), 600_000);
        assertEq(token.balanceOf(address(router)), 400_000);
        assertEq(token.balanceOf(address(controller)), 0);
    }

    function test_processFees_revertsOnEmpty() public {
        vm.expectRevert(ProtocolFeeController.NothingToProcess.selector);
        controller.processFees(address(token));
    }

    function test_processFees_dustGoesToBurn() public {
        token.mint(address(controller), 7); // 7 * 6000 / 10000 = 4 (treasury), rest to burn
        controller.processFees(address(token));
        assertEq(token.balanceOf(treasury), 4);
        assertEq(token.balanceOf(address(router)), 3);
        assertEq(token.balanceOf(address(controller)), 0);
    }

    function test_processFees_withRewardsActive() public {
        address rewards = address(0x9999);
        vm.startPrank(admin);
        controller.setRewardsReceiver(rewards);
        controller.setSplit(5000, 3500, 1500);
        vm.stopPrank();

        token.mint(address(controller), 10_000);
        controller.processFees(address(token));
        // 50% / 35% / 15% split, with burn taking the rounding remainder.
        assertEq(token.balanceOf(treasury), 5000);
        assertEq(token.balanceOf(rewards), 1500);
        assertEq(token.balanceOf(address(router)), 3500);
    }

    function test_adminRescue() public {
        token.mint(address(controller), 5000);
        vm.prank(admin);
        controller.adminRescue(address(token), stranger, 1000);
        assertEq(token.balanceOf(stranger), 1000);
        assertEq(token.balanceOf(address(controller)), 4000);
    }

    function test_adminRescueEth() public {
        vm.deal(address(controller), 1 ether);

        vm.prank(admin);
        controller.adminRescueEth(payable(stranger), 0.4 ether);

        assertEq(stranger.balance, 0.4 ether);
        assertEq(address(controller).balance, 0.6 ether);
    }

    function test_adminRescueEth_revertsForZeroRecipient() public {
        vm.deal(address(controller), 1 ether);

        vm.prank(admin);
        vm.expectRevert(ProtocolFeeController.ZeroAddress.selector);
        controller.adminRescueEth(payable(address(0)), 0.1 ether);
    }

    function test_adminRescueEth_revertsForInsufficientBalance() public {
        vm.deal(address(controller), 1 ether);

        vm.prank(admin);
        vm.expectRevert(ProtocolFeeController.InsufficientEthBalance.selector);
        controller.adminRescueEth(payable(stranger), 2 ether);
    }

    function test_adminRescueEth_nonOwnerReverts() public {
        vm.deal(address(controller), 1 ether);

        vm.prank(stranger);
        vm.expectRevert();
        controller.adminRescueEth(payable(stranger), 0.1 ether);
    }
}
