// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {ArtCoinsHookSkimFeeBase} from "../src/hooks/ArtCoinsHookSkimFee.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {IArtCoinsHookSkimFee} from "../src/hooks/interfaces/IArtCoinsHookSkimFee.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {IArtCoinsMevModuleBase} from "../src/interfaces/IArtCoinsMevModuleBase.sol";
import {IArtCoinsMevSkim} from "../src/mev-modules/interfaces/IArtCoinsMevSkim.sol";

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @notice Subclass that bypasses v4 address-flag validation so we can deploy
///         at any address. Exposes thin setters / helpers for direct state
///         manipulation in unit tests.
contract TestableHookSkimFee is ArtCoinsHookSkimFeeBase {
    constructor(address pm, address f, address al, address weth, address esc)
        ArtCoinsHookSkimFeeBase(pm, f, al, weth, esc)
    {}

    function validateHookAddress(BaseHook) internal pure override {}

    function testSetMevModule(PoolKey calldata pk, address m) external {
        mevModule[pk.toId()] = m;
        mevModuleEnabled[pk.toId()] = m != address(0);
    }

    function testSetPoolCreationTimestamp(PoolKey calldata pk, uint256 t) external {
        poolCreationTimestamp[pk.toId()] = t;
    }

    /// @notice Exposes `_initializeFeeData` so we can drive the init-data
    ///         path in isolation (without spinning up a PoolManager).
    function testInitializeFeeData(PoolKey calldata pk, bytes calldata feeData) external {
        _initializeFeeData(pk, feeData);
    }

    /// @notice Exposes the internal skim-amounts math for unit tests.
    function testSkimAmounts(
        PoolKey calldata pk,
        uint24 baselineBps,
        uint256 primarySide,
        bool isExactInput
    ) external view returns (uint256 totalSkim, uint256 baselineSkim, uint256 extra) {
        return _skimAmounts(pk.toId(), baselineBps, primarySide, isExactInput);
    }

    /// @notice Exposes the clamping helper.
    function testCurrentSkimBpsClamped(PoolKey calldata pk, uint24 baseline)
        external
        view
        returns (uint24)
    {
        return _currentSkimBpsClamped(pk.toId(), baseline);
    }

    /// @notice Drives the REAL `_beforeAddLiquidity` (not a reimplementation),
    ///         so this unit test can never silently diverge from the hook's
    ///         actual liquidity-lock logic. The prior harness hand-copied that
    ///         logic and, in doing so, could not reproduce the side-effecting
    ///         `mevModuleOperational` flag-flip that shrank the lock window —
    ///         which is exactly how that bug stayed untested. Routes through an
    ///         external self-call so the zero-value params arrive as calldata.
    function testBeforeAddLiquidity(PoolKey calldata pk) external view returns (bytes4) {
        IPoolManager.ModifyLiquidityParams memory p; // zero-value
        return this.exposedBeforeAddLiquidity(address(0), pk, p, "");
    }

    function exposedBeforeAddLiquidity(
        address sender,
        PoolKey calldata pk,
        IPoolManager.ModifyLiquidityParams calldata p,
        bytes calldata data
    ) external view returns (bytes4) {
        if (msg.sender != address(this)) revert("only self");
        return _beforeAddLiquidity(sender, pk, p, data);
    }
}

/// @notice Stand-in for an ArtCoinsToken whose `admin()` getter is the only
///         thing the hook's `onlyTokenAdmin` modifier actually reads. Letting
///         tests configure the admin directly avoids spinning up the factory.
contract MockTokenAdmin {
    address public admin;

    function setAdmin(address a) external {
        admin = a;
    }
}

/// @notice Stub MEV-skim module — tests dial `currentSkimBps` / `operational`
///         directly.
contract MockMevSkim is IArtCoinsMevSkim {
    uint24 internal _bps;
    bool internal _op;
    bool internal _revertOnCurrent;
    bool internal _revertOnOperational;

    function setBps(uint24 v) external {
        _bps = v;
    }

    function setOperational(bool v) external {
        _op = v;
    }

    function setRevertOnCurrent(bool v) external {
        _revertOnCurrent = v;
    }

    function setRevertOnOperational(bool v) external {
        _revertOnOperational = v;
    }

    function currentSkimBps(PoolId) external view override returns (uint24) {
        if (_revertOnCurrent) revert("mock revert");
        return _bps;
    }

    function operational(PoolId) external view override returns (bool) {
        if (_revertOnOperational) revert("mock revert");
        return _op;
    }

    function initialize(PoolKey calldata, bytes calldata) external override {}

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IArtCoinsMevModuleBase).interfaceId
            || interfaceId == type(IArtCoinsMevSkim).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Recipient that always reverts on ETH receive (for held-skim tests).
