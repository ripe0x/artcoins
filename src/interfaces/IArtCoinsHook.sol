// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IArtCoinsHook
/// @notice Interface for the ArtCoins Uniswap v4 hook (`ArtCoinsHook` and its
///         concrete fee variants). Covers the base pool/MEV surface plus the
///         pool-extension, sniper-fee and dynamic-fee members.
interface IArtCoinsHook {
    // ─── errors ───────────────────────────────────────────────────────────

    /// @notice Reverts when attempting to create a pool paired with native ETH.
    error ETHPoolNotAllowed();
    /// @notice Reverts when a factory-only function is called by someone else.
    error OnlyFactory();
    /// @notice Reverts when the initialization path is not supported for this caller.
    error UnsupportedInitializePath();
    /// @notice Reverts when attempting to initialize a MEV module past the allowed window.
    error PastCreationTimestamp();
    /// @notice Reverts when a MEV module is already enabled and another is attempted.
    error MevModuleEnabled();
    /// @notice Reverts when trying to use WETH as the art coin token.
    error WethCannotBeArtCoins();
    /// @notice Reverts when `initializePoolOpen` is given an `artCoin` address
    ///         that has no contract code, which would let a caller pre-create a
    ///         pool for a predicted, not-yet-deployed CREATE2 token address.
    error ArtCoinNotDeployed();
    /// @notice Reverts when an internal helper is called by anything other than the hook itself.
    error OnlyThis();
    /// @notice Reverts when an action requires the MEV module to be operational and it isn't.
    error MevModuleNotOperational();
    /// @notice Reverts when the caller is not authorized.
    error Unauthorized();
    /// @notice Reverts when a non-factory pool tries to register a pool extension.
    error OnlyFactoryPoolsCanHaveExtensions();
    /// @notice Reverts when the requested pool extension is not on the allowlist.
    error PoolExtensionNotEnabled();
    /// @notice Reverts when the caller is not the pool token's `admin()`.
    error NotTokenAdmin();
    /// @notice Reverts when the pool's extension slot is permanently locked.
    error PoolExtensionLockedErr();
    /// @notice Reverts when an attempt is made to change the sniper-fee
    ///         recipient on a pool whose recipient slot is permanently locked.
    error SniperFeeRecipientLockedErr();
    /// @notice Reverts when deploy-time sniper recipient config is invalid.
    error InvalidSniperFeeConfig();

    // ─── events ───────────────────────────────────────────────────────────

    /// @notice Emitted when a pool is created via the open (non-factory) path.
    /// @param pairedToken The paired token.
    /// @param artCoin The ArtCoins token.
    /// @param poolId The Uniswap v4 pool id.
    /// @param tickIfToken0IsArtCoins The tick assuming ArtCoins is token0.
    /// @param tickSpacing The pool tick spacing.
    event PoolCreatedOpen(
        address indexed pairedToken,
        address indexed artCoin,
        PoolId poolId,
        int24 tickIfToken0IsArtCoins,
        int24 tickSpacing
    );

    /// @notice Emitted when a pool is created via the factory path.
    /// @param pairedToken The paired token.
    /// @param artCoin The ArtCoins token.
    /// @param poolId The Uniswap v4 pool id.
    /// @param tickIfToken0IsArtCoins The tick assuming ArtCoins is token0.
    /// @param tickSpacing The pool tick spacing.
    /// @param locker The LP locker contract address.
    /// @param mevModule The MEV module contract address (may be zero).
    event PoolCreatedFactory(
        address indexed pairedToken,
        address indexed artCoin,
        PoolId poolId,
        int24 tickIfToken0IsArtCoins,
        int24 tickSpacing,
        address locker,
        address mevModule
    );

    /// @notice Emitted when a pool's MEV module is manually disabled. Not emitted on natural expiry.
    event MevModuleDisabled(PoolId);
    /// @notice Emitted when protocol-level fees are claimed from the hook.
    ///         `ArtCoinsHook` has no hook-level protocol-fee path and never
    ///         emits this; the event stays on the shared interface for hook
    ///         implementations that do expose such a path.
    /// @param token Token claimed.
    /// @param amount Amount claimed.
    event ClaimProtocolFees(address indexed token, uint256 amount);

