// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsHookStaticFeeV2} from "../src/hooks/legacy/ArtCoinsHookStaticFeeV2.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @notice Test subclass that skips Uniswap v4's address-flag validation so
///         we can `new TestableHook()` at any address. Exposes seeders so
///         tests can drive sniper-fee state without spinning up a real
///         PoolManager.
contract TestableHook is ArtCoinsHookStaticFeeV2 {
    constructor(address pm, address f, address al, address weth)
        ArtCoinsHookStaticFeeV2(pm, f, al, weth)
    {}

    function validateHookAddress(BaseHook) internal pure override {}

    function testSetArtCoinsIsToken0(PoolKey calldata pk, bool v) external {
        artCoinIsToken0[pk.toId()] = v;
    }

    function testSetMevModule(PoolKey calldata pk, address m) external {
        mevModule[pk.toId()] = m;
    }

    function testSetMevModuleEnabled(PoolKey calldata pk, bool e) external {
        mevModuleEnabled[pk.toId()] = e;
    }

    function testSetPoolCreationTimestamp(PoolKey calldata pk, uint256 t) external {
        poolCreationTimestamp[pk.toId()] = t;
    }
}

/// Stub of `ArtCoinsToken` that exposes only `admin()` (read by the hook's
/// `onlyTokenAdmin` modifier).
contract MockTokenAdmin {
    address private _admin;

    function setAdmin(address a) external {
        _admin = a;
    }

    function admin() external view returns (address) {
        return _admin;
    }
}

