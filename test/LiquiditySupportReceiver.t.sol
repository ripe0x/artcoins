// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LiquiditySupportReceiver} from "../src/protocol-fee/LiquiditySupportReceiver.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LiquiditySupportReceiverTest is Test {
    LiquiditySupportReceiver internal recv;
    MockToken internal layer;
    MockToken internal weth;
    address internal admin = address(0xA1);
    address internal recipient = address(0xB2);
    address internal stranger = address(0xDEAD);

    function setUp() public {
        layer = new MockToken();
        weth = new MockToken();
        recv = new LiquiditySupportReceiver(admin, address(layer), address(weth));
    }

    function test_constructorRejectsZeroAddresses() public {
        // Zero owner reverts at the OZ Ownable layer.
        vm.expectRevert();
        new LiquiditySupportReceiver(address(0), address(layer), address(weth));
        vm.expectRevert(LiquiditySupportReceiver.ZeroAddress.selector);
        new LiquiditySupportReceiver(admin, address(0), address(weth));
        vm.expectRevert(LiquiditySupportReceiver.ZeroAddress.selector);
        new LiquiditySupportReceiver(admin, address(layer), address(0));
    }

    function test_balancesView() public {
        layer.mint(address(recv), 1000);
        weth.mint(address(recv), 2000);
        (uint256 l, uint256 w) = recv.balances();
        assertEq(l, 1000);
        assertEq(w, 2000);
    }

    function test_adminWithdraw() public {
        layer.mint(address(recv), 5000);
        vm.prank(admin);
        recv.adminWithdraw(address(layer), recipient, 3000);
        assertEq(layer.balanceOf(recipient), 3000);
        assertEq(layer.balanceOf(address(recv)), 2000);
    }

    function test_adminWithdrawRevertsOnZeroRecipient() public {
        layer.mint(address(recv), 5000);
        vm.prank(admin);
        vm.expectRevert(LiquiditySupportReceiver.ZeroAddress.selector);
        recv.adminWithdraw(address(layer), address(0), 3000);
    }

    function test_adminWithdrawRevertsOnInsufficient() public {
        layer.mint(address(recv), 1000);
        vm.prank(admin);
        vm.expectRevert(LiquiditySupportReceiver.InsufficientBalance.selector);
        recv.adminWithdraw(address(layer), recipient, 2000);
    }

    function test_adminWithdrawRevertsForNonAdmin() public {
        layer.mint(address(recv), 1000);
        vm.prank(stranger);
        vm.expectRevert();
        recv.adminWithdraw(address(layer), recipient, 100);
    }

    function test_receivesEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(recv).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(recv).balance, 1 ether);
    }

    function test_adminWithdrawEth() public {
        vm.deal(address(recv), 1 ether);
        vm.prank(admin);
        recv.adminWithdrawEth(payable(recipient), 0.5 ether);
        assertEq(recipient.balance, 0.5 ether);
        assertEq(address(recv).balance, 0.5 ether);
    }
}
