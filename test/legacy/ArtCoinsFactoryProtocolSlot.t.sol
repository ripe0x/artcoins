// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactory} from "../../src/interfaces/IArtCoinsFactory.sol";
import {ArtCoinsFactory} from "../../src/legacy/ArtCoinsFactory.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Direct tests for the factory's protocol-fee-slot auto-injection.
/// @dev We can't reach the post-injection success path without the full
///      hook+locker stack, so we exercise the *validation* surface here:
///      project-side bps must sum to (10_000 - defaultProtocolFeeBps),
///      teamFeeRecipient must be set when injection is active, and the
///      `defaultProtocolFeeBps == 0` legacy path still works.
contract ArtCoinsFactoryProtocolSlotTest is Test {
    ArtCoinsFactory internal factory;
    address internal owner = address(0xCAFE);
    address internal artist = address(0xA1);
    address internal feeSink = address(0xFEE);

    function setUp() public {
        vm.startPrank(owner);
        factory = new ArtCoinsFactory(owner);
        factory.setDeprecated(false);
        factory.setTeamFeeRecipient(feeSink);
        // factory.deployFee() is 0.069 ether by default; tests fund and supply it.
        vm.stopPrank();
    }

    // ─── injection active (default 2000 bps) ─────────────────────────────

    function test_revertsWhenProjectBpsSumsTo10000() public {
        // Legacy locker shape (sum = 10_000) is rejected when injection is on.
        // We can't reach the locker check directly without a hook, but the
        // factory's own `ProjectSideBpsMismatch` fires first.
        IArtCoinsFactory.DeploymentConfig memory dc = _baseConfigWithRewardBps(_one(10_000));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(IArtCoinsFactory.ProjectSideBpsMismatch.selector);
        factory.deployToken{value: 0.069 ether}(dc);
    }

    function test_revertsWhenProjectBpsSumsTo7000() public {
        // 7000 + 2000 protocol = 9000 ≠ 10_000.
        IArtCoinsFactory.DeploymentConfig memory dc = _baseConfigWithRewardBps(_one(7000));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(IArtCoinsFactory.ProjectSideBpsMismatch.selector);
        factory.deployToken{value: 0.069 ether}(dc);
    }

    function test_revertsWhenProjectBpsSumsTo9000() public {
        // 9000 + 2000 = 11000 — over.
        IArtCoinsFactory.DeploymentConfig memory dc = _baseConfigWithRewardBps(_one(9000));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(IArtCoinsFactory.ProjectSideBpsMismatch.selector);
        factory.deployToken{value: 0.069 ether}(dc);
    }

    function test_passesProjectBpsCheckWhenSumsTo8000() public {
        // 8000 + 2000 = 10_000 — passes injection check; reverts later on
        // hook validation (no allowlisted hook in this test setup).
        IArtCoinsFactory.DeploymentConfig memory dc = _baseConfigWithRewardBps(_one(8000));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(IArtCoinsFactory.HookNotEnabled.selector);
        factory.deployToken{value: 0.069 ether}(dc);
    }

    function test_revertsWhenTeamFeeRecipientUnset() public {
        // Clear the recipient — injection has nothing to point at.
        vm.prank(owner);
        factory.setTeamFeeRecipient(address(0));

        IArtCoinsFactory.DeploymentConfig memory dc = _baseConfigWithRewardBps(_one(8000));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(IArtCoinsFactory.TeamFeeRecipientNotSet.selector);
        factory.deployToken{value: 0.069 ether}(dc);
    }

    // ─── injection disabled (defaultProtocolFeeBps = 0) ──────────────────

    function test_legacyShape_passesValidationWith10000() public {
        vm.prank(owner);
        factory.setDefaultProtocolFeeBps(0);
        // With injection disabled, the factory does NOT enforce the 8000 cap.
        // The deployer's array passes through; locker enforces sum == 10_000.
        IArtCoinsFactory.DeploymentConfig memory dc = _baseConfigWithRewardBps(_one(10_000));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(IArtCoinsFactory.HookNotEnabled.selector);
        factory.deployToken{value: 0.069 ether}(dc);
    }

    function test_legacyShape_doesNotRequireTeamFeeRecipient() public {
        // Even without a recipient, legacy path doesn't inject — and so
        // doesn't trip TeamFeeRecipientNotSet. Reverts later on hook check.
        vm.startPrank(owner);
        factory.setDefaultProtocolFeeBps(0);
        factory.setDeployFee(0); // skip fee forwarding too (which also requires recipient)
        factory.setTeamFeeRecipient(address(0));
        vm.stopPrank();

        IArtCoinsFactory.DeploymentConfig memory dc = _baseConfigWithRewardBps(_one(10_000));
        vm.expectRevert(IArtCoinsFactory.HookNotEnabled.selector);
        factory.deployToken{value: 0}(dc);
    }

    // ─── setter bounds ───────────────────────────────────────────────────

    function test_setDefaultProtocolFeeBps_atMax() public {
        uint16 cap = factory.MAX_PROTOCOL_FEE_BPS();
        vm.prank(owner);
        factory.setDefaultProtocolFeeBps(cap);
        assertEq(factory.defaultProtocolFeeBps(), 3000);
    }

    function test_setDefaultProtocolFeeBps_revertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(IArtCoinsFactory.ProtocolFeeBpsTooHigh.selector);
        factory.setDefaultProtocolFeeBps(3001);
    }

    function test_setDefaultProtocolFeeBps_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IArtCoinsFactory.DefaultProtocolFeeBpsUpdated(2000, 1500);
        vm.prank(owner);
        factory.setDefaultProtocolFeeBps(1500);
    }

    function test_setDefaultProtocolFeeBps_revertsForNonOwner() public {
        vm.prank(artist);
        vm.expectRevert();
        factory.setDefaultProtocolFeeBps(1500);
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _one(uint16 bps) internal pure returns (uint16[] memory arr) {
        arr = new uint16[](1);
        arr[0] = bps;
    }

    /// @dev Build a minimal config that gets past extension/fee validation
    ///      and into the protocol-slot injection logic. We don't allowlist
    ///      a hook, so any successful injection then reverts on
    ///      HookNotEnabled — useful as a "passes injection" sentinel.
    function _baseConfigWithRewardBps(uint16[] memory rewardBps)
        internal
        view
        returns (IArtCoinsFactory.DeploymentConfig memory dc)
    {
        dc.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: artist,
            name: "Test",
            symbol: "TST",
            salt: bytes32(uint256(uint160(rewardBps[0]))),
            image: "",
            metadata: "",
            context: "",
            totalSupply: 0,
            renderer: address(0)
        });

        address[] memory rewardAdmins = new address[](rewardBps.length);
        address[] memory rewardRecipients = new address[](rewardBps.length);
        for (uint256 i = 0; i < rewardBps.length; i++) {
            rewardAdmins[i] = artist;
            rewardRecipients[i] = artist;
        }

        int24[] memory tickLower = new int24[](1);
        tickLower[0] = -200;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = 200;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        dc.lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: address(0xBADBABE),
            rewardAdmins: rewardAdmins,
            rewardRecipients: rewardRecipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: ""
        });

        dc.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: address(0xDEADDEAD),
            pairedToken: address(0xC0FFEE),
            tickIfToken0IsArtCoins: 0,
            tickSpacing: 200,
            poolData: ""
        });

        // No extensions; deploy fee is the only required msg.value.
    }
}
