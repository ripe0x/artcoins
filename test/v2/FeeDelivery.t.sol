// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsFeeEscrowV2} from "../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {IArtCoinsFeeEscrowV2} from "../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {FeeDelivery} from "../../src/v2/libraries/FeeDelivery.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ── shared mocks (also imported by the locker and escrow tests) ─────────────

contract PayableRecipient {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

contract RevertingRecipient {
    receive() external payable {
        revert("no eth");
    }
}

contract GasBurner {
    uint256 public sink;

    receive() external payable {
        while (true) {
            sink++;
        }
    }
}

/// @dev Returns a huge returndata blob from receive. A caller that copies
///      returndata would pay for it.
contract ReturnBomb {
    receive() external payable {
        assembly {
            revert(0, 1000000)
        }
    }
}

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Transfers to a blocked address revert; transferFrom is unaffected.
contract BlockingToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Block", "BLK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[to]) revert("blocked");
        super._update(from, to, value);
    }
}

/// @dev `transfer` returns false without moving funds; `transferFrom` works.
contract FalseTransferToken is ERC20 {
    constructor() ERC20("False", "FLS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev USDT style: no return value on transfer, transferFrom and approve.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        // USDT: non zero to non zero is rejected
        require(amount == 0 || allowance[msg.sender][spender] == 0, "usdt approve");
        allowance[msg.sender][spender] = amount;
    }
}

/// @dev Exposes the internal library through a depositor contract.
contract DeliveryHarness {
    address public immutable escrow;

    constructor(address escrow_) {
        escrow = escrow_;
    }

    receive() external payable {}

    function sendNative(address to, uint256 amount, uint256 gasCap) external returns (bool) {
        return FeeDelivery.sendNative(escrow, to, amount, gasCap);
    }

    function sendErc20(address token, address to, uint256 amount) external returns (bool) {
        return FeeDelivery.sendErc20(escrow, token, to, amount);
    }
}

