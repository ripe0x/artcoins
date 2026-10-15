// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IConstantsBound} from "./IConstantsBound.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IArtCoinsHookV2
/// @notice Skim fee hook for v2 art coin pools, each pairing native eth (currency0) with the coin (currency1) at lp fee 0.
/// @dev    The hook charges a skim on the eth side of every swap and splits it
///         into a bounty, a protocol and a referral leg. Skim above the pool
///         baseline during the anti sniper window goes to the bounty recipient.
///         Each leg is pushed with the 2,300 gas stipend, and a failed push is
///         credited to the recipient in the fee escrow. Skim charged on the
///         unfilled part of a quote specified fill is credited there to the refund
///         address, which the swap's `hookData` must carry.
///
///         Authority: allowlisted launchers create pools. The owner sets
///         launchers, fee escrow, extension allowlist and referral rate. The coin
///         admin sets the pool's bounty recipient and extension and lowers its
///         baseline skim, until the coin is locked (`locked()`) or the admin is 0.
///         Units: bps = 1/10,000 of swap volume, amounts in wei, seconds.
///
///         Swap `hookData` is optional and never reverts the swap:
///           abi.encode(bytes mevModuleSwapData, bytes poolExtensionSwapData)
///         mevModuleSwapData is empty or exactly 32 bytes, abi.encode(address
///         refundTo), with clean high 12 bytes (`HookCalldata.refundTo`). A quote
///         specified swap that fills partially reverts `RefundAddressRequired`
///         without a valid refundTo.
///         poolExtensionSwapData is empty or abi.encode(address referrer,
///         bytes extensionPayload) and goes whole to the pool extension. The
///         referrer is paid `referralBps` of the swap volume out of the protocol
///         leg. Malformed input yields a zero referrer and a zero refund address.
interface IArtCoinsHookV2 is IConstantsBound {
    // ── types ─────────────────────────────────────────────────────────────

    /// @notice Per pool record, written at `initializePool`. Every field is fixed
    ///         except `extension`, which the coin admin changes with
    ///         `setPoolExtension`. A nonzero `launcher` marks an official pool.
    ///         When `restricted` is set the hook grants a PoolManager transfer
    ///         allowance on each swap.
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

    /// @notice Per pool fee config. Fixed at init except `bountyRecipient`
    ///         (`setBountyRecipient`) and `baselineSkimBps` (`lowerBaselineSkim`,
    ///         lower only). The referral rate is hook wide (`referralBps`).
    struct SkimConfig {
        /// @dev Baseline skim, bps of swap volume. At most Constants.MAX_BASELINE_SKIM_BPS.
        uint24 baselineSkimBps;
        /// @dev Bounty share of the baseline skim, bps. At most Constants.MAX_BOUNTY_BPS.
        uint16 bountyBps;
        /// @dev Receives the bounty leg, which is the bounty share of the
        ///      baseline skim plus all skim above the baseline. Nonzero.
        address payable bountyRecipient;
        /// @dev Receives the protocol leg. Nonzero, fixed at init.
        address payable protocolRecipient;
    }

    /// @notice Owner controlled hook wide addresses.
    struct HookGlobals {
        /// @dev Fee escrow that credits failed leg pushes and skim refunds.
        address feeEscrow;
        /// @dev Allowlist consulted for `PoolInitParams.extension` at pool creation.
        ///      0 disables extensions.
        address extensionAllowlist;
    }

    /// @notice Launcher input to `initializePool`.
    struct PoolInitParams {
        /// @dev The coin. Must name this hook, the pool and the calling launcher.
        address token;
        /// @dev Starting tick as if the coin were token0. The pool price uses its
        ///      negation because the coin is currency1.
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

    /// @notice The pool's launch completed in `initializeMevModule`.
    /// @param poolId Pool id.
    event PoolStarted(PoolId indexed poolId);

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

    /// @notice Skim charged on the unfilled part of a quote specified swap was
    ///         credited to `to` in the fee escrow.
    /// @param poolId Pool id.
    /// @param to Refund address from `hookData`.
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

    /// @notice A referrer was named in the swap `hookData` and the swap paid a skim.
    /// @param poolId Pool id.
    /// @param swapper PoolManager caller of the swap.
    /// @param referrer Referrer named in `hookData`.
    /// @param quoteVolume Realized eth side swap amount, wei.
    /// @param referralPaid Referral leg, wei. Zero when the referrer is the swapper.
    event SwapAttribution(
        PoolId indexed poolId,
        address indexed swapper,
        address indexed referrer,
        uint256 quoteVolume,
        uint256 referralPaid
    );

    /// @notice The owner changed the hook wide referral rate.
    /// @param oldBps Previous rate, bps of swap volume.
    /// @param newBps New rate, bps of swap volume.
    event ReferralBpsSet(uint24 oldBps, uint24 newBps);

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

