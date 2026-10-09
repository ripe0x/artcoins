// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IConstantsBound} from "./IConstantsBound.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IArtCoinsHookV2
/// @notice Skim fee hook for v2 art coin pools (native eth paired). Pools are
///         created only by allowlisted launchers. Per pool values are written
///         once at init; the coin admin may later change the bounty recipient
///         until the coin locks its recipients or renounces its admin.
///         Fee legs are pushed with a zero gas call and fall back to the fee
///         escrow.
///
///         Units: bps = 1/10,000; `lpFeePips` = 1/1,000,000; amounts in wei;
///         durations in seconds.
///
///         Anti sniper skim above the pool baseline goes to the bounty
///         recipient. The skim is charged on the realized fill; any over charge
///         on a price limited fill is credited in the fee escrow to the refund
///         address.
///
///         Swap `hookData` (all parts optional, never reverts the swap):
///           abi.encode(bytes mevModuleSwapData, bytes poolExtensionSwapData)
///         mevModuleSwapData names the refund address for the over charge on a
///         price limited fill: empty, or exactly 32 bytes encoding one address
///         with clean high bits, else the refund goes to the PoolManager caller.
///         poolExtensionSwapData is
///           abi.encode(Attribution attribution, bytes extensionPayload),
///           Attribution = (bytes32 sourceId, address referrer, bytes16
///           campaignId, uint24 referralBps), where referralBps is BPS of
///           volume, capped by the pool's maxReferralBpsOfVolume.
///         Malformed input yields an empty attribution and refund address; the
///         swap never reverts on it.
interface IArtCoinsHookV2 is IConstantsBound {
    // ── types ─────────────────────────────────────────────────────────────

    /// @notice Per pool record, written once at `initializePool`. A nonzero
    ///         `launcher` marks an official pool. When `restricted` is set the
    ///         hook grants a PoolManager transfer allowance on each swap.
    struct PoolInfo {
        /// @dev Stack version (Constants.STACK_VERSION) at creation.
        uint16 version;
        /// @dev Mirrors the coin's restriction flag at creation.
        bool restricted;
        /// @dev Pool creation timestamp, seconds. The anti sniper window ends no
        ///      later than `createdAt + Constants.MAX_MEV_WINDOW`.
        uint40 createdAt;
        /// @dev Launcher that created the pool. Only it may call `initializeMevModule`.
        address launcher;
        /// @dev The coin, currency1 of the pool.
        address token;
        /// @dev LP locker holding the pool's launch liquidity.
        address locker;
        /// @dev Anti sniper skim module, or 0 for none.
        address mevModule;
        /// @dev Pool extension, or 0 for none.
        address extension;
    }

    /// @notice Per pool fee config. All fields are fixed at init except
    ///         `bountyRecipient`, which the coin admin may change with
    ///         `setBountyRecipient` until the coin locks its recipients or
    ///         renounces its admin.
    struct SkimConfig {
        /// @dev Baseline skim, bps of swap volume. At most Constants.MAX_BASELINE_SKIM_BPS.
        uint24 baselineSkimBps;
        /// @dev Bounty share of the baseline skim, bps. At most Constants.MAX_BOUNTY_BPS.
        uint16 bountyBps;
        /// @dev Cap on a swapper named referral, bps of swap volume. At most
        ///      Constants.MAX_REFERRAL_CAP_OF_VOLUME.
        uint24 maxReferralBpsOfVolume;
        /// @dev Uniswap v4 LP fee, pips (1/1,000,000). At most Constants.MAX_LP_FEE.
        uint24 lpFeePips;
        /// @dev Receives the bounty leg, which is the bounty share of the
        ///      baseline skim plus all skim above the baseline. Nonzero.
        address payable bountyRecipient;
        /// @dev Receives the protocol leg. Nonzero, fixed at init.
        address payable protocolRecipient;
    }

    /// @notice Owner controlled hook wide addresses.
    struct HookGlobals {
        /// @dev Fee escrow that credits legs whose push failed and skim refunds.
        address feeEscrow;
        /// @dev Allowlist consulted for `PoolInitParams.extension` at pool creation.
        ///      0 disables extensions.
        address extensionAllowlist;
    }