/// @notice Unit tests for the sniper-extra fee path's access controls,
///         storage machine, and lock semantics. Does NOT exercise the real
///         skim path through PoolManager (that's covered separately by the
///         fork test). Mirrors the structure of HookSetPoolExtensionTest.
contract HookSniperExtraFeeUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    TestableHook internal hook;
    ArtCoinsPoolExtensionAllowlist internal allowlist;
    MockTokenAdmin internal token;

    address internal admin = makeAddr("admin");
    address internal recipient = makeAddr("burnRouter");
    address internal mevModuleAddr = makeAddr("mevModule");
    address internal factory = address(0x5678);

    PoolKey internal pk;
    PoolId internal pid;

    function setUp() public {
        allowlist = new ArtCoinsPoolExtensionAllowlist(address(this));
        hook = new TestableHook(
            address(0x1234), // pool manager (unused)
            factory,
            address(allowlist),
            address(0x9abc) // weth (unused)
        );

        token = new MockTokenAdmin();
        token.setAdmin(admin);

        address paired = makeAddr("paired");
        pk = PoolKey({
            currency0: Currency.wrap(
                uint160(address(token)) < uint160(paired) ? address(token) : paired
            ),
            currency1: Currency.wrap(
                uint160(address(token)) < uint160(paired) ? paired : address(token)
            ),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        pid = pk.toId();

        bool nmIsToken0 = Currency.unwrap(pk.currency0) == address(token);
        hook.testSetArtCoinsIsToken0(pk, nmIsToken0);

        // Bind a MEV module + mark it operational (within the 15-minute window).
        hook.testSetMevModule(pk, mevModuleAddr);
        hook.testSetMevModuleEnabled(pk, true);
        hook.testSetPoolCreationTimestamp(pk, block.timestamp);
    }

    // ─── setSniperFeeRecipient — auth, behavior, lock interaction ────

    function test_setSniperFeeRecipient_byAdmin_succeeds() public {
        vm.prank(admin);
        hook.setSniperFeeRecipient(pk, recipient);
        assertEq(hook.sniperFeeRecipient(pid), recipient);
        assertFalse(hook.sniperFeeRecipientLocked(pid));
    }

    function test_setSniperFeeRecipient_byNonAdmin_reverts() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.setSniperFeeRecipient(pk, recipient);
    }

    function test_setSniperFeeRecipient_zeroClearsAndDisablesPath() public {
        vm.prank(admin);
        hook.setSniperFeeRecipient(pk, recipient);
        vm.prank(admin);
        hook.setSniperFeeRecipient(pk, address(0));
        assertEq(hook.sniperFeeRecipient(pid), address(0));
    }

    function test_setSniperFeeRecipient_emitsEvent() public {
        vm.expectEmit(true, true, true, false, address(hook));
        emit IArtCoinsHook.SniperFeeRecipientSet(pid, address(0), recipient);
        vm.prank(admin);
        hook.setSniperFeeRecipient(pk, recipient);
    }

    function test_factorySetSniperFeeRecipient_setsAndLocks() public {
        vm.prank(factory);
        hook.factorySetSniperFeeRecipient(pk, recipient, true);

        assertEq(hook.sniperFeeRecipient(pid), recipient);
        assertTrue(hook.sniperFeeRecipientLocked(pid));

        vm.prank(admin);
        vm.expectRevert(IArtCoinsHook.SniperFeeRecipientLockedErr.selector);
        hook.setSniperFeeRecipient(pk, makeAddr("other"));
    }

    function test_factorySetSniperFeeRecipient_revertsWhenLockingZero() public {
        vm.prank(factory);
        vm.expectRevert(IArtCoinsHook.InvalidSniperFeeConfig.selector);
        hook.factorySetSniperFeeRecipient(pk, address(0), true);
    }

    function test_factorySetSniperFeeRecipient_byNonFactory_reverts() public {
        vm.prank(makeAddr("notFactory"));
        vm.expectRevert(IArtCoinsHook.OnlyFactory.selector);
        hook.factorySetSniperFeeRecipient(pk, recipient, true);
    }

    // ─── lockSniperFeeRecipient — one-way, gates further sets ────────

    function test_lockSniperFeeRecipient_byAdmin_locksFurtherChanges() public {
        vm.prank(admin);
        hook.setSniperFeeRecipient(pk, recipient);
        vm.prank(admin);
        hook.lockSniperFeeRecipient(pk);
        assertTrue(hook.sniperFeeRecipientLocked(pid));

        // Subsequent set reverts.
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHook.SniperFeeRecipientLockedErr.selector);
        hook.setSniperFeeRecipient(pk, makeAddr("other"));
    }

    function test_lockSniperFeeRecipient_byNonAdmin_reverts() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.lockSniperFeeRecipient(pk);
    }

    function test_lockSniperFeeRecipient_doubleCall_reverts() public {
        vm.prank(admin);
        hook.lockSniperFeeRecipient(pk);
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHook.SniperFeeRecipientLockedErr.selector);
        hook.lockSniperFeeRecipient(pk);
    }

    function test_lockSniperFeeRecipient_emitsEvent() public {
        vm.expectEmit(true, false, false, false, address(hook));
        emit IArtCoinsHook.SniperFeeRecipientLockedEvt(pid);
        vm.prank(admin);
        hook.lockSniperFeeRecipient(pk);
    }

    // ─── mevModuleSetSniperFee — auth, no-op gates, storage write ────

    function test_mevModuleSetSniperFee_byBoundModule_storesValue() public {
        vm.prank(mevModuleAddr);
        hook.mevModuleSetSniperFee(pk, 490_000);
        assertEq(hook.currentSniperExtraFeePpm(pid), 490_000);
    }

    function test_mevModuleSetSniperFee_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit IArtCoinsHook.MevModuleSetSniperFee(pid, 240_000);
        vm.prank(mevModuleAddr);
        hook.mevModuleSetSniperFee(pk, 240_000);
    }

    function test_mevModuleSetSniperFee_byOther_reverts() public {
        vm.prank(makeAddr("notTheModule"));
        vm.expectRevert(IArtCoinsHook.Unauthorized.selector);
        hook.mevModuleSetSniperFee(pk, 100_000);
    }

    function test_mevModuleSetSniperFee_silentNoOpAfterDelayExpires() public {
        // Push past MAX_MEV_MODULE_DELAY (15 minutes). The hook silently no-ops
        // and disables the module — the call neither reverts nor stores.
        vm.warp(block.timestamp + 16 minutes);
        vm.prank(mevModuleAddr);
        hook.mevModuleSetSniperFee(pk, 100_000);
        assertEq(hook.currentSniperExtraFeePpm(pid), 0, "extra not stored");
        assertFalse(hook.mevModuleEnabled(pid), "module disabled on expiry");
    }

    function test_maxMevModuleDelayIsFifteenMinutes() public view {
        assertEq(hook.MAX_MEV_MODULE_DELAY(), 15 minutes);
    }

    function test_mevModuleSetSniperFee_silentNoOpAboveMaxFee() public {
        // MAX_MEV_LP_FEE is 990_000; values above are silently dropped.
        vm.prank(mevModuleAddr);
        hook.mevModuleSetSniperFee(pk, 999_999);
        assertEq(hook.currentSniperExtraFeePpm(pid), 0, "extra not stored");
    }

    function test_mevModuleSetSniperFee_silentNoOpWhenModuleNotEnabled() public {
        hook.testSetMevModuleEnabled(pk, false);
        vm.prank(mevModuleAddr);
        hook.mevModuleSetSniperFee(pk, 100_000);
        assertEq(hook.currentSniperExtraFeePpm(pid), 0);
    }

    // ─── Initial state — before any setup, everything is zero/false ────

    function test_initialState_unsetForFreshPool() public {
        PoolKey memory freshKey = PoolKey({
            currency0: Currency.wrap(makeAddr("c0fresh")),
            currency1: Currency.wrap(makeAddr("c1fresh")),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId freshId = freshKey.toId();
        assertEq(hook.sniperFeeRecipient(freshId), address(0));
        assertFalse(hook.sniperFeeRecipientLocked(freshId));
        assertEq(hook.currentSniperExtraFeePpm(freshId), 0);
        assertEq(hook.sniperExtraAccruedToken0(freshId), 0);
        assertEq(hook.sniperExtraAccruedToken1(freshId), 0);
    }

    // ─── Renounce-admin pattern: setters become uncallable ─────────────

    function test_renouncedAdmin_blocksRecipientChanges() public {
        token.setAdmin(address(0));
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.setSniperFeeRecipient(pk, recipient);
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.lockSniperFeeRecipient(pk);
    }
}
