// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {IArtCoinsPoolExtension} from "../src/hooks/interfaces/IArtCoinsPoolExtension.sol";
import {ArtCoinsHookStaticFeeV2} from "../src/hooks/legacy/ArtCoinsHookStaticFeeV2.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// Test subclass that skips Uniswap v4's address-flag validation so we can
/// `new TestableHook()` at any address. State seeders expose internals so
/// tests can drive `setPoolExtension` and `lockPoolExtension` directly
/// without spinning up a real PoolManager + LP locker.
contract TestableHook is ArtCoinsHookStaticFeeV2 {
    constructor(address pm, address f, address al, address weth)
        ArtCoinsHookStaticFeeV2(pm, f, al, weth)
    {}

    // Skip the BaseHook constructor's address-bits check — tests don't care.
    function validateHookAddress(BaseHook) internal pure override {}

    // Test seeders.
    function testSetArtCoinsIsToken0(PoolKey calldata pk, bool v) external {
        artCoinIsToken0[pk.toId()] = v;
    }

    function testSetLocker(PoolKey calldata pk, address l) external {
        locker[pk.toId()] = l;
    }

    function testSeedPoolExtension(PoolKey calldata pk, address ext, bool setupDone) external {
        poolExtension[pk.toId()] = ext;
        poolExtensionSetup[pk.toId()] = setupDone;
    }

    /// @notice Test-only wrapper that exposes the internal `_runPoolExtension`
    ///         dispatch helper. Lets tests verify the post-swap dispatch path
    ///         (which is what fires when a real Uniswap v4 swap completes)
    ///         without spinning up a full PoolManager.
    function testRunPoolExtension(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        address sender,
        BalanceDelta delta,
        bytes calldata swapData
    ) external {
        _runPoolExtension(poolKey, swapParams, sender, delta, swapData);
    }
}

/// Records every hook → extension callback for assertions, including the
/// exact swap params/delta/data passed by the hook on each `afterSwap`.
contract MockPoolExtension is IArtCoinsPoolExtension {
    bytes public lastInitData;
    address public lastLocker;
    bool public preCalled;
    bool public postCalled;

    uint256 public afterSwapCount;
    PoolId public lastPoolId;
    bool public lastZeroForOne;
    int256 public lastAmountSpecified;
    BalanceDelta public lastDelta;
    bool public lastNmIsToken0;
    bytes public lastSwapData;

    /// If set, `afterSwap` reverts. Used to test the hook's try/catch.
    bool public revertOnAfterSwap;

    function setRevertOnAfterSwap(bool b) external {
        revertOnAfterSwap = b;
    }

    function initializePreLockerSetup(PoolKey calldata, bool, bytes calldata data)
        external
        override
    {
        preCalled = true;
        lastInitData = data;
    }

    function initializePostLockerSetup(PoolKey calldata, address l, bool) external override {
        postCalled = true;
        lastLocker = l;
    }

    function afterSwap(
        PoolKey calldata pk,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bool nmIsToken0,
        bytes calldata data
    ) external override {
        if (revertOnAfterSwap) revert("extension reverted");
        afterSwapCount++;
        lastPoolId = PoolIdLibrary.toId(pk);
        lastZeroForOne = params.zeroForOne;
        lastAmountSpecified = params.amountSpecified;
        lastDelta = delta;
        lastNmIsToken0 = nmIsToken0;
        lastSwapData = data;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsPoolExtension).interfaceId;
    }
}

/// Stub of `ArtCoinsToken` that exposes only `admin()`. The hook's auth
/// modifier (`onlyTokenAdmin`) reads it via `ArtCoinsToken(token).admin()`.
contract MockTokenAdmin {
    address private _admin;

    function setAdmin(address a) external {
        _admin = a;
    }

    function admin() external view returns (address) {
        return _admin;
    }
}