    /// @notice Launcher input to `initializePool`.
    struct PoolInitParams {
        /// @dev The coin. Must name this hook, the pool and the calling launcher.
        address token;
        /// @dev Starting tick as if the coin were token0. The pool price uses its negation
        ///      because the coin is currency1.
        int24 tickIfToken0IsCoin;
        /// @dev Pool tick spacing.
        int24 tickSpacing;
        /// @dev LP locker for the pool. Its `constantsHash()` must match.
        address locker;
        /// @dev Anti sniper skim module, or 0 for none. Its `constantsHash()` must match.
        address mevModule;
        /// @dev Pool extension, or 0 for none. Must be enabled on the extension allowlist.
        address extension;
        /// @dev Opaque payload passed to the extension's pre locker setup.
        bytes extensionData;
        /// @dev Fee config stored for the pool.
        SkimConfig skim;
        /// @dev Protocol leg floor, bps of the baseline skim. A referral is paid
        ///      only from the protocol leg above it. `skim.bountyBps` plus this
        ///      value must not exceed 10,000.
        uint16 minProtocolShareBps;
    }

    // ── events ────────────────────────────────────────────────────────────

    /// @notice A pool was created and registered.
    /// @param poolId Pool id.
    /// @param token The coin.
    /// @param launcher Launcher that created the pool.
    /// @param version Stack version.
    /// @param restricted Whether the coin is transfer restricted.
    /// @param locker LP locker.
    /// @param mevModule Anti sniper module, or 0.
    /// @param extension Pool extension, or 0.
    /// @param tickSpacing Pool tick spacing.
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

    /// @notice The pool's fee config was stored at creation.
    /// @param poolId Pool id.
    /// @param config The stored config.
    event SkimConfigInitialized(PoolId indexed poolId, SkimConfig config);

    /// @notice The pool's anti sniper module was configured by `initializeMevModule`.
    /// @param poolId Pool id.
    /// @param module The module.
    event MevModuleInitialized(PoolId indexed poolId, address indexed module);

    /// @notice One fee leg was delivered. `escrowed` is true when the push
    ///         failed and the amount was credited to `to` in the fee escrow.
    /// @param poolId Pool id.
    /// @param leg Leg id (Constants.LEG_BOUNTY, LEG_PROTOCOL or LEG_REFERRAL).
    /// @param to Leg recipient.
    /// @param amount Leg amount, wei.
    /// @param escrowed Whether the amount was credited in the fee escrow.
    event FeeDelivered(
        PoolId indexed poolId, uint8 indexed leg, address indexed to, uint256 amount, bool escrowed
    );

    /// @notice Skim charged on the unfilled part of a price limited swap was
    ///         credited in the fee escrow to `to`.
    /// @param poolId Pool id.
    /// @param to Refund address from `hookData`, else the PoolManager caller.
    /// @param amount Over charge, wei.
    event SkimRefunded(PoolId indexed poolId, address indexed to, uint256 amount);

    /// @notice The skim of one swap was split into legs.
    /// @param poolId Pool id.
    /// @param quoteVolume Realized eth side swap amount, wei.
    /// @param bountyAmount Bounty leg, wei.
    /// @param protocolNet Protocol leg after the referral, wei.
    /// @param referralPaid Referral leg, wei.
    event SkimSplit(
        PoolId indexed poolId,
        uint256 quoteVolume,
        uint256 bountyAmount,
        uint256 protocolNet,
        uint256 referralPaid
    );

    /// @notice Attribution named in the swap `hookData`. Emitted when a referrer
    ///         or a nonzero `sourceId` is present and the swap paid a skim.
    /// @param poolId Pool id.
    /// @param swapper PoolManager caller of the swap.
    /// @param referrer Referrer named in `hookData`, or 0.
    /// @param sourceId Opaque source id from `hookData`.
    /// @param campaignId Opaque campaign id from `hookData`.
    /// @param quoteVolume Realized eth side swap amount, wei.
    /// @param referralPaid Referral leg, wei.
    event SwapAttribution(
        PoolId indexed poolId,
        address indexed swapper,
        address indexed referrer,
        bytes32 sourceId,
        bytes16 campaignId,
        uint256 quoteVolume,
        uint256 referralPaid
    );

    /// @notice A launcher was enabled or disabled.
    /// @param launcher Launcher address.
    /// @param enabled New state.
    event LauncherSet(address indexed launcher, bool enabled);

    /// @notice The fee escrow changed.
    /// @param oldEscrow Previous escrow.
    /// @param newEscrow New escrow.
    event FeeEscrowSet(address indexed oldEscrow, address indexed newEscrow);

    /// @notice The extension allowlist changed.
    /// @param oldAllowlist Previous allowlist.
    /// @param newAllowlist New allowlist.
    event ExtensionAllowlistSet(address indexed oldAllowlist, address indexed newAllowlist);

    /// @notice Stray eth or erc20 was sent out by the owner.
    /// @param token Token, or 0 for eth.
    /// @param to Recipient.
    /// @param amount Amount, token units or wei.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Stray PoolManager erc6909 claims were sent out by the owner.
    /// @param currency Claim currency.
    /// @param to Recipient.
    /// @param amount Claim amount.
    event ClaimsRescued(Currency indexed currency, address indexed to, uint256 amount);

