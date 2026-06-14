// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactory} from "../../src/interfaces/IArtCoinsFactory.sol";
import {ArtCoinsFactory} from "../../src/legacy/ArtCoinsFactory.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Tests for the flat ETH deploy fee on ArtCoinsFactory.
/// @dev We exercise the unit-level surface here (storage default, setter,
///      bounds, event, msg.value validation, and interaction with the
///      no-extensions path). A full-fledged "successful deploy + fee
///      forwarded" test requires the rest of the launch stack and lives in
///      the fork-only Integration suite.
contract ArtCoinsFactoryDeployFeeTest is Test {
    ArtCoinsFactory internal factory;
    address internal owner = address(0xCAFE);
    address internal nonOwner = address(0xDEAD);

    function setUp() public {
        vm.startPrank(owner);
        factory = new ArtCoinsFactory(owner);
        vm.stopPrank();
    }

    // ─── default state ───────────────────────────────────────────────────

    function test_defaultDeployFee() public view {
        assertEq(factory.deployFee(), 0.069 ether);
    }

    function test_maxDeployFeeConstant() public view {
        assertEq(factory.MAX_DEPLOY_FEE(), 1 ether);
    }

    function test_defaultProtocolFeeBps() public view {
        assertEq(factory.defaultProtocolFeeBps(), 2000);
    }

    // ─── setter ──────────────────────────────────────────────────────────

    function test_setDeployFee() public {
        vm.expectEmit(true, true, true, true);
        emit IArtCoinsFactory.DeployFeeUpdated(0.069 ether, 0.1 ether);
        vm.prank(owner);
        factory.setDeployFee(0.1 ether);
        assertEq(factory.deployFee(), 0.1 ether);
    }

    function test_setDeployFee_toZero() public {
        vm.prank(owner);
        factory.setDeployFee(0);
        assertEq(factory.deployFee(), 0);
    }

    function test_setDeployFee_atMax() public {
        uint256 cap = factory.MAX_DEPLOY_FEE();
        vm.prank(owner);
        factory.setDeployFee(cap);
        assertEq(factory.deployFee(), 1 ether);
    }

    function test_setDeployFee_revertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(IArtCoinsFactory.DeployFeeTooHigh.selector);
        factory.setDeployFee(1 ether + 1);
    }

    function test_setDeployFee_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setDeployFee(0.1 ether);
    }

    // ─── deployToken msg.value gating ────────────────────────────────────

    function test_deploy_revertsIfMsgValueLessThanFee() public {
        vm.prank(owner);
        factory.setDeprecated(false);

        IArtCoinsFactory.DeploymentConfig memory config;
        config.tokenConfig = _makeTokenConfig(bytes32(uint256(1)));

        vm.deal(address(this), 1 ether);
        // No extensions, deploy fee = 0.069 ether — sending less must revert.
        vm.expectRevert(IArtCoinsFactory.ExtensionMsgValueMismatch.selector);
        factory.deployToken{value: 0.05 ether}(config);
    }

    function test_deploy_revertsIfMsgValueExceedsFee() public {
        vm.prank(owner);
        factory.setDeprecated(false);

        IArtCoinsFactory.DeploymentConfig memory config;
        config.tokenConfig = _makeTokenConfig(bytes32(uint256(2)));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(IArtCoinsFactory.ExtensionMsgValueMismatch.selector);
        factory.deployToken{value: 0.5 ether}(config);
    }

    function test_deploy_revertsIfFeeSetButRecipientUnset() public {
        // With default deployFee = 0.069 ether and teamFeeRecipient unset,
        // a deploy must revert with TeamFeeRecipientNotSet. This fires from
        // either _forwardDeployFee or _injectProtocolFeeSlot — both check
        // teamFeeRecipient — before the hook/locker validation runs.
        vm.prank(owner);
        factory.setDeprecated(false);

        IArtCoinsFactory.DeploymentConfig memory config;
        config.tokenConfig = _makeTokenConfig(bytes32(uint256(3)));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(IArtCoinsFactory.TeamFeeRecipientNotSet.selector);
        factory.deployToken{value: 0.069 ether}(config);
    }

    function test_deploy_skipsFeeForwardWhenFeeIsZero() public {
        // With fee = 0 and no recipient, the fee forwarding is skipped entirely
        // (no revert from _forwardDeployFee). The protocol-fee injection still
        // runs but only blocks if defaultProtocolFeeBps > 0 — set it to 0 here
        // to confirm the deploy proceeds to the next layer (hook validation).
        vm.startPrank(owner);
        factory.setDeployFee(0);
        factory.setDefaultProtocolFeeBps(0);
        factory.setDeprecated(false);
        vm.stopPrank();

        IArtCoinsFactory.DeploymentConfig memory config;
        config.tokenConfig = _makeTokenConfig(bytes32(uint256(4)));
        // Hook unset on the config + no allowlist → reverts with HookNotEnabled.
        vm.expectRevert(IArtCoinsFactory.HookNotEnabled.selector);
        factory.deployToken{value: 0}(config);
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _makeTokenConfig(bytes32 salt)
        internal
        view
        returns (IArtCoinsFactory.TokenConfig memory)
    {
        return IArtCoinsFactory.TokenConfig({
            tokenAdmin: address(0xA1),
            name: "T",
            symbol: "T",
            salt: salt,
            image: "",
            metadata: "",
            context: "",
            totalSupply: 0,
            renderer: address(0)
        });
    }
}