contract RejectingRecipient {
    receive() external payable {
        revert("nope");
    }
}

/// @notice IReferralPayoutForHook stub that accepts notifies and records
///         per-referrer receipts.
contract MockReferralPayout {
    mapping(address => uint256) public received;

    function notify(address referrer) external payable {
        received[referrer] += msg.value;
    }
    receive() external payable {}
}

/// @notice IReferralPayoutForHook stub that always reverts on notify (for
///         held-referral re-hold tests).
contract RejectingReferralPayout {
    function notify(address) external payable {
        revert("nope");
    }
}

contract ArtCoinsHookSkimFeeUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    TestableHookSkimFee internal hook;
    ArtCoinsPoolExtensionAllowlist internal allowlist;
    MockTokenAdmin internal token;
    MockMevSkim internal module;

    address internal admin = makeAddr("admin");
    address payable internal bountyRecipient = payable(makeAddr("bountyRecipient"));
    address payable internal protocolRecipient = payable(makeAddr("protocolRecipient"));
    address payable internal referralPayout = payable(makeAddr("referralPayout"));
    address internal factory = makeAddr("factory");

    PoolKey internal pk;
    PoolId internal pid;

    uint24 constant BASELINE_BPS = 5000; // 5% of trader cost
    uint16 constant BOUNTY_BPS = 8000; // 80% of baseline → bounty
    uint24 constant MAX_REF_BPS = 500; // 0.5% of volume (50% of cap)
    uint24 constant LP_FEE_PPM = 10_000; // 1%

    function setUp() public {
        allowlist = new ArtCoinsPoolExtensionAllowlist(address(this));
        hook = new TestableHookSkimFee(
            makeAddr("pm"), factory, address(allowlist), makeAddr("weth"), makeAddr("feeEscrow")
        );

        token = new MockTokenAdmin();
        token.setAdmin(admin);
        module = new MockMevSkim();

        // Native-ETH paired: currency0 == address(0), currency1 == token.
        pk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        pid = pk.toId();
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _validInit(uint24 maxRefBps) internal view returns (bytes memory) {
        return abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: maxRefBps,
                lpFee: LP_FEE_PPM,
                bountyRecipient: bountyRecipient,
                protocolRecipient: protocolRecipient,
                referralPayout: referralPayout,
                quoteToken: address(0) // native ETH = currency0
            })
        );
    }

    function _validInitBytes() internal view returns (bytes memory) {
        return _validInit(MAX_REF_BPS);
    }

    function _getMaxReferralBps() internal view returns (uint24) {
        (,, uint24 maxRefBps,,,,,) = hook.skimConfig(pid);
        return maxRefBps;
    }

    // ─── initializePoolOpen ── token-must-exist guard ────────────────────

    /// @notice `initializePoolOpen` must reject an `artCoin` with no code. This
    ///         blocks pre-creating a pool for a predicted, not-yet-deployed
    ///         CREATE2 token address, which would make the factory's own later
    ///         initialization of that pool revert `PoolAlreadyInitialized` and
    ///         brick the token's launch. The guard runs before any PoolManager
    ///         interaction, so the stubbed PM in this unit fixture is never
    ///         reached.
    function test_initializePoolOpen_revertsForNotYetDeployedToken() public {
        address ghost = makeAddr("ghostToken"); // EOA label → no code
        assertEq(ghost.code.length, 0, "precondition: ghost token has no code");
        vm.expectRevert(IArtCoinsHook.ArtCoinNotDeployed.selector);
        hook.initializePoolOpen(ghost, address(0), int24(-190_400), int24(200), _validInitBytes());
    }

    // ─── _initializeFeeData ── validation ────────────────────────────────

    function test_initializeFeeData_storesConfig() public {
        hook.testInitializeFeeData(pk, _validInitBytes());

        (
            uint24 b,
            uint16 bb,
            uint24 maxRef,
            uint24 lp,
            address payable br,
            address payable pr,
            address payable rp,
            address quote
        ) = hook.skimConfig(pid);
        assertEq(b, BASELINE_BPS);
        assertEq(bb, BOUNTY_BPS);
        assertEq(maxRef, MAX_REF_BPS);
        assertEq(lp, LP_FEE_PPM);
        assertEq(br, bountyRecipient);
        assertEq(pr, protocolRecipient);
        assertEq(rp, referralPayout);
        assertEq(quote, address(0));
    }

    function test_initializeFeeData_revertsOnLpFeeTooHigh() public {
        bytes memory data = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: MAX_REF_BPS,
                lpFee: 1_000_000, // > MAX_LP_FEE (100_000)
                bountyRecipient: bountyRecipient,
                protocolRecipient: protocolRecipient,
                referralPayout: referralPayout,
                quoteToken: address(0)
            })
        );
        vm.expectRevert(IArtCoinsHookSkimFee.LpFeeTooHigh.selector);
        hook.testInitializeFeeData(pk, data);
    }

    function test_initializeFeeData_revertsOnBaselineTooHigh() public {
        bytes memory data = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: 90_001, // > MAX_SKIM_BPS
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: MAX_REF_BPS,
                lpFee: LP_FEE_PPM,
                bountyRecipient: bountyRecipient,
                protocolRecipient: protocolRecipient,
                referralPayout: referralPayout,
                quoteToken: address(0)
            })
        );
        vm.expectRevert(IArtCoinsHookSkimFee.BaselineSkimBpsTooHigh.selector);
        hook.testInitializeFeeData(pk, data);
    }

    function test_initializeFeeData_revertsOnBadLegBps() public {
        // bountyBps >= BPS_DENOMINATOR (10_000) → no slice for protocol.
        bytes memory data = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: 10_000, // exactly equal — no protocol slice
                maxReferralBpsOfVolume: MAX_REF_BPS,
                lpFee: LP_FEE_PPM,
                bountyRecipient: bountyRecipient,
                protocolRecipient: protocolRecipient,
                referralPayout: referralPayout,
                quoteToken: address(0)
            })
        );
        vm.expectRevert(IArtCoinsHookSkimFee.BadLegBps.selector);
        hook.testInitializeFeeData(pk, data);
    }

    function test_initializeFeeData_revertsOnMaxRefTooHigh() public {
        bytes memory data = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: 1001, // > MAX_REFERRAL_CAP_OF_VOLUME (1_000)
                lpFee: LP_FEE_PPM,
                bountyRecipient: bountyRecipient,
                protocolRecipient: protocolRecipient,
                referralPayout: referralPayout,
                quoteToken: address(0)
            })
        );
        vm.expectRevert(IArtCoinsHookSkimFee.MaxReferralTooHigh.selector);
        hook.testInitializeFeeData(pk, data);
    }

    function test_initializeFeeData_acceptsZeroMaxRef() public {
        // Launching with referrals fully disabled (PC's default at v1 launch).
        hook.testInitializeFeeData(pk, _validInit(0));
        assertEq(_getMaxReferralBps(), 0);
    }

    function test_initializeFeeData_revertsOnZeroBountyRecipient() public {
        bytes memory data = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: MAX_REF_BPS,
                lpFee: LP_FEE_PPM,
                bountyRecipient: payable(address(0)),
                protocolRecipient: protocolRecipient,
                referralPayout: referralPayout,
                quoteToken: address(0)
            })
        );
        vm.expectRevert(IArtCoinsHookSkimFee.BountyRecipientZero.selector);
        hook.testInitializeFeeData(pk, data);
    }

    function test_initializeFeeData_revertsOnZeroProtocolRecipient() public {
        bytes memory data = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: MAX_REF_BPS,
                lpFee: LP_FEE_PPM,
                bountyRecipient: bountyRecipient,
                protocolRecipient: payable(address(0)),
                referralPayout: referralPayout,
                quoteToken: address(0)
            })
        );
        vm.expectRevert(IArtCoinsHookSkimFee.ProtocolRecipientZero.selector);
        hook.testInitializeFeeData(pk, data);
    }

    function test_initializeFeeData_revertsOnZeroReferralPayout() public {
        bytes memory data = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: MAX_REF_BPS,
                lpFee: LP_FEE_PPM,
                bountyRecipient: bountyRecipient,
                protocolRecipient: protocolRecipient,
                referralPayout: payable(address(0)),
                quoteToken: address(0)
            })
        );
        vm.expectRevert(IArtCoinsHookSkimFee.ReferralPayoutZero.selector);
        hook.testInitializeFeeData(pk, data);
    }

    function test_initializeFeeData_revertsOnQuoteMismatch() public {
        bytes memory data = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: MAX_REF_BPS,
                lpFee: LP_FEE_PPM,
                bountyRecipient: bountyRecipient,
                protocolRecipient: protocolRecipient,
                referralPayout: referralPayout,
                quoteToken: makeAddr("not-in-pool")
            })
        );
        vm.expectRevert(IArtCoinsHookSkimFee.QuoteTokenMismatch.selector);
        hook.testInitializeFeeData(pk, data);
    }

    function test_initializeFeeData_revertsOnNonNativeQuoteToken() public {
        bytes memory data = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: MAX_REF_BPS,
                lpFee: LP_FEE_PPM,
                bountyRecipient: bountyRecipient,
                protocolRecipient: protocolRecipient,
                referralPayout: referralPayout,
                quoteToken: address(token) // currency1
            })
        );
        vm.expectRevert(IArtCoinsHookSkimFee.QuoteTokenMustBeNative.selector);
        hook.testInitializeFeeData(pk, data);
    }

    // ─── setMaxReferralBpsOfVolume ───────────────────────────────────────

    function test_setMaxRef_updatesValue() public {
        hook.testInitializeFeeData(pk, _validInit(0));
        assertEq(_getMaxReferralBps(), 0);

        vm.prank(admin);
        hook.setMaxReferralBpsOfVolume(pk, 500);
        assertEq(_getMaxReferralBps(), 500);

        vm.prank(admin);
        hook.setMaxReferralBpsOfVolume(pk, 1000);
        assertEq(_getMaxReferralBps(), 1000);
    }

    function test_setMaxRef_emitsEvent() public {
        hook.testInitializeFeeData(pk, _validInit(0));
        vm.expectEmit(true, false, false, true, address(hook));
        emit IArtCoinsHookSkimFee.MaxReferralBpsUpdated(pid, 750);
        vm.prank(admin);
        hook.setMaxReferralBpsOfVolume(pk, 750);
    }

    function test_setMaxRef_acceptsBoundaryValues() public {
        hook.testInitializeFeeData(pk, _validInit(0));

        // Lower bound: 0 (disabled).
        vm.prank(admin);
        hook.setMaxReferralBpsOfVolume(pk, 0);
        assertEq(_getMaxReferralBps(), 0);

        // Upper bound: 1_000 (1% of volume).
        vm.prank(admin);
        hook.setMaxReferralBpsOfVolume(pk, 1000);
        assertEq(_getMaxReferralBps(), 1000);
    }

    function test_setMaxRef_revertsAboveCap() public {
        hook.testInitializeFeeData(pk, _validInit(0));
        vm.prank(admin);
        vm.expectRevert(IArtCoinsHookSkimFee.MaxReferralTooHigh.selector);
        hook.setMaxReferralBpsOfVolume(pk, 1001);
    }

    function test_setMaxRef_revertsForNonAdmin() public {
        hook.testInitializeFeeData(pk, _validInit(0));
        vm.prank(makeAddr("not-admin"));
        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.setMaxReferralBpsOfVolume(pk, 500);
    }

    function test_setMaxRef_duplicateValueIsAllowed() public {
        // Calling with the existing value is a permitted no-op-shaped update:
        // storage stays the same, but the event still fires (deterministic
        // signal for off-chain consumers). No revert path on duplicates.
        hook.testInitializeFeeData(pk, _validInit(500));
        assertEq(_getMaxReferralBps(), 500);

        vm.expectEmit(true, false, false, true, address(hook));
        emit IArtCoinsHookSkimFee.MaxReferralBpsUpdated(pid, 500);
        vm.prank(admin);
        hook.setMaxReferralBpsOfVolume(pk, 500);
        assertEq(_getMaxReferralBps(), 500);
    }

    function test_setMaxRef_followsAdminRotation() public {
        // After token admin is rotated, the new admin gates pass and the
        // old admin's calls revert. Mirrors PC's TokenAdminPoker handoff.
        hook.testInitializeFeeData(pk, _validInit(0));
        address newAdmin = makeAddr("newAdmin");
        token.setAdmin(newAdmin);

        vm.prank(admin); // the old admin
        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.setMaxReferralBpsOfVolume(pk, 500);

        vm.prank(newAdmin);
        hook.setMaxReferralBpsOfVolume(pk, 500);
        assertEq(_getMaxReferralBps(), 500);
    }

    function test_setMaxRef_zeroAdminRenouncesGate() public {
        // After admin is renounced to address(0), no caller can pass the gate.
        hook.testInitializeFeeData(pk, _validInit(500));
        token.setAdmin(address(0));

        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.setMaxReferralBpsOfVolume(pk, 700);

        // Existing value is frozen at whatever the last successful set wrote.
        assertEq(_getMaxReferralBps(), 500);
    }

    // ─── _skimAmounts ── math (exactInput) ───────────────────────────────

    function test_skimAmounts_exactInput_baselineOnly() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        // No module bound → totalBps = baseline = 5_000
        (uint256 total, uint256 base, uint256 extra) =
            hook.testSkimAmounts(pk, BASELINE_BPS, 100 ether, true);
        // 5% of 100 ETH = 5 ETH
        assertEq(total, 5 ether);
        assertEq(base, 5 ether);
        assertEq(extra, 0);
    }

    function test_skimAmounts_exactInput_duringMev() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        hook.testSetMevModule(pk, address(module));
        module.setBps(68_690); // ~69% effective trader cost at t=0
        module.setOperational(true);

        (uint256 total, uint256 base, uint256 extra) =
            hook.testSkimAmounts(pk, BASELINE_BPS, 1 ether, true);

        // total = 68_690 / 100_000 of 1 ETH = 0.6869 ETH
        assertEq(total, 0.6869 ether);
        // baseline = 5_000 / 100_000 of 1 ETH = 0.05 ETH
        assertEq(base, 0.05 ether);
        assertEq(extra, total - base);
        assertEq(base + extra, total, "splits sum to total");
    }

    function test_skimAmounts_exactInput_zeroPrimary() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        (uint256 total, uint256 base, uint256 extra) =
            hook.testSkimAmounts(pk, BASELINE_BPS, 0, true);
        assertEq(total, 0);
        assertEq(base, 0);
        assertEq(extra, 0);
    }

    function test_skimAmounts_exactInput_zeroBaselineAndNoModule_noSkim() public {
        bytes memory data = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: 0,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: 0,
                lpFee: LP_FEE_PPM,
                bountyRecipient: bountyRecipient,
                protocolRecipient: protocolRecipient,
                referralPayout: referralPayout,
                quoteToken: address(0)
            })
        );
        hook.testInitializeFeeData(pk, data);
        (uint256 total, uint256 base, uint256 extra) = hook.testSkimAmounts(pk, 0, 1 ether, true);
        assertEq(total, 0);
        assertEq(base, 0);
        assertEq(extra, 0);
    }

    // ─── _skimAmounts ── math (exactOutput / gross-up) ───────────────────

    function test_skimAmounts_exactOutput_baselineOnly() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        // trader wants 1 ETH out; skim = 5_000 * 1e18 / (100_000 - 5_000)
        (uint256 total, uint256 base, uint256 extra) =
            hook.testSkimAmounts(pk, BASELINE_BPS, 1 ether, false);

        uint256 expected = uint256(1 ether) * 5000 / (100_000 - 5000);
        assertEq(total, expected);
        assertEq(base, expected);
        assertEq(extra, 0);
    }

    function test_skimAmounts_exactOutput_duringMev() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        hook.testSetMevModule(pk, address(module));
        module.setBps(50_000); // 50%
        module.setOperational(true);

        (uint256 total, uint256 base, uint256 extra) =
            hook.testSkimAmounts(pk, BASELINE_BPS, 1 ether, false);

        uint256 expectedTotal = uint256(1 ether) * 50_000 / (100_000 - 50_000);
        assertEq(total, expectedTotal);
        uint256 expectedBase = uint256(1 ether) * 5000 / (100_000 - 50_000);
        assertEq(base, expectedBase);
        assertEq(extra, expectedTotal - expectedBase);
    }

    // ─── _currentSkimBpsClamped ──────────────────────────────────────────

    function test_currentSkimBpsClamped_noModule_returnsBaseline() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        assertEq(hook.testCurrentSkimBpsClamped(pk, BASELINE_BPS), BASELINE_BPS);
    }

    function test_currentSkimBpsClamped_clampsAboveMax() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        hook.testSetMevModule(pk, address(module));
        module.setBps(95_000); // Above MAX_SKIM_BPS=90_000
        assertEq(hook.testCurrentSkimBpsClamped(pk, BASELINE_BPS), 90_000);
    }

    function test_currentSkimBpsClamped_flooredAtBaseline() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        hook.testSetMevModule(pk, address(module));
        module.setBps(1000); // Below baseline (5_000)
        assertEq(hook.testCurrentSkimBpsClamped(pk, BASELINE_BPS), BASELINE_BPS);
    }

    function test_currentSkimBpsClamped_returnsModuleValueInRange() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        hook.testSetMevModule(pk, address(module));
        module.setBps(30_000);
        assertEq(hook.testCurrentSkimBpsClamped(pk, BASELINE_BPS), 30_000);
    }

    function test_currentSkimBpsClamped_failsClosedToBaseline() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        hook.testSetMevModule(pk, address(module));
        module.setRevertOnCurrent(true);
        // Module reverts → fall back to baseline only.
        assertEq(hook.testCurrentSkimBpsClamped(pk, BASELINE_BPS), BASELINE_BPS);
    }

    // ─── _beforeAddLiquidity ─────────────────────────────────────────────

    function test_beforeAddLiquidity_revertsDuringMevWindow() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        hook.testSetMevModule(pk, address(module));
        module.setOperational(true);

        vm.expectRevert(IArtCoinsHook.MevModuleEnabled.selector);
        hook.testBeforeAddLiquidity(pk);
    }

    function test_beforeAddLiquidity_allowsAfterMevWindow() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        hook.testSetMevModule(pk, address(module));
        module.setOperational(false);
        hook.testBeforeAddLiquidity(pk); // returns without revert
    }

    function test_beforeAddLiquidity_noModule_allows() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        hook.testBeforeAddLiquidity(pk);
    }

    /// @notice Regression: the public-LP lock holds for the WHOLE skim window,
    ///         even after the base hook's generic 15-min gate has expired and
    ///         cleared `mevModuleEnabled` (as the first swap past 15m would via
    ///         `_runMevModule`). Pre-fix, that flag-flip made
    ///         `_beforeAddLiquidity` fall through and ALLOW adds mid-window,
    ///         silently shrinking the documented ~69m lock to ~15m. The lock
    ///         now keys solely on the skim module's `operational()`.
    function test_beforeAddLiquidity_locksFullSkimWindow_afterGenericGateExpiry() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        hook.testSetMevModule(pk, address(module)); // sets mevModuleEnabled = true
        hook.testSetPoolCreationTimestamp(pk, block.timestamp);
        module.setOperational(true); // skim decay window still open

        // Advance past the generic 15-min cap and trigger the side-effecting
        // `mevModuleOperational`, which clears `mevModuleEnabled` exactly as the
        // first swap past the cap would.
        vm.warp(block.timestamp + hook.MAX_MEV_MODULE_DELAY() + 1 minutes);
        assertFalse(hook.mevModuleOperational(pk.toId()), "generic gate expired");
        assertFalse(hook.mevModuleEnabled(pk.toId()), "generic flag cleared");

        // Skim module is still operational → the lock MUST still hold.
        vm.expectRevert(IArtCoinsHook.MevModuleEnabled.selector);
        hook.testBeforeAddLiquidity(pk);
    }

    /// @notice Fail-open: a bound module whose `operational()` reverts (a
    ///         non-skim / misconfigured module — the production module's is a
    ///         pure storage read that never reverts) imposes no lock rather
    ///         than permanently bricking liquidity.
    function test_beforeAddLiquidity_failOpen_whenModuleReverts() public {
        hook.testInitializeFeeData(pk, _validInitBytes());
        hook.testSetMevModule(pk, address(module));
        module.setRevertOnOperational(true);
        hook.testBeforeAddLiquidity(pk); // returns without revert
    }
    // ─── Constants ───────────────────────────────────────────────────────

    function test_constants() public view {
        assertEq(hook.MAX_SKIM_BPS(), 90_000);
        assertEq(hook.MAX_REFERRAL_CAP_OF_VOLUME(), 1000);
        assertEq(hook.SKIM_DENOMINATOR(), 100_000);
        assertEq(hook.BPS_DENOMINATOR(), 10_000);
    }
}