    /// @notice The pool's protocol leg floor was stored at creation.
    /// @param poolId Pool id.
    /// @param minProtocolShareBps Floor, bps of the baseline skim.
    event ProtocolFloorInitialized(PoolId indexed poolId, uint16 minProtocolShareBps);
    /// @notice The coin admin changed the pool's bounty recipient.
    /// @param poolId Pool id.
    /// @param oldRecipient Previous bounty recipient.
    /// @param newRecipient New bounty recipient.
    event BountyRecipientSet(
        PoolId indexed poolId, address indexed oldRecipient, address indexed newRecipient
    );

    // ── errors ────────────────────────────────────────────────────────────

    /// @notice The caller is not an allowlisted launcher, or not the launcher of the pool.
    error NotLauncher();

    /// @notice The PoolManager initialized a pool on this hook outside `initializePool`.
    error ForeignInitialize();

    /// @notice A required address argument is zero.
    error ZeroAddress();

    /// @notice The coin does not name this hook, this pool id and the calling launcher.
    error CanonicalHookMismatch();

    /// @notice The extension is not enabled on the extension allowlist, or no allowlist is set.
    error ExtensionNotAllowed(address extension);

    /// @notice `initializeMevModule` was already called for the pool.
    error MevModuleAlreadyInitialized();

    /// @notice Liquidity add refused while the pool's anti sniper window is open.
    error MevWindowActive();

    /// @notice `lpFeePips` exceeds Constants.MAX_LP_FEE.
    error LpFeeTooHigh();

    /// @notice `baselineSkimBps` exceeds Constants.MAX_BASELINE_SKIM_BPS.
    error BaselineSkimBpsTooHigh();

    /// @notice `bountyBps` exceeds Constants.MAX_BOUNTY_BPS (share of the skim, in bps).
    error BountyBpsTooHigh();

    /// @notice `bountyBps + minProtocolShareBps` exceeds 10,000 bps, so the legs cannot fit.
    error BadLegBps();

    /// @notice `maxReferralBpsOfVolume` exceeds Constants.MAX_REFERRAL_CAP_OF_VOLUME.
    error MaxReferralTooHigh();

    /// @notice The bounty recipient is zero.
    error BountyRecipientZero();

    /// @notice The protocol recipient is zero.
    error ProtocolRecipientZero();

    /// @notice A computed skim exceeds int128, the v4 BeforeSwapDelta limit.
    ///         The skim is bounded by the swap amount, itself an int128.
    /// @param value The computed skim, wei.
    error SkimExceedsInt128(uint256 value);

    /// @notice An eth transfer in `rescue` failed.
    error NativeTransferFailed();

    /// @notice The escrow passed to `setFeeEscrow` does not list this hook as a
    ///         core depositor, so a failed push could not fall back to it.
    /// @param escrow The rejected escrow.
    error EscrowNotCoreDepositor(address escrow);
    /// @notice `setBountyRecipient` rejected a recipient that cannot hold a fee:
    ///         the coin, this hook, the PoolManager, this hook's fee escrow, the
    ///         pool locker's fee escrow, the pool's mev module, the pool's locker,
    ///         the factory, its token deployer or the PositionManager.
    /// @param recipient The rejected recipient.
    error RecipientCannotReceive(address recipient);
    /// @notice A reject-set lookup (token deployer, locker PositionManager or locker
    ///         fee escrow) reverted, so the recipient could not be verified. The
    ///         setter refuses the change.
    error RecipientCheckFailed();
    /// @notice The caller of `setBountyRecipient` is not the coin's current admin.
    error NotCoinAdmin();
    /// @notice The coin's recipients are frozen (the coin called `lockRecipients`
    ///         or renounced its admin).
    error RecipientsLocked();
    /// @notice `poolId` was not created by this hook.
    error UnknownPool();

    // ── launcher ──────────────────────────────────────────────────────────

    /// @notice Creates and registers the pool, initializes it in the PoolManager
    ///         and freezes its fee config.
    /// @dev    Callable by allowlisted launchers only. The pool is eth (currency0)
    ///         against `p.token` (currency1) with a dynamic LP fee set once to
    ///         `p.skim.lpFeePips`. The locker and the mev module (when set) must
    ///         report this build's `constantsHash()`. Reverts with `NotLauncher`,
    ///         `ZeroAddress`, `ConstantsMismatch`, `LpFeeTooHigh`,
    ///         `BaselineSkimBpsTooHigh`, `BountyBpsTooHigh`, `MaxReferralTooHigh`,
    ///         `BountyRecipientZero`, `ProtocolRecipientZero`, `BadLegBps`,
    ///         `CanonicalHookMismatch` or `ExtensionNotAllowed`.
    /// @param p Pool parameters.
    /// @return poolKey Key of the created pool.
    function initializePool(PoolInitParams calldata p) external returns (PoolKey memory poolKey);