    /// @notice The owner sent out eth or erc20 held by the hook.
    /// @param token Token, or 0 for eth.
    /// @param to Recipient.
    /// @param amount Amount, token units or wei.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice The owner sent out PoolManager erc6909 claims held by the hook.
    /// @param currency Claim currency.
    /// @param to Recipient.
    /// @param amount Claim amount.
    event ClaimsRescued(Currency indexed currency, address indexed to, uint256 amount);

    /// @notice The coin admin set the pool's bounty recipient.
    /// @param poolId Pool id.
    /// @param oldRecipient Previous bounty recipient.
    /// @param newRecipient New bounty recipient.
    event BountyRecipientSet(
        PoolId indexed poolId, address indexed oldRecipient, address indexed newRecipient
    );

    /// @notice The coin admin lowered the pool's baseline skim.
    /// @param poolId Pool id.
    /// @param oldBps Previous baseline skim, bps of swap volume.
    /// @param newBps New baseline skim, bps of swap volume.
    event BaselineSkimLowered(PoolId indexed poolId, uint24 oldBps, uint24 newBps);

    /// @notice The coin admin set the pool's extension.
    /// @param poolId Pool id.
    /// @param oldExtension Previous extension, zero for none.
    /// @param newExtension New extension, zero for none.
    event PoolExtensionSet(
        PoolId indexed poolId, address indexed oldExtension, address indexed newExtension
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

    /// @notice `setPoolExtension` before the pool's launch completed (`initializeMevModule`).
    error PoolNotStarted();

    /// @notice `baselineSkimBps` is zero or exceeds Constants.MAX_BASELINE_SKIM_BPS.
    /// @param bps The rejected value.
    error BaselineSkimOutOfBounds(uint24 bps);

    /// @notice `bountyBps` exceeds Constants.MAX_BOUNTY_BPS (share of the skim, in bps).
    error BountyBpsTooHigh();

    /// @notice `setReferralBps` above Constants.MAX_REFERRAL_CAP_OF_VOLUME.
    error ReferralBpsTooHigh();

    /// @notice The bounty recipient is zero.
    error BountyRecipientZero();

    /// @notice The protocol recipient is zero.
    error ProtocolRecipientZero();

    /// @notice A computed skim exceeds int128, the v4 BeforeSwapDelta limit.
    /// @param value The computed skim, wei.
    error SkimExceedsInt128(uint256 value);

    /// @notice An eth transfer in `rescue` failed.
    error NativeTransferFailed();

    /// @notice The escrow passed to `setFeeEscrow` does not list this hook as a
    ///         core depositor, so a failed push could not fall back to it.
    /// @param escrow The rejected escrow.
    error EscrowNotCoreDepositor(address escrow);

    /// @notice A recipient cannot hold a fee: the coin, this hook, the PoolManager,
    ///         a fee escrow this hook has used, the pool's mev module, locker or
    ///         pool extension, any factory-enabled launch extension, the coin's
    ///         launcher, its token deployer or the locker's PositionManager. Also reverts when a skim recipient is this hook or
    ///         the PoolManager at init.
    /// @param recipient The rejected recipient.
    error RecipientCannotReceive(address recipient);

    /// @notice A reject-set lookup (token deployer or locker PositionManager)
    ///         reverted, so the recipient could not be verified.
    error RecipientCheckFailed();

    /// @notice The caller is not the coin's current admin.
    error NotCoinAdmin();

    /// @notice The coin is locked (`locked()`), so the admin settings are frozen.
    error CoinLocked();

    /// @notice `lowerBaselineSkim` with zero or a value at or above the baseline.
    /// @param current Current baseline skim, bps of swap volume.
    /// @param requested Requested value.
    error SkimNotLower(uint24 current, uint24 requested);

    /// @notice `poolId` was not created by this hook.
    error UnknownPool();

    /// @notice A quote specified swap filled partially and `hookData` carries no
    ///         refund address for the over charge.
    error RefundAddressRequired();

    // ── launcher ──────────────────────────────────────────────────────────

    /// @notice Creates and registers the pool, initializes it in the PoolManager
    ///         and writes the pool record and skim config.
    /// @dev    Callable by allowlisted launchers. The locker and the mev module (when
    ///         set) must report this build's `constantsHash()`. Reverts with
    ///         `NotLauncher`, `ZeroAddress`, `ConstantsMismatch`, `BaselineSkimOutOfBounds`,
    ///         `BountyBpsTooHigh`, `BountyRecipientZero`, `ProtocolRecipientZero`,
    ///         `RecipientCannotReceive`, `CanonicalHookMismatch`, `ExtensionNotAllowed`
    ///         or `EscrowNotCoreDepositor`.
    /// @param p Pool parameters.
    /// @return poolKey Key of the created pool.
    function initializePool(PoolInitParams calldata p) external returns (PoolKey memory poolKey);

    /// @notice Starts the pool's anti sniper window and runs the extension's
    ///         post locker setup.
    /// @dev    Callable once, by the launcher of that pool. Reverts with
    ///         `NotLauncher` or `MevModuleAlreadyInitialized`.
    /// @param poolKey Key of the pool.
    /// @param mevConfig Empty for the Constants defaults, else
    ///        `abi.encode(startingSkimBps, windowSeconds)`. The hook passes the
    ///        module the pool baseline, capped at the starting value, as the end
    ///        value.
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

    /// @notice Hook wide referral rate, bps of swap volume, paid out of the protocol
    ///         leg to the referrer a swap names.
    function referralBps() external view returns (uint24);

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
    /// @dev    The escrow must report this build's `constantsHash()` and list this
    ///         hook as a core depositor. Reverts with `ConstantsMismatch` or `EscrowNotCoreDepositor`.
    /// @param escrow New fee escrow.
    function setFeeEscrow(address escrow) external;

    /// @notice Sets the hook wide referral rate. Owner only.
    /// @dev    Reverts with `ReferralBpsTooHigh` above
    ///         Constants.MAX_REFERRAL_CAP_OF_VOLUME. Applies to every pool from the
    ///         next swap. A referral is at most the protocol leg of its swap.
    /// @param bps New rate, bps of swap volume.
    function setReferralBps(uint24 bps) external;

    /// @notice Sets the extension allowlist. Owner only.
    /// @dev    Gates the extension in `initializePool` and `setPoolExtension`.
    ///         Extensions already set keep running. 0 rejects every nonzero
    ///         extension.
    /// @param allowlist New allowlist.
    function setExtensionAllowlist(address allowlist) external;

    /// @notice Sends eth (`token == address(0)`) or erc20 held by the hook. Owner only.
    /// @dev    Reverts with `ZeroAddress` when `to` is zero and with
    ///         `NativeTransferFailed` when an eth send fails.
    /// @param token Token, or 0 for eth.
    /// @param to Recipient.
    /// @param amount Amount, token units or wei.
    function rescue(address token, address to, uint256 amount) external;

    /// @notice Sends PoolManager erc6909 claims held by the hook. Owner only.
    /// @dev    Reverts with `ZeroAddress` when `to` is zero.
    /// @param currency Claim currency.
    /// @param to Recipient.
    /// @param amount Claim amount.
    function rescueClaims(Currency currency, address to, uint256 amount) external;

    // ── coin admin ─────────────────────────────────────────────────────────

    /// @notice Sets the pool's bounty recipient. Coin admin only, until the coin
    ///         is locked or the admin is 0.
    /// @dev    `newRecipient` must be nonzero and not in the set listed at
    ///         `RecipientCannotReceive`, which includes the pool extension and
    ///         every factory-enabled launch extension.
    ///         Reverts with `UnknownPool`, `NotCoinAdmin`, `CoinLocked`,
    ///         `BountyRecipientZero`, `RecipientCannotReceive` or `RecipientCheckFailed`.
    /// @param poolId Pool id.
    /// @param newRecipient New bounty recipient.
    function setBountyRecipient(PoolId poolId, address payable newRecipient) external;

    /// @notice Lowers the pool's baseline skim. Coin admin only, until the coin
    ///         is locked or the admin is 0.
    /// @dev    `bps` must be above zero and below the current baseline. Applies
    ///         from the next swap. A running anti sniper window keeps its schedule
    ///         and the skim is at least the new baseline. Reverts with `UnknownPool`, `NotCoinAdmin`,
    ///         `CoinLocked` or `SkimNotLower`.
    /// @param poolId Pool id.
    /// @param bps New baseline skim, bps of swap volume.
    function lowerBaselineSkim(PoolId poolId, uint24 bps) external;

    /// @notice Sets the pool's extension. Coin admin only, until the coin is
    ///         locked or the admin is 0.
    /// @dev    `newExtension` is zero or enabled on the extension allowlist. A new
    ///         extension receives both locker setup calls in this call. The old
    ///         extension is not called. Callable after `initializeMevModule`.
    ///         Reverts with `UnknownPool`, `NotCoinAdmin`, `CoinLocked`,
    ///         `PoolNotStarted` or `ExtensionNotAllowed`.
    /// @param key Key of the pool.
    /// @param newExtension New extension, zero for none.
    /// @param initData Opaque bytes passed to the new extension's pre locker setup.
    function setPoolExtension(PoolKey calldata key, address newExtension, bytes calldata initData)
        external;

    /// @notice Stack version tag (Constants.STACK_VERSION).
    /// @return The stack version.
    function STACK_VERSION() external view returns (uint16);
}
