// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IConstantsBound} from "./IConstantsBound.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IArtCoinsHookV2
/// @notice Skim fee hook for v2 art coin pools (native eth paired). Pools are
///         created only by allowlisted launchers. Per pool values are written
///         once at init; the coin admin may later change the bounty recipient.
///         Fee legs are pushed with a zero gas call and fall back to the fee
///         escrow.
interface IArtCoinsHookV2 is IConstantsBound {
    // ── types ─────────────────────────────────────────────────────────────

    /// @notice Frozen per pool record. `launcher != 0` marks an official pool.
    ///         `restricted` mirrors the coin's launch flag; the hook grants a
    ///         PoolManager transfer allowance on each swap when it is set.
    struct PoolInfo {
        uint16 version;
        bool restricted;
        uint40 createdAt;
        address launcher;
        address token;
        address locker;
        address mevModule;
        address extension;
    }

    /// @notice Per pool fee config. The rates and caps are set once at init; the
    ///         coin admin may change `bountyRecipient` later.
    struct SkimConfig {
        uint24 baselineSkimBps; // BPS of volume
        uint16 bountyBps; // bounty share of the skim, BPS
        uint24 maxReferralBpsOfVolume; // BPS of volume
        uint24 lpFeePips; // uniswap v4 pips (1e6 units)
        address payable bountyRecipient;
        address payable protocolRecipient;
    }

    /// @notice Owner set globals.
    struct HookGlobals {
        address feeEscrow;
        address extensionAllowlist;
    }

    /// @notice Launcher input to `initializePool`.
    struct PoolInitParams {
        address token;
        int24 tickIfToken0IsCoin;
        int24 tickSpacing;
        address locker;
        address mevModule; // 0 for none
        address extension; // 0 for none, must be on the extension allowlist
        bytes extensionData;
        SkimConfig skim;
        /// @dev Additive (D52): protocol leg floor, BPS of the baseline skim.
        ///      A referral is paid only from the protocol leg above it.
        uint16 minProtocolShareBps;
    }

    // ── events ────────────────────────────────────────────────────────────

    event PoolInitializedV2(
        PoolId indexed poolId,
        address indexed token,
        address indexed launcher,
        uint16 version,
        bool restricted,
        address locker,
        address mevModule,
        address extension,
        int24 tickSpacing
    );
    event SkimConfigInitialized(PoolId indexed poolId, SkimConfig config);
    event MevModuleInitialized(PoolId indexed poolId, address indexed module);
    /// @notice One fee leg (Constants.LEG_*) delivered; `escrowed` when the push failed.
    event FeeDelivered(
        PoolId indexed poolId, uint8 indexed leg, address indexed to, uint256 amount, bool escrowed
    );
    /// @notice Skim charged on the unfilled part of a price limited swap, refunded via the escrow.
    event SkimRefunded(PoolId indexed poolId, address indexed to, uint256 amount);
    event SkimSplit(
        PoolId indexed poolId,
        uint256 quoteVolume,
        uint256 bountyAmount,
        uint256 protocolNet,
        uint256 referralPaid
    );
    event SwapAttribution(
        PoolId indexed poolId,
        address indexed swapper,
        address indexed referrer,
        bytes32 sourceId,
        bytes16 campaignId,
        uint256 quoteVolume,
        uint256 referralPaid
    );

    event LauncherSet(address indexed launcher, bool enabled);
    event FeeEscrowSet(address indexed oldEscrow, address indexed newEscrow);
    event ExtensionAllowlistSet(address indexed oldAllowlist, address indexed newAllowlist);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event ClaimsRescued(Currency indexed currency, address indexed to, uint256 amount);

    // ── errors ────────────────────────────────────────────────────────────

    error NotLauncher();
    error ForeignInitialize();
    error ZeroAddress();
    error CanonicalHookMismatch();
    error ExtensionNotAllowed(address extension);
    error MevModuleAlreadyInitialized();
    error MevWindowActive();
    error LpFeeTooHigh();
    error BaselineSkimBpsTooHigh();
    /// @notice `bountyBps` exceeds MAX_BOUNTY_BPS (share of the skim, in BPS).
    error BountyBpsTooHigh();
    /// @notice `bountyBps + minProtocolShareBps` exceeds BPS, so the legs cannot fit.
    error BadLegBps();
    error MaxReferralTooHigh();
    error BountyRecipientZero();
    error ProtocolRecipientZero();
    /// @notice A computed skim exceeds int128, the v4 BeforeSwapDelta limit.
    ///         Unreachable for valid pools: the skim is bounded by the swap
    ///         amount, itself an int128.
    error SkimExceedsInt128(uint256 value);
    error NativeTransferFailed();

    // ── launcher ──────────────────────────────────────────────────────────

    /// @notice Creates and registers the pool. Allowlisted launchers only.
    ///         Checks `constantsHash()` of the locker and the mev module.
    function initializePool(PoolInitParams calldata p) external returns (PoolKey memory poolKey);

    /// @notice Starts the pool's anti sniper window after liquidity is placed.
    ///         Launcher of that pool only, once.
    function initializeMevModule(PoolKey calldata poolKey, bytes calldata mevConfig) external;

    // ── reads ─────────────────────────────────────────────────────────────

    function poolInfo(PoolId poolId) external view returns (PoolInfo memory);
    function isOfficialPool(PoolId poolId) external view returns (bool);
    function skimConfig(PoolId poolId) external view returns (SkimConfig memory);
    function globals() external view returns (HookGlobals memory);
    function isLauncher(address launcher) external view returns (bool);

    // ── owner ─────────────────────────────────────────────────────────────

    function setLauncher(address launcher, bool enabled) external;
    /// @dev Affects where failed pushes land from now on.
    function setFeeEscrow(address escrow) external;
    /// @dev Affects new pools only.
    function setExtensionAllowlist(address allowlist) external;
    /// @notice Sends stray eth (`token == address(0)`) or erc20. The hook holds nothing between swaps.
    function rescue(address token, address to, uint256 amount) external;
    /// @notice Sends stray PoolManager erc6909 claims held by the hook.
    function rescueClaims(Currency currency, address to, uint256 amount) external;

    // ── coin admin ─────────────────────────────────────────────────────────

    /// @notice Sets the pool's bounty recipient. Coin admin only, until the coin
    ///         locks its recipients or renounces its admin. `newRecipient` must
    ///         be nonzero and not the coin, this hook, the PoolManager, the hook
    ///         or locker fee escrow, the pool's mev module, the pool's locker,
    ///         the factory, its token deployer or the PositionManager.
    function setBountyRecipient(PoolId poolId, address payable newRecipient) external;

    /// @notice Stack version tag (Constants.STACK_VERSION).
    function STACK_VERSION() external view returns (uint16);
}
