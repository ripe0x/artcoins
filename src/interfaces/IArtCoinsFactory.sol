// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOwnerAdmins} from "./IOwnerAdmins.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IArtCoinsFactory
/// @notice Interface for the ArtCoins token launcher factory.
/// @dev Defines configs, events, and errors used during deployment.
interface IArtCoinsFactory is IOwnerAdmins {
    /// @notice Parameters describing the token to deploy.
    /// @param tokenAdmin The initial admin address for the deployed token.
    /// @param name ERC20 name.
    /// @param symbol ERC20 symbol.
    /// @param salt Salt combined with `tokenAdmin` to derive a CREATE2 address.
    /// @param image Image URL used in metadata.
    /// @param metadata Metadata/description string.
    /// @param context Freeform context string.
    /// @param totalSupply Token supply (0 = use factory default).
    /// @param renderer Optional metadata renderer (zero = built-in default). Owner can
    ///                 still swap it out post-deploy via `token.setMetadataRenderer`.
    struct TokenConfig {
        address tokenAdmin;
        string name;
        string symbol;
        bytes32 salt;
        string image;
        string metadata;
        string context;
        uint256 totalSupply; // 0 = use default (1B), otherwise deployer's choice
        address renderer;
    }

    /// @notice Pool configuration for the Uniswap v4 pool that backs the token.
    /// @param hook The (allowlisted) hook contract bound to the pool.
    /// @param pairedToken The other side of the pair (typically WETH).
    /// @param tickIfToken0IsArtCoins Starting tick if the deployed token sorts as `currency0`.
    /// @param tickSpacing Tick spacing for the v4 pool.
    /// @param poolData Hook-specific encoded init blob (`PoolInitializationData`).
    struct PoolConfig {
        address hook;
        address pairedToken;
        int24 tickIfToken0IsArtCoins;
        int24 tickSpacing;
        bytes poolData;
    }

    /// @notice LP locker + per-position + per-recipient configuration.
    /// @param locker The (allowlisted) locker contract.
    /// @param rewardAdmins Admins authorized to update the corresponding `rewardRecipients` slot.
    /// @param rewardRecipients Reward recipients (parallel to `rewardBps`).
    /// @param rewardBps Per-recipient share in basis points; must sum to 10_000.
    /// @param tickLower Per-position tick lower bound.
    /// @param tickUpper Per-position tick upper bound.
    /// @param positionBps Per-position share of the pool supply in basis points; must sum to 10_000.
    /// @param lockerData Locker-specific encoded init blob (locker-dependent).
    struct LockerConfig {
        address locker;
        address[] rewardAdmins;
        address[] rewardRecipients;
        uint16[] rewardBps;
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionBps;
        bytes lockerData;
    }

    /// @notice Configuration for one deploy-time extension (vault / airdrop / dev-buy / etc.).
    /// @param extension The (allowlisted) extension contract.
    /// @param msgValue ETH forwarded to the extension during `receiveTokens`.
    /// @param extensionBps Share of `totalSupply` allocated to this extension, in basis points.
    /// @param extensionData Extension-specific encoded init blob.
    struct ExtensionConfig {
        address extension;
        uint256 msgValue;
        uint16 extensionBps;
        bytes extensionData;
    }

    /// @notice Optional deploy-time sniper-extra fee routing.
    /// @param recipient Recipient for sniper-extra fees. Zero leaves the path disabled.
    /// @param lockRecipient If true, locks the recipient slot during deployment.
    struct SniperFeeConfig {
        address recipient;
        bool lockRecipient;
    }

    /// @notice Top-level deployment payload — combines all configs in a single call.
    /// @param tokenConfig Token-level metadata + supply + admin.
    /// @param poolConfig Pool-level hook + paired-token + tick configuration.
    /// @param lockerConfig LP locker positions + reward routing.
    /// @param mevModuleConfig MEV module bound to the pool at init.
    /// @param sniperFeeConfig Optional deploy-time sniper-extra fee routing.
    /// @param extensionConfigs Optional deploy-time extensions (vault, airdrop, dev-buy, …).
    struct DeploymentConfig {
        TokenConfig tokenConfig;
        PoolConfig poolConfig;
        LockerConfig lockerConfig;
        MevModuleConfig mevModuleConfig;
        SniperFeeConfig sniperFeeConfig;
        ExtensionConfig[] extensionConfigs;
    }

    /// @notice MEV module configuration bound to the new pool.
    /// @param mevModule The (allowlisted) MEV module contract.
    /// @param mevModuleData Module-specific encoded init blob (e.g. linear-fee parameters).
    struct MevModuleConfig {
        address mevModule;
        bytes mevModuleData;
    }

    /// @notice Persisted summary of a successful deployment, queryable via `tokenDeploymentInfo`.
    /// @param token The deployed token (proxy) address.
    /// @param hook The hook bound to the token's pool.
    /// @param locker The locker holding the LP positions for this token.
    /// @param extensions The extensions invoked at deploy time.
    struct DeploymentInfo {
        address token;
        address hook;
        address locker;
        address[] extensions;
    }

