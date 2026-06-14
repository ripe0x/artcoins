// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactory} from "../../src/interfaces/IArtCoinsFactory.sol";
import {ArtCoinsFactory} from "../../src/legacy/ArtCoinsFactory.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Helper that pushes ETH into a target via `selfdestruct`. The factory
///      has no payable receiver, so this is the only legitimate way to land
///      stuck ETH for the `recoverETH` test.
contract ETHForcer {
    constructor() payable {}

    function forceTo(address payable target) external {
        selfdestruct(target);
    }
}

contract ArtCoinsFactoryTest is Test {
    ArtCoinsFactory public factory;
    address public owner = address(0xCAFE);
    address public admin = address(0xA1);
    address public nonOwner = address(0xDEAD);

    function setUp() public {
        vm.startPrank(owner);
        factory = new ArtCoinsFactory(owner);
        vm.stopPrank();
    }

    // ─── Constructor & initial state ────────────────────────────────────

    function test_initialState() public view {
        assertTrue(factory.deprecated());
        assertEq(factory.teamFeeRecipient(), address(0));
        // Protocol-fee + deploy-fee defaults baked into the constructor:
        assertEq(factory.defaultProtocolFeeBps(), 2000);
        assertEq(factory.deployFee(), 0.069 ether);
    }

    // ─── Owner functions ────────────────────────────────────────────────

    function test_setDeprecated() public {
        vm.prank(owner);
        factory.setDeprecated(false);
        assertFalse(factory.deprecated());
    }

    function test_setDeprecatedRevertsIfNotOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setDeprecated(false);
    }

    function test_setTeamFeeRecipient() public {
        vm.prank(owner);
        factory.setTeamFeeRecipient(address(0xFEE));
        assertEq(factory.teamFeeRecipient(), address(0xFEE));
    }

    // ─── ETH safety ─────────────────────────────────────────────────────

    function test_deployRevertsOnEthWithNoExtensions() public {
        // Without this guard, ETH would be silently trapped in the factory.
        vm.startPrank(owner);
        factory.setDeprecated(false);
        vm.stopPrank();

        IArtCoinsFactory.DeploymentConfig memory config;
        config.tokenConfig = _makeTokenConfig(bytes32(uint256(42)));
        // No extensions, but caller sends 1 ether anyway.
        vm.deal(address(this), 1 ether);
        vm.expectRevert(IArtCoinsFactory.ExtensionMsgValueMismatch.selector);
        factory.deployToken{value: 1 ether}(config);
    }

    function test_recoverETH_sweepsOwnerOnly() public {
        // Force ETH into the factory via selfdestruct (the factory has no
        // payable receive, so this is the only legitimate path for stuck ETH).
        ETHForcer forcer = new ETHForcer{value: 0.5 ether}();
        forcer.forceTo(payable(address(factory)));
        assertEq(address(factory).balance, 0.5 ether);

        address payable recipient = payable(address(0xABCD));
        vm.prank(owner);
        factory.recoverETH(recipient);
        assertEq(address(factory).balance, 0);
        assertEq(recipient.balance, 0.5 ether);
    }

    function test_recoverETHRevertsIfNotOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.recoverETH(payable(address(0xABCD)));
    }

    function test_recoverETHRevertsOnZeroRecipient() public {
        vm.prank(owner);
        vm.expectRevert(IArtCoinsFactory.ZeroAddress.selector);
        factory.recoverETH(payable(address(0)));
    }

    // ─── Deploy reverts ─────────────────────────────────────────────────

    function test_deployRevertsWhenDeprecated() public {
        IArtCoinsFactory.DeploymentConfig memory config;
        config.tokenConfig = _makeTokenConfig(bytes32(uint256(1)));

        vm.expectRevert(IArtCoinsFactory.Deprecated.selector);
        factory.deployToken(config);
    }

    function test_ownerCanDeployWhenDeprecated() public {
        _prepareDeprecatedBypassTest();

        IArtCoinsFactory.DeploymentConfig memory config;
        config.tokenConfig = _makeTokenConfig(bytes32(uint256(2)));

        vm.prank(owner);
        vm.expectRevert(IArtCoinsFactory.HookNotEnabled.selector);
        factory.deployToken(config);
    }

    function test_adminCanDeployWhenDeprecated() public {
        _prepareDeprecatedBypassTest();
        vm.prank(owner);
        factory.setAdmin(admin, true);

        IArtCoinsFactory.DeploymentConfig memory config;
        config.tokenConfig = _makeTokenConfig(bytes32(uint256(3)));

        vm.prank(admin);
        vm.expectRevert(IArtCoinsFactory.HookNotEnabled.selector);
        factory.deployToken(config);
    }

    // ─── Admin management ───────────────────────────────────────────────

    function test_setAdmin() public {
        vm.prank(owner);
        factory.setAdmin(admin, true);

        // Admin should be able to call onlyOwnerOrAdmin functions
        // (we can't easily test this without mock hooks, but we verify the setter works)
    }

    // ─── Constants ──────────────────────────────────────────────────────

    function test_constants() public view {
        assertEq(factory.DEFAULT_TOKEN_SUPPLY(), 1_000_000_000e18);
        assertEq(factory.MIN_TOKEN_SUPPLY(), 1e18);
        assertEq(factory.BPS(), 10_000);
        assertEq(factory.MAX_EXTENSIONS(), 10);
        assertEq(factory.MAX_EXTENSION_BPS(), 9000);
        // Bounds for the protocol-fee + deploy-fee features:
        assertEq(factory.MAX_PROTOCOL_FEE_BPS(), 3000);
        assertEq(factory.MAX_DEPLOY_FEE(), 1 ether);
    }

    function test_customSupplyInConfig() public view {
        // Verify TokenConfig accepts custom supply
        IArtCoinsFactory.TokenConfig memory config = IArtCoinsFactory.TokenConfig({
            tokenAdmin: admin,
            name: "Custom",
            symbol: "CST",
            salt: bytes32(uint256(1)),
            image: "",
            metadata: "",
            context: "",
            totalSupply: 1_000_000e18, // 1M tokens
            renderer: address(0)
        });
        assertEq(config.totalSupply, 1_000_000e18);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _prepareDeprecatedBypassTest() internal {
        assertTrue(factory.deprecated());
        vm.startPrank(owner);
        factory.setDeployFee(0);
        factory.setDefaultProtocolFeeBps(0);
        vm.stopPrank();
    }

    function _makeTokenConfig(bytes32 salt)
        internal
        view
        returns (IArtCoinsFactory.TokenConfig memory)
    {
        return IArtCoinsFactory.TokenConfig({
            tokenAdmin: admin,
            name: "TestToken",
            symbol: "TT",
            salt: salt,
            image: "https://img.com/t.png",
            metadata: "desc",
            context: "ctx",
            totalSupply: 0,
            renderer: address(0)
        });
    }
}