    /// @notice Emitted after a successful pool-extension afterSwap call.
    /// @param poolId The pool id.
    event PoolExtensionSuccess(PoolId poolId);
    /// @notice Emitted when a pool-extension afterSwap call reverts (it is swallowed).
    /// @param poolId The pool id.
    /// @param swapParams Parameters of the swap that triggered the failed call.
    event PoolExtensionFailed(PoolId poolId, IPoolManager.SwapParams swapParams);
    /// @notice Emitted when the MEV module raises the LP fee for a swap.
    /// @param poolId The pool id.
    /// @param fee The new fee.
    event MevModuleSetFee(PoolId poolId, uint24 fee);
    /// @notice Emitted when a pool extension is bound to a pool.
    /// @param poolId The pool id.
    /// @param extension The pool extension contract.
    event PoolExtensionRegistered(PoolId indexed poolId, address indexed extension);
    /// @notice Emitted when the token admin swaps the pool's extension via
    ///         `setPoolExtension`. `oldExtension` is the prior address (zero
    ///         if there was no extension); `newExtension` is the replacement
    ///         (zero if the slot was cleared).
    /// @param poolId The pool id.
    /// @param oldExtension Previous extension address.
    /// @param newExtension New extension address (zero = cleared).
    event PoolExtensionSwapped(
        PoolId indexed poolId, address indexed oldExtension, address indexed newExtension
    );
    /// @notice Emitted when the pool's extension slot is permanently locked.
    /// @param poolId The pool id.
    event PoolExtensionLockedEvt(PoolId indexed poolId);
    /// @notice Emitted when the sniper-fee recipient is set or changed for a pool.
    /// @param poolId The pool id.
    /// @param oldRecipient Previous recipient address (zero if unset).
    /// @param newRecipient New recipient address (zero clears the slot).
    event SniperFeeRecipientSet(
        PoolId indexed poolId, address indexed oldRecipient, address indexed newRecipient
    );
    /// @notice Emitted when the pool's sniper-fee recipient slot is permanently locked.
    /// @param poolId The pool id.
    event SniperFeeRecipientLockedEvt(PoolId indexed poolId);
    /// @notice Emitted when the bound MEV module sets the per-swap sniper-extra ppm.
    /// @param poolId The pool id.
    /// @param extraPpm Extra fee on top of the pool's base LP fee, in ppm (1e6 = 100%).
    event MevModuleSetSniperFee(PoolId indexed poolId, uint24 extraPpm);
    /// @notice Emitted when the hook accrues sniper-extra in the input currency
    ///         (mints claim tokens that will be flushed to the recipient on the
    ///         next swap).
    /// @param poolId The pool id.
    /// @param currency The input currency the extra was taken in.
    /// @param amount The extra amount in that currency.
    event SniperExtraFeeAccrued(PoolId indexed poolId, address indexed currency, uint256 amount);
    /// @notice Emitted when previously accrued sniper-extra is flushed to the recipient.
    /// @param poolId The pool id.
    /// @param currency The currency flushed.
    /// @param amount Amount flushed.
    /// @param recipient The recipient that received the flush.
    event SniperExtraFeeFlushed(
        PoolId indexed poolId, address indexed currency, uint256 amount, address indexed recipient
    );

    // ─── structs ──────────────────────────────────────────────────────────

    /// @notice Decoded payload for `poolData` passed to `initializePool`.
    /// @param extension Optional pool extension contract.
    /// @param extensionData ABI-encoded init data for the extension.
    /// @param feeData ABI-encoded fee config consumed by `_initializeFeeData`.
    struct PoolInitializationData {
        address extension;
        bytes extensionData;
        bytes feeData;
    }

    /// @notice Decoded payload for `swapData` passed via Uniswap v4 hook calls.
    /// @param mevModuleSwapData Forwarded to the MEV module's `beforeSwap`.
    /// @param poolExtensionSwapData Forwarded to the pool extension's `afterSwap`.
    struct PoolSwapData {
        bytes mevModuleSwapData;
        bytes poolExtensionSwapData;
    }

    // ─── functions ──────────────────────────────────────────────────────────