    /// @notice Reverts when public deployments are disabled and caller is not owner/admin.
    error Deprecated();
    /// @notice Reverts when a lookup target isn't found.
    error NotFound();
    /// @notice Reverts when the provided hook fails the interface check.
    error InvalidHook();
    /// @notice Reverts when the provided locker fails the interface check.
    error InvalidLocker();
    /// @notice Reverts when the provided extension fails the interface check.
    error InvalidExtension();
    /// @notice Reverts when the chosen hook is not on the allowlist.
    error HookNotEnabled();
    /// @notice Reverts when the chosen locker/hook pair is not on the allowlist.
    error LockerNotEnabled();
    /// @notice Reverts when an extension is not on the allowlist.
    error ExtensionNotEnabled();
    /// @notice Reverts when the chosen MEV module is not on the allowlist.
    error MevModuleNotEnabled();
    /// @notice Reverts when `msg.value` doesn't equal the sum of extension msgValues.
    error ExtensionMsgValueMismatch();
    /// @notice Reverts when more than `MAX_EXTENSIONS` extensions are supplied.
    error MaxExtensionsExceeded();
    /// @notice Reverts when the combined extension bps exceeds `MAX_EXTENSION_BPS`.
    error MaxExtensionBpsExceeded();
    /// @notice Reverts when the provided MEV module fails the interface check.
    error InvalidMevModule();
    /// @notice Reverts when the team fee recipient is not set but required.
    error TeamFeeRecipientNotSet();
    /// @notice Reverts when the deployer-supplied total supply is below `MIN_TOKEN_SUPPLY`.
    error TotalSupplyTooLow();
    /// @notice Reverts when an `onlyOwner` ETH sweep is attempted but the recipient is the zero address.
    error ZeroAddress();
    /// @notice Reverts when an ETH transfer (e.g. `recoverETH`) fails.
    error EthTransferFailed();
    /// @notice Reverts when the requested protocol-fee bps exceeds the cap.
    error ProtocolFeeBpsTooHigh();
    /// @notice Reverts when the deployer-supplied locker reward bps doesn't sum to
    ///         `(10_000 - defaultProtocolFeeBps)` so the factory can append the
    ///         protocol slot to bring the total to 10_000.
    error ProjectSideBpsMismatch();
    /// @notice Reverts when the requested deploy fee exceeds the cap.
    error DeployFeeTooHigh();

    /// @notice Emitted when ETH is swept out of the factory by the owner.
    /// @param recipient Address that received the ETH.
    /// @param amount Wei transferred.
    event RecoverEth(address indexed recipient, uint256 amount);

    /// @notice Emitted after a successful token deployment.
    event TokenCreated(
        address msgSender,
        address indexed tokenAddress,
        address indexed tokenAdmin,
        string tokenImage,
        string tokenName,
        string tokenSymbol,
        string tokenMetadata,
        string tokenContext,
        int24 startingTick,
        address poolHook,
        PoolId poolId,
        address pairedToken,
        address locker,
        address mevModule,
        uint256 extensionsSupply,
        address[] extensions
    );
    /// @notice Emitted when an extension receives its allocation.
    /// @param extension The extension contract address.
    /// @param extensionSupply Token amount allocated to the extension.
    /// @param msgValue ETH sent to the extension.
    event ExtensionTriggered(address extension, uint256 extensionSupply, uint256 msgValue);
    /// @notice Emitted when the deprecation flag is toggled.
    /// @param deprecated Current deprecation state.
    event SetDeprecated(bool deprecated);
    /// @notice Emitted when an extension's allowlist state is updated.
    /// @param extension The extension contract address.
    /// @param enabled New allowlist state.
    event SetExtension(address extension, bool enabled);
    /// @notice Emitted when a hook's allowlist state is updated.
    /// @param hook The hook contract address.
    /// @param enabled New allowlist state.
    event SetHook(address hook, bool enabled);
    /// @notice Emitted when a MEV module's allowlist state is updated.
    /// @param mevModule The MEV module contract address.
    /// @param enabled New allowlist state.
    event SetMevModule(address mevModule, bool enabled);
    /// @notice Emitted when a locker/hook pair's allowlist state is updated.
    /// @param locker The locker contract address.
    /// @param hook The hook contract address.
    /// @param enabled New allowlist state.
    event SetLocker(address locker, address hook, bool enabled);
    /// @notice Emitted when the team fee recipient changes.
    /// @param oldTeamFeeRecipient Previous recipient.
    /// @param newTeamFeeRecipient New recipient.
    event SetTeamFeeRecipient(address oldTeamFeeRecipient, address newTeamFeeRecipient);
    /// @notice Emitted when team fees are claimed from the factory.
    /// @param token Token that was swept.
    /// @param recipient Recipient address.
    /// @param amount Amount transferred.
    event ClaimTeamFees(address indexed token, address indexed recipient, uint256 amount);
    /// @notice Emitted when the default protocol-fee bps changes.
    /// @param oldBps Previous default.
    /// @param newBps New default.
    event DefaultProtocolFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    /// @notice Emitted when the flat ETH deploy fee changes.
    /// @param oldFee Previous fee in wei.
    /// @param newFee New fee in wei.
    event DeployFeeUpdated(uint256 oldFee, uint256 newFee);
    /// @notice Emitted when a deploy fee is paid out to the recipient.
    /// @param recipient The fee recipient (== `teamFeeRecipient` at deploy time).
    /// @param amount The fee amount paid in wei.
    event DeployFeePaid(address indexed recipient, uint256 amount);

    /// @notice Whether public deployments are disabled.
    function deprecated() external view returns (bool);
    /// @notice Atomically deploys a new token with associated pool/locker/extensions.
    /// @param deploymentConfig Full deployment configuration.
    /// @return tokenAddress Address of the newly deployed token contract.
    function deployToken(DeploymentConfig memory deploymentConfig)
        external
        payable
        returns (address tokenAddress);
    /// @notice Returns the stored deployment info for a given token.
    /// @param token The token address.
    /// @return The deployment info struct.
    function tokenDeploymentInfo(address token) external view returns (DeploymentInfo memory);
}