    /// @notice Starts the pool's anti sniper window after liquidity is placed
    ///         and runs the extension's post locker setup.
    /// @dev    Callable once, by the launcher of that pool. Reverts with
    ///         `NotLauncher` or `MevModuleAlreadyInitialized`.
    /// @param poolKey Key of the pool.
    /// @param mevConfig Empty for the Constants defaults, else
    ///        `abi.encode(startingSkimBps, windowSeconds)`. The hook appends the
    ///        pool baseline as the module's end value.
    function initializeMevModule(PoolKey calldata poolKey, bytes calldata mevConfig) external;

    // ── reads ─────────────────────────────────────────────────────────────

    /// @notice Pool record. All fields are zero for a pool this hook did not create.
    /// @param poolId Pool id.
    /// @return The pool record.
    function poolInfo(PoolId poolId) external view returns (PoolInfo memory);

    /// @notice Whether this hook created the pool.
    /// @param poolId Pool id.
    /// @return True when the pool's launcher is nonzero.
    function isOfficialPool(PoolId poolId) external view returns (bool);

    /// @notice Fee config of a pool, including the current bounty recipient.
    /// @param poolId Pool id.
    /// @return The fee config.
    function skimConfig(PoolId poolId) external view returns (SkimConfig memory);

    /// @notice The pool's protocol leg floor, in bps of the baseline skim.
    function minProtocolShareBps(PoolId poolId) external view returns (uint16);

    /// @notice Current fee escrow and extension allowlist.
    /// @return The hook wide addresses.
    function globals() external view returns (HookGlobals memory);

    /// @notice Whether `launcher` may create pools.
    /// @param launcher Address to check.
    /// @return True when enabled.
    function isLauncher(address launcher) external view returns (bool);

    // ── owner ─────────────────────────────────────────────────────────────

    /// @notice Enables or disables a launcher. Owner only.
    /// @dev    Reverts with `ZeroAddress` when `launcher` is zero.
    /// @param launcher Launcher address.
    /// @param enabled New state.
    function setLauncher(address launcher, bool enabled) external;

    /// @notice Sets the fee escrow. Owner only.
    /// @dev    Applies to failed pushes and refunds from now on. The escrow must
    ///         report this build's `constantsHash()` and list this hook as a core
    ///         depositor. Reverts with `ConstantsMismatch` or `EscrowNotCoreDepositor`.
    /// @param escrow New fee escrow.
    function setFeeEscrow(address escrow) external;

    /// @notice Sets the extension allowlist. Owner only.
    /// @dev    Applies to pools created from now on. 0 disables extensions.
    /// @param allowlist New allowlist.
    function setExtensionAllowlist(address allowlist) external;

    /// @notice Sends stray eth (`token == address(0)`) or erc20 held by the hook.
    ///         The hook holds nothing between swaps. Owner only.
    /// @dev    Reverts with `ZeroAddress` when `to` is zero and with
    ///         `NativeTransferFailed` when an eth send fails.
    /// @param token Token, or 0 for eth.
    /// @param to Recipient.
    /// @param amount Amount, token units or wei.
    function rescue(address token, address to, uint256 amount) external;

    /// @notice Sends stray PoolManager erc6909 claims held by the hook. Owner only.
    /// @dev    Reverts with `ZeroAddress` when `to` is zero.
    /// @param currency Claim currency.
    /// @param to Recipient.
    /// @param amount Claim amount.
    function rescueClaims(Currency currency, address to, uint256 amount) external;

    // ── coin admin ─────────────────────────────────────────────────────────

    /// @notice Sets the pool's bounty recipient. Coin admin only, until the coin
    ///         locks its recipients or renounces its admin.
    /// @dev    `newRecipient` must be nonzero and not the coin, this hook, the
    ///         PoolManager, the hook or locker fee escrow, the pool's mev module,
    ///         the pool's locker, the factory, its token deployer or the
    ///         PositionManager. The factory, token deployer, PositionManager and
    ///         locker fee escrow lookups fail closed: a lookup that reverts
    ///         refuses the change. Reverts with `UnknownPool`, `NotCoinAdmin`,
    ///         `RecipientsLocked`, `BountyRecipientZero`, `RecipientCannotReceive`
    ///         or `RecipientCheckFailed`.
    /// @param poolId Pool id.
    /// @param newRecipient New bounty recipient.
    function setBountyRecipient(PoolId poolId, address payable newRecipient) external;

    /// @notice Stack version tag (Constants.STACK_VERSION).
    /// @return The stack version.
    function STACK_VERSION() external view returns (uint16);
}