/// Stub factory: the hook's allowlist gate uses `ArtCoinsPoolExtensionAllowlist`
/// directly, so the factory only needs to be constructable + own the allowlist.
/// We pass `address(this)` as the test contract so `Ownable(factory).owner()`
/// behaves predictably if any other path consults it (it doesn't here).
contract LoneOwner {
    address public owner;

    constructor() {
        owner = msg.sender;
    }
}

contract HookSetPoolExtensionTest is Test {
    using PoolIdLibrary for PoolKey;

    TestableHook internal hook;
    ArtCoinsPoolExtensionAllowlist internal allowlist;
    MockTokenAdmin internal token;
    MockPoolExtension internal extA;
    MockPoolExtension internal extB;

    address internal admin = makeAddr("admin");
    address internal locker = makeAddr("locker");

    PoolKey internal pk;
    PoolId internal pid;

    function setUp() public {
        // Allowlist owner = this test contract.
        allowlist = new ArtCoinsPoolExtensionAllowlist(address(this));
        // Pool manager + factory + weth can be any address — the new code
        // we're testing doesn't reach them.
        hook = new TestableHook(
            address(0x1234), // pool manager (unused in tests)
            address(0x5678), // factory (unused)
            address(allowlist),
            address(0x9abc) // weth (unused)
        );

        token = new MockTokenAdmin();
        token.setAdmin(admin);

        extA = new MockPoolExtension();
        extB = new MockPoolExtension();
        allowlist.setPoolExtension(address(extA), true);
        allowlist.setPoolExtension(address(extB), true);

        // Build a pool key with the mock token as currency0.
        address paired = makeAddr("paired");
        if (uint160(address(token)) > uint160(paired)) {
            (paired,) = (address(token), paired);
        }
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
        hook.testSetLocker(pk, locker);
        hook.testSeedPoolExtension(pk, address(extA), true);
    }

    // ─── setPoolExtension auth ─────────────────────────────────────────

    function test_setPoolExtension_byAdmin_succeeds() public {
        vm.prank(admin);
        hook.setPoolExtension(pk, address(extB), "");
        assertEq(hook.poolExtension(pid), address(extB));
        assertTrue(hook.poolExtensionSetup(pid));
    }

    function test_setPoolExtension_byNonAdmin_reverts() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.setPoolExtension(pk, address(extB), "");
    }

    function test_setPoolExtension_revertsForNonAllowlistedExtension() public {
        MockPoolExtension rogue = new MockPoolExtension();
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHook.PoolExtensionNotEnabled.selector);
        hook.setPoolExtension(pk, address(rogue), "");
    }

    function test_setPoolExtension_zeroAddressClearsSlot() public {
        vm.prank(admin);
        hook.setPoolExtension(pk, address(0), "");
        assertEq(hook.poolExtension(pid), address(0));
        assertFalse(hook.poolExtensionSetup(pid));
    }

    // ─── setPoolExtension forwards to extension's init callbacks ─────

    function test_setPoolExtension_callsBothInitCallbacks() public {
        bytes memory initData = hex"deadbeef";
        vm.prank(admin);
        hook.setPoolExtension(pk, address(extB), initData);
        assertTrue(extB.preCalled());
        assertTrue(extB.postCalled());
        assertEq(extB.lastLocker(), locker);
        assertEq(extB.lastInitData(), initData);
    }

    function test_setPoolExtension_doesNotCallNewExtensionWhenZero() public {
        // Cleared → no calls on extA either way.
        uint256 prePreA = extA.preCalled() ? 1 : 0;
        vm.prank(admin);
        hook.setPoolExtension(pk, address(0), "");
        // No mock call assertions to make for "nothing was called" — just
        // confirm extA didn't get a spurious init call as a result.
        assertEq(extA.preCalled() ? 1 : 0, prePreA);
    }

    // ─── Event ────────────────────────────────────────────────────────

    function test_setPoolExtension_emitsEvent() public {
        vm.expectEmit(true, true, true, false, address(hook));
        emit IArtCoinsHook.PoolExtensionSwapped(pid, address(extA), address(extB));
        vm.prank(admin);
        hook.setPoolExtension(pk, address(extB), "");
    }

    // ─── lockPoolExtension ───────────────────────────────────────────

    function test_lockPoolExtension_byAdmin_locksFurtherChanges() public {
        vm.prank(admin);
        hook.lockPoolExtension(pk);
        assertTrue(hook.poolExtensionLocked(pid));

        vm.prank(admin);
        vm.expectRevert(IArtCoinsHook.PoolExtensionLockedErr.selector);
        hook.setPoolExtension(pk, address(extB), "");
    }

    function test_lockPoolExtension_byNonAdmin_reverts() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.lockPoolExtension(pk);
    }

    function test_lockPoolExtension_emitsEvent() public {
        vm.expectEmit(true, false, false, false, address(hook));
        emit IArtCoinsHook.PoolExtensionLockedEvt(pid);
        vm.prank(admin);
        hook.lockPoolExtension(pk);
    }

    function test_lockPoolExtension_doubleCall_reverts() public {
        vm.prank(admin);
        hook.lockPoolExtension(pk);
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHook.PoolExtensionLockedErr.selector);
        hook.lockPoolExtension(pk);
    }

    // ─── Renounce-admin pattern (admin → 0x0) ────────────────────────

    function test_renouncedAdmin_disablesSetter() public {
        token.setAdmin(address(0));
        // Now nobody can call as admin (msg.sender can't equal 0x0).
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.setPoolExtension(pk, address(extB), "");
    }

    // ─── Swap-dispatch path ────────────────────────────────────────────
    //
    // These tests exercise `_runPoolExtension`, the helper the hook calls at
    // the end of every real Uniswap v4 swap. They prove that when an
    // afterSwap fires on the hook, the bound extension's afterSwap is called
    // with the exact swap params, balance delta, nm-is-token0 flag, and
    // swap-data the hook received. The full path under a real PoolManager
    // adds protocol fee accounting on top of this dispatch but doesn't
    // change which extension is called or what args it gets — that's all
    // here in `_runPoolExtension`.

    /// Build the swap-data envelope the hook expects: a `PoolSwapData` struct
    /// whose `poolExtensionSwapData` field is what gets forwarded.
    function _swapData(bytes memory ext) internal pure returns (bytes memory) {
        return
            abi.encode(
                IArtCoinsHook.PoolSwapData({mevModuleSwapData: "", poolExtensionSwapData: ext})
            );
    }

    function _params(bool zeroForOne, int256 amount)
        internal
        pure
        returns (IPoolManager.SwapParams memory)
    {
        return IPoolManager.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: 0
        });
    }

    function test_swapDispatch_extensionGetsCalledWithSwapArgs() public {
        IPoolManager.SwapParams memory params = _params(false, -1 ether);
        BalanceDelta delta = toBalanceDelta(int128(0), int128(1));
        bytes memory extData = hex"feedface";

        hook.testRunPoolExtension(pk, params, makeAddr("trader"), delta, _swapData(extData));

        assertEq(MockPoolExtension(address(extA)).afterSwapCount(), 1);
        assertEq(PoolId.unwrap(extA.lastPoolId()), PoolId.unwrap(pid));
        assertEq(extA.lastZeroForOne(), false);
        assertEq(extA.lastAmountSpecified(), -1 ether);
        assertEq(extA.lastSwapData(), extData);
        // nmIsToken0 should match the hook's mapping.
        assertEq(extA.lastNmIsToken0(), hook.artCoinIsToken0(pid));
    }

    function test_swapDispatch_skipsWhenExtensionUnset() public {
        // Clear the extension via the new admin setter.
        vm.prank(admin);
        hook.setPoolExtension(pk, address(0), "");

        hook.testRunPoolExtension(
            pk, _params(true, -1 ether), makeAddr("trader"), toBalanceDelta(0, 0), _swapData("")
        );

        assertEq(extA.afterSwapCount(), 0);
    }

    function test_swapDispatch_skipsWhenExtensionSetupNotDone() public {
        // `_runPoolExtension` requires both an extension AND poolExtensionSetup=true.
        // Seed an extension but with setupDone=false (e.g. mid-init).
        hook.testSeedPoolExtension(pk, address(extB), false);
        hook.testRunPoolExtension(
            pk, _params(true, -1 ether), makeAddr("trader"), toBalanceDelta(0, 0), _swapData("")
        );
        assertEq(extB.afterSwapCount(), 0);
    }

    function test_swapDispatch_skipsWhenSenderIsLocker() public {
        // The hook intentionally skips dispatch when the swap sender is the
        // locker, so locker-initiated fee-claim swaps don't double-count
        // through the extension. Simulate by passing locker as `sender`.
        hook.testRunPoolExtension(
            pk, _params(true, -1 ether), locker, toBalanceDelta(0, 0), _swapData("")
        );
        assertEq(extA.afterSwapCount(), 0);
    }

    function test_swapDispatch_revertingExtensionDoesNotBreakDispatch() public {
        // Reverting extension is wrapped in try/catch — dispatch returns
        // normally and the swap can complete. This is the safety property
        // that lets us trust extensions can be swapped to potentially-buggy
        // ones without bricking trading.
        extA.setRevertOnAfterSwap(true);
        // Should not revert.
        hook.testRunPoolExtension(
            pk, _params(false, -1 ether), makeAddr("trader"), toBalanceDelta(0, 0), _swapData("")
        );
        // Extension was called, but its state-recording branch never ran
        // (it reverted before the increment).
        assertEq(extA.afterSwapCount(), 0);
    }

    function test_swapDispatch_emitsSuccessEvent() public {
        vm.expectEmit(false, false, false, true, address(hook));
        emit IArtCoinsHook.PoolExtensionSuccess(pid);
        hook.testRunPoolExtension(
            pk, _params(false, -1 ether), makeAddr("trader"), toBalanceDelta(0, 0), _swapData("")
        );
    }

    function test_swapDispatch_emitsFailedEventOnRevert() public {
        extA.setRevertOnAfterSwap(true);
        vm.expectEmit(false, false, false, true, address(hook));
        emit IArtCoinsHook.PoolExtensionFailed(pid, _params(true, -1 ether));
        hook.testRunPoolExtension(
            pk, _params(true, -1 ether), makeAddr("trader"), toBalanceDelta(0, 0), _swapData("")
        );
    }

    /// End-to-end: swap before the setter swap, verify dispatch goes to extA;
    /// swap to extB via the new setter; then swap and verify dispatch goes
    /// to extB. This is the integration of the new mutator with the hook's
    /// per-swap dispatch path.
    function test_swapDispatch_routesToNewExtensionAfterSetPoolExtension() public {
        // First swap → extA increments.
        hook.testRunPoolExtension(
            pk, _params(false, -1 ether), makeAddr("trader"), toBalanceDelta(0, 0), _swapData("")
        );
        assertEq(extA.afterSwapCount(), 1);

        // Admin swaps to extB.
        vm.prank(admin);
        hook.setPoolExtension(pk, address(extB), "");

        // Next swap → extB increments, extA stays at 1.
        hook.testRunPoolExtension(
            pk, _params(false, -1 ether), makeAddr("trader"), toBalanceDelta(0, 0), _swapData("")
        );
        assertEq(extA.afterSwapCount(), 1);
        assertEq(extB.afterSwapCount(), 1);
    }

    function test_swapDispatch_decodesEmptySwapDataGracefully() public {
        // `_runPoolExtension` permits empty swapData (uses default empty
        // poolExtensionSwapData). Should not revert; extension's
        // `lastSwapData` should be empty bytes.
        hook.testRunPoolExtension(
            pk, _params(false, -1 ether), makeAddr("trader"), toBalanceDelta(0, 0), ""
        );
        assertEq(extA.afterSwapCount(), 1);
        assertEq(extA.lastSwapData(), "");
    }
}