contract FeeDeliveryTest is Test {
    ArtCoinsFeeEscrowV2 escrow;
    DeliveryHarness harness;
    address owner = makeAddr("owner");

    function setUp() public {
        escrow = new ArtCoinsFeeEscrowV2(owner);
        harness = new DeliveryHarness(address(escrow));
        vm.prank(owner);
        escrow.addDepositor(address(harness), true);
        vm.deal(address(harness), 100 ether);
    }

    // ── native ────────────────────────────────────────────────────────────

    function test_delivery_payable_pushed() public {
        PayableRecipient r = new PayableRecipient();
        bool pushed = harness.sendNative(address(r), 1 ether, Constants.PUSH_GAS_DEFAULT);
        assertTrue(pushed);
        assertEq(address(r).balance, 1 ether);
        assertEq(r.received(), 1 ether);
        assertEq(escrow.balances(address(r), address(0)), 0);
        assertEq(escrow.totalOwed(address(0)), 0);
    }

    function test_delivery_eoa_pushed() public {
        address eoa = makeAddr("eoa");
        assertTrue(harness.sendNative(eoa, 1 ether, Constants.PUSH_GAS_MIN));
        assertEq(eoa.balance, 1 ether);
    }

    function test_delivery_reverting_escrowed() public {
        RevertingRecipient r = new RevertingRecipient();
        bool pushed = harness.sendNative(address(r), 1 ether, Constants.PUSH_GAS_DEFAULT);
        assertFalse(pushed);
        assertEq(address(r).balance, 0);
        assertEq(escrow.balances(address(r), address(0)), 1 ether);
        assertEq(escrow.totalOwed(address(0)), 1 ether);
        assertEq(address(escrow).balance, 1 ether);
    }

    function test_delivery_gasBurner_escrowed() public {
        GasBurner r = new GasBurner();
        uint256 g = gasleft();
        bool pushed = harness.sendNative(address(r), 1 ether, Constants.PUSH_GAS_DEFAULT);
        uint256 used = g - gasleft();
        assertFalse(pushed);
        assertEq(escrow.balances(address(r), address(0)), 1 ether);
        // the burner is limited to the cap; the fallback adds well under 100k
        assertLt(used, uint256(Constants.PUSH_GAS_DEFAULT) + 120_000);
    }

    function test_delivery_returnBomb_escrowed_cheaply() public {
        ReturnBomb r = new ReturnBomb();
        uint256 g = gasleft();
        bool pushed = harness.sendNative(address(r), 1 ether, Constants.PUSH_GAS_MAX);
        uint256 used = g - gasleft();
        assertFalse(pushed);
        assertEq(escrow.balances(address(r), address(0)), 1 ether);
        assertLt(used, uint256(Constants.PUSH_GAS_MAX) + 120_000);
    }

    function test_delivery_zeroAmount_noop() public {
        RevertingRecipient r = new RevertingRecipient();
        assertTrue(harness.sendNative(address(r), 0, Constants.PUSH_GAS_DEFAULT));
        assertTrue(harness.sendErc20(address(0xBEEF), address(r), 0));
        assertEq(escrow.totalOwed(address(0)), 0);
    }

    function test_delivery_notDepositor_reverts() public {
        DeliveryHarness stranger = new DeliveryHarness(address(escrow));
        vm.deal(address(stranger), 1 ether);
        RevertingRecipient r = new RevertingRecipient();
        vm.expectRevert(IArtCoinsFeeEscrowV2.NotDepositor.selector);
        stranger.sendNative(address(r), 1 ether, Constants.PUSH_GAS_DEFAULT);
    }

    function testFuzz_delivery_native_everyWeiAccounted(uint96 amount, uint8 kind) public {
        vm.assume(amount > 0);
        address to;
        if (kind % 3 == 0) to = address(new PayableRecipient());
        else if (kind % 3 == 1) to = address(new RevertingRecipient());
        else to = address(new GasBurner());
        vm.deal(address(harness), amount);
        harness.sendNative(to, amount, Constants.PUSH_GAS_DEFAULT);
        assertEq(to.balance + escrow.balances(to, address(0)), amount);
        assertEq(address(harness).balance, 0);
    }

    // ── erc20 ─────────────────────────────────────────────────────────────

    function test_delivery_erc20_pushed() public {
        MockToken t = new MockToken();
        t.mint(address(harness), 10e18);
        address to = makeAddr("to");
        assertTrue(harness.sendErc20(address(t), to, 3e18));
        assertEq(t.balanceOf(to), 3e18);
        assertEq(t.balanceOf(address(escrow)), 0);
    }

    function test_delivery_erc20_blocked_escrowed() public {
        BlockingToken t = new BlockingToken();
        t.mint(address(harness), 10e18);
        address to = makeAddr("to");
        t.setBlocked(to, true);
        assertFalse(harness.sendErc20(address(t), to, 3e18));
        assertEq(escrow.balances(to, address(t)), 3e18);
        assertEq(escrow.totalOwed(address(t)), 3e18);
        assertEq(t.balanceOf(address(escrow)), 3e18);
        assertEq(t.allowance(address(harness), address(escrow)), 0);
    }

    function test_delivery_erc20_falseReturn_escrowed() public {
        FalseTransferToken t = new FalseTransferToken();
        t.mint(address(harness), 10e18);
        address to = makeAddr("to");
        assertFalse(harness.sendErc20(address(t), to, 3e18));
        assertEq(escrow.balances(to, address(t)), 3e18);
        assertEq(t.balanceOf(address(escrow)), 3e18);
    }

    function test_delivery_erc20_noReturn_pushed() public {
        NoReturnToken t = new NoReturnToken();
        t.mint(address(harness), 10e18);
        address to = makeAddr("to");
        assertTrue(harness.sendErc20(address(t), to, 3e18));
        assertEq(t.balanceOf(to), 3e18);
    }

    function test_delivery_erc20_insufficient_reverts() public {
        // the fallback cannot conjure funds: delivering more than held reverts
        MockToken t = new MockToken();
        t.mint(address(harness), 1e18);
        vm.expectRevert();
        harness.sendErc20(address(t), makeAddr("to"), 3e18);
    }
}
