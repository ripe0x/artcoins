// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

import {ArtCoinsVault} from "../src/extensions/ArtCoinsVault.sol";
import {IArtCoinsVault} from "../src/extensions/interfaces/IArtCoinsVault.sol";
import {IArtCoinsExtension} from "../src/interfaces/IArtCoinsExtension.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";

/// @notice Unit tests for ArtCoinsVault — covers setup, claim happy + revert
///         paths, vesting math, the lockup floor (7d), and the new vesting
///         floor (90d) anti-rug guarantee.
///
/// @dev    Deploys vault with `factory_ = address(this)` so the test contract
///         can drive `receiveTokens` directly without the factory + Uniswap v4
///         stack.
contract ArtCoinsVaultTest is Test {
    ArtCoinsVault internal vault;
    ERC20Mock internal token;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant LOCKUP = 7 days;
    uint256 internal constant VESTING = 90 days;
    uint256 internal constant TOTAL_SUPPLY = 1000 ether;

    function setUp() public {
        vault = new ArtCoinsVault(address(this));
        token = new ERC20Mock();
        token.mint(address(this), TOTAL_SUPPLY);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _emptyPoolKey() internal pure returns (PoolKey memory pk) {}

    function _depConfig(address admin_, uint256 lockupDur, uint256 vestingDur, uint16 bps)
        internal
        view
        returns (IArtCoinsFactory.DeploymentConfig memory cfg)
    {
        cfg.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](1);
        cfg.extensionConfigs[0] = IArtCoinsFactory.ExtensionConfig({
            extension: address(vault),
            msgValue: 0,
            extensionBps: bps,
            extensionData: abi.encode(
                IArtCoinsVault.VaultExtensionData({
                    admin: admin_, lockupDuration: lockupDur, vestingDuration: vestingDur
                })
            )
        });
    }

    function _setupVault(uint256 lockupDur, uint256 vestingDur) internal {
        token.approve(address(vault), TOTAL_SUPPLY);
        vault.receiveTokens(
            _depConfig(admin, lockupDur, vestingDur, 1000),
            _emptyPoolKey(),
            address(token),
            TOTAL_SUPPLY,
            0
        );
    }

    // ─── receiveTokens ─────────────────────────────────────────────────

    function test_receiveTokens_setsState() public {
        _setupVault(LOCKUP, VESTING);
        (
            address tokenAddr,
            uint256 amountTotal,
            uint256 amountClaimed,
            uint256 lockupEnd,
            uint256 vestingEnd,
            address admin_
        ) = vault.allocation(address(token));

        assertEq(tokenAddr, address(token));
        assertEq(amountTotal, TOTAL_SUPPLY);
        assertEq(amountClaimed, 0);
        assertEq(lockupEnd, block.timestamp + LOCKUP);
        assertEq(vestingEnd, block.timestamp + LOCKUP + VESTING);
        assertEq(admin_, admin);
        assertEq(token.balanceOf(address(vault)), TOTAL_SUPPLY);
    }

    function test_receiveTokens_revertsForNonFactory() public {
        token.approve(address(vault), TOTAL_SUPPLY);
        vm.prank(makeAddr("notFactory"));
        vm.expectRevert(IArtCoinsVault.Unauthorized.selector);
        vault.receiveTokens(
            _depConfig(admin, LOCKUP, VESTING, 1000),
            _emptyPoolKey(),
            address(token),
            TOTAL_SUPPLY,
            0
        );
    }

    function test_receiveTokens_revertsIfAlreadyExists() public {
        _setupVault(LOCKUP, VESTING);
        token.mint(address(this), TOTAL_SUPPLY);
        token.approve(address(vault), TOTAL_SUPPLY);
        vm.expectRevert(IArtCoinsVault.AllocationAlreadyExists.selector);
        vault.receiveTokens(
            _depConfig(admin, LOCKUP, VESTING, 1000),
            _emptyPoolKey(),
            address(token),
            TOTAL_SUPPLY,
            0
        );
    }

    function test_receiveTokens_revertsIfBpsZero() public {
        token.approve(address(vault), TOTAL_SUPPLY);
        vm.expectRevert(IArtCoinsVault.InvalidVaultBps.selector);
        vault.receiveTokens(
            _depConfig(admin, LOCKUP, VESTING, 0), _emptyPoolKey(), address(token), TOTAL_SUPPLY, 0
        );
    }

    function test_receiveTokens_revertsIfAdminZero() public {
        token.approve(address(vault), TOTAL_SUPPLY);
        vm.expectRevert(IArtCoinsVault.InvalidVaultAdmin.selector);
        vault.receiveTokens(
            _depConfig(address(0), LOCKUP, VESTING, 1000),
            _emptyPoolKey(),
            address(token),
            TOTAL_SUPPLY,
            0
        );
    }

    function test_receiveTokens_revertsIfMsgValueNonZero() public {
        token.approve(address(vault), TOTAL_SUPPLY);
        IArtCoinsFactory.DeploymentConfig memory cfg = _depConfig(admin, LOCKUP, VESTING, 1000);
        cfg.extensionConfigs[0].msgValue = 1;
        vm.deal(address(this), 1);
        vm.expectRevert(IArtCoinsExtension.InvalidMsgValue.selector);
        vault.receiveTokens{value: 1}(cfg, _emptyPoolKey(), address(token), TOTAL_SUPPLY, 0);
    }

    // ─── Lockup floor ─────────────────────────────────────────────────

    function test_receiveTokens_revertsIfLockupBelowFloor() public {
        token.approve(address(vault), TOTAL_SUPPLY);
        vm.expectRevert(IArtCoinsVault.VaultLockupDurationTooShort.selector);
        vault.receiveTokens(
            _depConfig(admin, LOCKUP - 1, VESTING, 1000),
            _emptyPoolKey(),
            address(token),
            TOTAL_SUPPLY,
            0
        );
    }

    function test_receiveTokens_acceptsLockupAtFloor() public {
        _setupVault(LOCKUP, VESTING);
        (,,, uint256 lockupEnd,,) = vault.allocation(address(token));
        assertEq(lockupEnd, block.timestamp + LOCKUP);
    }

    // ─── Vesting floor (the new check) ─────────────────────────────────

    function test_receiveTokens_revertsIfVestingBelowFloor() public {
        token.approve(address(vault), TOTAL_SUPPLY);
        vm.expectRevert(IArtCoinsVault.VaultVestingDurationTooShort.selector);
        vault.receiveTokens(
            _depConfig(admin, LOCKUP, VESTING - 1, 1000),
            _emptyPoolKey(),
            address(token),
            TOTAL_SUPPLY,
            0
        );
    }

    function test_receiveTokens_revertsIfVestingZero() public {
        token.approve(address(vault), TOTAL_SUPPLY);
        vm.expectRevert(IArtCoinsVault.VaultVestingDurationTooShort.selector);
        vault.receiveTokens(
            _depConfig(admin, LOCKUP, 0, 1000), _emptyPoolKey(), address(token), TOTAL_SUPPLY, 0
        );
    }

    function test_receiveTokens_acceptsVestingAtFloor() public {
        _setupVault(LOCKUP, VESTING);
        (,,,, uint256 vestingEnd,) = vault.allocation(address(token));
        assertEq(vestingEnd, block.timestamp + LOCKUP + VESTING);
    }

    function test_receiveTokens_acceptsVestingAboveFloor() public {
        _setupVault(LOCKUP, 365 days);
        (,,, uint256 lockupEnd, uint256 vestingEnd,) = vault.allocation(address(token));
        assertEq(vestingEnd, lockupEnd + 365 days);
    }

    // ─── claim — happy paths ───────────────────────────────────────────

    function test_claim_atVestingEnd_paysFullAllocation() public {
        _setupVault(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING);
        vault.claim(address(token));
        assertEq(token.balanceOf(admin), TOTAL_SUPPLY);
    }

    function test_claim_halfwayThroughVesting_paysHalf() public {
        _setupVault(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING / 2);
        vault.claim(address(token));
        assertApproxEqAbs(token.balanceOf(admin), TOTAL_SUPPLY / 2, 1);
    }

    function test_claim_multiplePartialClaims_accumulate() public {
        _setupVault(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING / 4);
        vault.claim(address(token));
        uint256 first = token.balanceOf(admin);
        assertGt(first, 0);
        assertLt(first, TOTAL_SUPPLY);

        vm.warp(block.timestamp + VESTING / 4);
        vault.claim(address(token));
        uint256 second = token.balanceOf(admin);
        assertGt(second, first);

        vm.warp(block.timestamp + VESTING); // past end
        vault.claim(address(token));
        assertEq(token.balanceOf(admin), TOTAL_SUPPLY);
    }

    function test_claim_emitsEvent() public {
        _setupVault(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IArtCoinsVault.AllocationClaimed(address(token), TOTAL_SUPPLY, 0);
        vault.claim(address(token));
    }

    function test_claim_anyoneCanCall_butAdminReceives() public {
        // The contract sends tokens to `allocation.admin`, regardless of msg.sender.
        _setupVault(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING);
        vm.prank(makeAddr("relayer"));
        vault.claim(address(token));
        assertEq(token.balanceOf(admin), TOTAL_SUPPLY);
    }

    function test_amountAvailableToClaim_tracksVesting() public {
        _setupVault(LOCKUP, VESTING);
        // During lockup
        assertEq(vault.amountAvailableToClaim(address(token)), 0);
        // Halfway through vesting
        vm.warp(block.timestamp + LOCKUP + VESTING / 2);
        assertApproxEqAbs(vault.amountAvailableToClaim(address(token)), TOTAL_SUPPLY / 2, 1);
        // After vesting end
        vm.warp(block.timestamp + VESTING / 2);
        assertEq(vault.amountAvailableToClaim(address(token)), TOTAL_SUPPLY);
    }

    // ─── claim — revert paths ─────────────────────────────────────────

    function test_claim_revertsIfBeforeLockup() public {
        _setupVault(LOCKUP, VESTING);
        vm.expectRevert(IArtCoinsVault.AllocationNotUnlocked.selector);
        vault.claim(address(token));
    }

    function test_claim_revertsIfNothingClaimable_atLockupEnd() public {
        // Exactly at lockupEnd, with vesting > 0, the formula yields 0.
        _setupVault(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP);
        vm.expectRevert(IArtCoinsVault.NoBalanceToClaim.selector);
        vault.claim(address(token));
    }

    function test_claim_revertsAfterFullClaim() public {
        _setupVault(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING);
        vault.claim(address(token));
        // Second attempt: nothing left to claim
        vm.expectRevert(IArtCoinsVault.NoBalanceToClaim.selector);
        vault.claim(address(token));
    }

    // ─── editAllocationAdmin ───────────────────────────────────────────

    function test_editAllocationAdmin_byAdmin_works() public {
        _setupVault(LOCKUP, VESTING);
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        vault.editAllocationAdmin(address(token), newAdmin);
        (,,,,, address admin_) = vault.allocation(address(token));
        assertEq(admin_, newAdmin);
    }

    function test_editAllocationAdmin_byNonAdmin_reverts() public {
        _setupVault(LOCKUP, VESTING);
        vm.expectRevert(IArtCoinsVault.Unauthorized.selector);
        vm.prank(makeAddr("attacker"));
        vault.editAllocationAdmin(address(token), makeAddr("evil"));
    }

    function test_editAllocationAdmin_thenClaim_paysToNewAdmin() public {
        _setupVault(LOCKUP, VESTING);
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        vault.editAllocationAdmin(address(token), newAdmin);
        vm.warp(block.timestamp + LOCKUP + VESTING);
        vault.claim(address(token));
        assertEq(token.balanceOf(newAdmin), TOTAL_SUPPLY);
        assertEq(token.balanceOf(admin), 0);
    }

    // ─── ERC-165 ──────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(type(IArtCoinsExtension).interfaceId));
        assertFalse(vault.supportsInterface(0xdeadbeef));
    }
}
