// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFeeController} from "../src/protocol-fee/ProtocolFeeController.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal IBurnRouter stub — only `layerToken()` is read during
///      ProtocolFeeController construction (and `setBurnRouter`). Payable so
///      it can receive the native-ETH burn share.
contract MockBurnRouter {
    address public layerToken;

    receive() external payable {}

    constructor(address _layer) {
        layerToken = _layer;
    }
}

contract MockNonPayableRecipient {
    // No receive(), no payable fallback. Rejects ETH.

    }

/// @notice Unit tests for the fixed two-sink `ProtocolFeeController` — the
///         immutable split set at construction, the ERC20 and native-ETH
///         processing paths, and downstream-wiring rotation.
contract ProtocolFeeControllerTest is Test {
    ProtocolFeeController internal pfc;
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    MockBurnRouter internal burnRouter;
    address internal layerToken = makeAddr("layer");

    /// @dev LAYER's split: 60% treasury / 40% burn.
    uint16 internal constant TREASURY_BPS = 6000;

    function setUp() public {
        burnRouter = new MockBurnRouter(layerToken);
        pfc = new ProtocolFeeController(admin, treasury, address(burnRouter), TREASURY_BPS);
    }

    receive() external payable {}

    // ─── constants & state ──────────────────────────────────────────────

    function test_constants() public view {
        assertEq(pfc.BPS(), 10_000);
        assertEq(pfc.MIN_TREASURY_BPS(), 4000);
        assertEq(pfc.MIN_BURN_BPS(), 1000);
    }

    function test_defaults() public view {
        assertEq(pfc.treasury(), treasury);
        assertEq(pfc.burnRouter(), address(burnRouter));
        assertEq(pfc.treasuryBps(), 6000);
        assertEq(pfc.burnBps(), 4000);
    }

    // ─── construction: immutable split ──────────────────────────────────

    /// @dev burnBps is derived as BPS - treasuryBps; an 8667/1333 instance is
    ///      the permanent-collection shape.
    function test_constructor_derivesBurnBps() public {
        ProtocolFeeController pc =
            new ProtocolFeeController(admin, treasury, address(burnRouter), 8667);
        assertEq(pc.treasuryBps(), 8667);
        assertEq(pc.burnBps(), 1333);
    }

    /// @dev Both floors are inclusive: 40/60 (treasury floor) and 90/10 (burn
    ///      floor) are valid.
    function test_constructor_acceptsBoundaries() public {
        ProtocolFeeController lo =
            new ProtocolFeeController(admin, treasury, address(burnRouter), 4000);
        assertEq(lo.treasuryBps(), 4000);
        assertEq(lo.burnBps(), 6000);

        ProtocolFeeController hi =
            new ProtocolFeeController(admin, treasury, address(burnRouter), 9000);
        assertEq(hi.treasuryBps(), 9000);
        assertEq(hi.burnBps(), 1000);
    }

    function test_constructor_revertsTreasuryTooLow() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolFeeController.TreasuryShareTooLow.selector, uint16(3999), uint16(4000)
            )
        );
        new ProtocolFeeController(admin, treasury, address(burnRouter), 3999);
    }

    /// @dev treasuryBps 9001 → derived burn 999 < MIN_BURN_BPS.
    function test_constructor_revertsBurnTooLow() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolFeeController.BurnShareTooLow.selector, uint16(999), uint16(1000)
            )
        );
        new ProtocolFeeController(admin, treasury, address(burnRouter), 9001);
    }

    /// @dev treasuryBps > BPS is caught by the same burn-floor upper bound,
    ///      with the implied burn share reported as 0 (no underflow).
    function test_constructor_revertsTreasuryOverBps() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolFeeController.BurnShareTooLow.selector, uint16(0), uint16(1000)
            )
        );
        new ProtocolFeeController(admin, treasury, address(burnRouter), 10_001);
    }

    function test_constructor_rejectsZeros() public {
        // Zero owner reverts at the OZ Ownable layer before our ZeroAddress check.
        vm.expectRevert();
        new ProtocolFeeController(address(0), treasury, address(burnRouter), TREASURY_BPS);
        // Zero treasury / burnRouter hit our explicit ZeroAddress check.
        vm.expectRevert(ProtocolFeeController.ZeroAddress.selector);
        new ProtocolFeeController(admin, address(0), address(burnRouter), TREASURY_BPS);
        vm.expectRevert(ProtocolFeeController.ZeroAddress.selector);
        new ProtocolFeeController(admin, treasury, address(0), TREASURY_BPS);
    }

    // ─── setBurnRouter ──────────────────────────────────────────────────

    function test_setBurnRouter_acceptsSameLayer() public {
        MockBurnRouter newRouter = new MockBurnRouter(layerToken);
        vm.prank(admin);
        pfc.setBurnRouter(address(newRouter));
        assertEq(pfc.burnRouter(), address(newRouter));
    }

    function test_setBurnRouter_rejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ProtocolFeeController.ZeroAddress.selector);
        pfc.setBurnRouter(address(0));
    }

    /// @dev A new router pointing at a different LAYER token is the mismatch
    ///      branch — distinct from the zero-address branch, which is why it
    ///      carries its own `LayerTokenMismatch` error.
    function test_setBurnRouter_rejectsLayerMismatch() public {
        MockBurnRouter wrongRouter = new MockBurnRouter(makeAddr("otherLayer"));
        vm.prank(admin);
        vm.expectRevert(ProtocolFeeController.LayerTokenMismatch.selector);
        pfc.setBurnRouter(address(wrongRouter));
    }

    function test_setBurnRouter_onlyOwner() public {
        MockBurnRouter newRouter = new MockBurnRouter(layerToken);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        pfc.setBurnRouter(address(newRouter));
    }

    // ─── setTreasury ────────────────────────────────────────────────────

    function test_setTreasury_rotates() public {
        address next = makeAddr("nextTreasury");
        vm.prank(admin);
        pfc.setTreasury(next);
        assertEq(pfc.treasury(), next);
    }

    function test_setTreasury_onlyOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        pfc.setTreasury(makeAddr("nextTreasury"));
    }

    function test_receivesEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(pfc).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(address(pfc).balance, 0.5 ether);
    }

    // ─── processNativeFees ──────────────────────────────────────────────

    function test_processNativeFees_splitsCorrectly() public {
        vm.deal(address(pfc), 1 ether);

        uint256 treasuryBefore = treasury.balance;
        uint256 burnBefore = address(burnRouter).balance;

        pfc.processNativeFees();

        // 60% treasury / 40% burn.
        assertEq(treasury.balance - treasuryBefore, 0.6 ether, "treasury 60%");
        assertEq(address(burnRouter).balance - burnBefore, 0.4 ether, "burn 40%");
        assertEq(address(pfc).balance, 0, "PFC drained");
    }

    /// @dev The 80/20 permanent-collection instance routes through the same
    ///      code path on its own immutable split.
    function test_processNativeFees_8020Instance() public {
        ProtocolFeeController pc =
            new ProtocolFeeController(admin, treasury, address(burnRouter), 8000);
        vm.deal(address(pc), 1 ether);

        uint256 treasuryBefore = treasury.balance;
        uint256 burnBefore = address(burnRouter).balance;

        pc.processNativeFees();

        assertEq(treasury.balance - treasuryBefore, 0.8 ether, "treasury 80%");
        assertEq(address(burnRouter).balance - burnBefore, 0.2 ether, "burn 20%");
    }

    function test_processNativeFees_revertsWhenEmpty() public {
        vm.expectRevert(ProtocolFeeController.NothingToProcess.selector);
        pfc.processNativeFees();
    }

    function test_processNativeFees_revertsIfTreasuryRejects() public {
        // Replace treasury with a non-payable contract.
        MockNonPayableRecipient bad = new MockNonPayableRecipient();
        vm.prank(admin);
        pfc.setTreasury(address(bad));

        vm.deal(address(pfc), 1 ether);
        vm.expectRevert(ProtocolFeeController.EthTransferFailed.selector);
        pfc.processNativeFees();

        // Balance preserved for retry.
        assertEq(address(pfc).balance, 1 ether);
    }

    function test_processNativeFees_permissionless() public {
        vm.deal(address(pfc), 1 ether);
        vm.prank(makeAddr("randomCaller"));
        pfc.processNativeFees();
        assertEq(address(pfc).balance, 0);
    }

    // ─── processFees (ERC20) ────────────────────────────────────────────

    function test_processFees_splitsErc20() public {
        MockToken token = new MockToken();
        token.mint(address(pfc), 1000 ether);

        pfc.processFees(address(token));

        assertEq(token.balanceOf(treasury), 600 ether, "treasury 60%");
        assertEq(token.balanceOf(address(burnRouter)), 400 ether, "burn 40%");
        assertEq(token.balanceOf(address(pfc)), 0, "PFC drained");
    }

    function test_processFees_revertsWhenEmpty() public {
        MockToken token = new MockToken();
        vm.expectRevert(ProtocolFeeController.NothingToProcess.selector);
        pfc.processFees(address(token));
    }

    /// @notice The V1 footgun (`processFees(address(0))` hitting a confusing
    ///         IERC20 balanceOf revert) is now an explicit `NothingToProcess`.
    function test_processFees_zeroAddressReverts() public {
        vm.deal(address(pfc), 1 ether);
        vm.expectRevert(ProtocolFeeController.NothingToProcess.selector);
        pfc.processFees(address(0));
    }

    function test_processFees_permissionless() public {
        MockToken token = new MockToken();
        token.mint(address(pfc), 100 ether);
        vm.prank(makeAddr("randomCaller"));
        pfc.processFees(address(token));
        assertEq(token.balanceOf(address(pfc)), 0);
    }
}