    /// @notice Initializes a pool via the factory path.
    /// @param artCoin The ArtCoins token.
    /// @param pairedToken The paired token.
    /// @param tickIfToken0IsArtCoins Starting tick assuming ArtCoins is token0.
    /// @param tickSpacing The pool tick spacing.
    /// @param locker LP locker contract.
    /// @param mevModule MEV module contract (optional).
    /// @param poolData Hook-specific initialization data.
    /// @return poolKey The resulting Uniswap v4 pool key.
    function initializePool(
        address artCoin,
        address pairedToken,
        int24 tickIfToken0IsArtCoins,
        int24 tickSpacing,
        address locker,
        address mevModule,
        bytes calldata poolData
    ) external returns (PoolKey memory);

    /// @notice Initializes a pool outside the factory (permissionless path).
    /// @param artCoin The ArtCoins token.
    /// @param pairedToken The paired token.
    /// @param tickIfToken0IsArtCoins Starting tick assuming ArtCoins is token0.
    /// @param tickSpacing The pool tick spacing.
    /// @param poolData Hook-specific initialization data.
    /// @return poolKey The resulting Uniswap v4 pool key.
    function initializePoolOpen(
        address artCoin,
        address pairedToken,
        int24 tickIfToken0IsArtCoins,
        int24 tickSpacing,
        bytes calldata poolData
    ) external returns (PoolKey memory);

    /// @notice Turns on a pool's MEV module if one was configured.
    /// @param poolKey The target pool key.
    /// @param mevModuleData Encoded MEV module initialization data.
    function initializeMevModule(PoolKey calldata poolKey, bytes calldata mevModuleData) external;

    /// @notice Lets the bound MEV module raise the dynamic LP fee for the next swap.
    /// @param poolKey The pool key.
    /// @param fee The desired fee.
    function mevModuleSetFee(PoolKey calldata poolKey, uint24 fee) external;

    /// @notice Lets the bound MEV module signal an "extra" fee on top of the
    ///         pool's base LP fee for the next swap. The extra is taken from
    ///         the swap's input currency and routed to the per-pool
    ///         `sniperFeeRecipient`. The pool's LP fee is NOT changed — the
    ///         normal locker reward split continues to receive only the base
    ///         pool fee.
    /// @dev    Silent no-op if the MEV module is not operational, the caller
    ///         is not the bound MEV module, or `extraPpm > MAX_MEV_LP_FEE`.
    /// @param poolKey The pool key.
    /// @param extraPpm Extra fee on top of base LP fee, in ppm (1e6 = 100%).
    function mevModuleSetSniperFee(PoolKey calldata poolKey, uint24 extraPpm) external;

    /// @notice Sets the recipient that receives sniper-extra fees collected on
    ///         this pool (independent of the locker reward split). Token admin only.
    /// @param poolKey The pool key.
    /// @param recipient The recipient address (set to zero to disable the path).
    function setSniperFeeRecipient(PoolKey calldata poolKey, address recipient) external;

    /// @notice Factory-only deploy-time setup for the sniper-extra recipient.
    /// @param poolKey The pool key.
    /// @param recipient The recipient address (set to zero to disable the path).
    /// @param lockRecipient Whether to permanently lock the recipient slot after setting it.
    function factorySetSniperFeeRecipient(
        PoolKey calldata poolKey,
        address recipient,
        bool lockRecipient
    ) external;

    /// @notice Permanently locks the pool's sniper-fee recipient slot so it can
    ///         never be changed again. Token admin only. One-way.
    /// @param poolKey The pool key.
    function lockSniperFeeRecipient(PoolKey calldata poolKey) external;

    /// @notice Returns whether the MEV module is currently operational, disabling it on expiry.
    /// @param poolId The pool id.
    /// @return True if operational.
    function mevModuleOperational(PoolId poolId) external returns (bool);

    /// @notice Returns whether a pool currently has an active MEV module.
    /// @param poolId The pool id.
    /// @return True if a MEV module is active.
    function mevModuleEnabled(PoolId poolId) external view returns (bool);

    /// @notice Returns the block timestamp a pool was created at.
    /// @param poolId The pool id.
    /// @return Creation timestamp.
    function poolCreationTimestamp(PoolId poolId) external view returns (uint256);

    /// @notice Maximum allowed delay between pool creation and MEV module activation.
    function MAX_MEV_MODULE_DELAY() external view returns (uint256);
    /// @notice Maximum normal LP fee.
    function MAX_LP_FEE() external view returns (uint24);
    /// @notice Maximum LP fee that the MEV module may set.
    function MAX_MEV_LP_FEE() external view returns (uint24);

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}
