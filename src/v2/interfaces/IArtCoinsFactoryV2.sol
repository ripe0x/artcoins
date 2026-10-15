// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IConstantsBound} from "./IConstantsBound.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title  IArtCoinsFactoryV2
/// @notice Launches a coin, its native eth Uniswap v4 pool on the v2 hook, and
///         its locked liquidity in one call. The token address is a function of
///         (factory, sender, full config).
///
///         Frozen at launch: the pool, hook, locker, mev module, tick spacing,
///         the bounty share, supply and the positions. Mutable by the coin admin
///         until the coin's `lock` or admin renounce: the bounty recipient, the
///         pool extension, the baseline skim (lower only), the allowlist entries
///         and turning restriction off once. Mutable by the coin admin until
///         admin renounce: description, image and metadata renderer.
/// @dev    Units: bps = 1/10,000 (Constants.BPS). Amounts are in wei or coin base units.
///         Durations are in seconds. Functions marked owner only require the factory owner.
interface IArtCoinsFactoryV2 is IConstantsBound {
    // ── launch config ─────────────────────────────────────────────────────

    /// @notice Coin parameters.
    /// @dev    String lengths are in bytes and capped by `Constants.MAX_*_BYTES`.
    ///         A longer field reverts with the token's `StringTooLong(field, len)`.
    /// @param tokenAdmin Coin admin. Nonzero, else `ZeroAddress`.
    /// @param name ERC-20 name, at most `Constants.MAX_NAME_BYTES` bytes.
    /// @param symbol ERC-20 symbol, at most `Constants.MAX_SYMBOL_BYTES` bytes.
    /// @param salt Vanity input. Folded into `configHash`, so it changes the token address.
    /// @param image Image url, at most `Constants.MAX_IMAGE_BYTES` bytes.
    /// @param description Description, at most `Constants.MAX_DESCRIPTION_BYTES` bytes.
    /// @param totalSupply Total supply in coin base units. 0 selects
    ///        `Constants.DEFAULT_TOKEN_SUPPLY`. A nonzero value below `Constants.MIN_TOKEN_SUPPLY`
    ///        reverts `TotalSupplyTooLow`.
    /// @param renderer Renderer contract. 0 for none. A nonzero address without code reverts with
    ///        the token's `InvalidRenderer`.
    struct TokenConfigV2 {
        address tokenAdmin;
        string name;
        string symbol;
        bytes32 salt;
        string image;
        string description;
        uint256 totalSupply;
        address renderer;
    }

    /// @notice Pool parameters. The paired currency is native eth.
    /// @param hook Hook the pool is created on. Must be enabled, else `HookNotEnabled`.
    /// @param tickIfToken0IsCoin Initial tick passed to the hook's `initializePool`.
    /// @param tickSpacing Pool tick spacing. Passed to the hook and bound into the coin's canonical
    ///        pool.
    /// @param extension Initial pool extension. 0 for none. The coin admin can replace it until
    ///        `lock` or admin renounce.
    /// @param extensionData Opaque payload passed to the pool extension.
    struct PoolConfigV2 {
        address hook;
        int24 tickIfToken0IsCoin;
        int24 tickSpacing;
        address extension;
        bytes extensionData;
    }

    /// @notice Pool skim parameters. The factory injects `protocolRecipient` from its own state.
    /// @param baselineSkimBps Baseline skim in bps of swap volume. Above zero, else `ZeroFeeLaunch`;
    ///        at most `Constants.MAX_BASELINE_SKIM_BPS`, else `FeeConfigOutOfBounds`.
    /// @param bountyBps Bounty share of the skim in bps. At most `Constants.MAX_BOUNTY_BPS`, else
    ///        `BountyBpsTooHigh`. The referral rate is hook wide (`IArtCoinsHookV2.referralBps`)
    ///        and is carved from the protocol leg.
    /// @param bountyRecipient Receives the bounty leg. Nonzero, else `ZeroAddress`.
    struct FeeConfigV2 {
        uint24 baselineSkimBps;
        uint16 bountyBps;
        address payable bountyRecipient;
    }

    /// @notice Locker and liquidity layout.
    /// @param locker Locker contract. Must be enabled, else `LockerNotEnabled`.
    /// @param tickLower Lower tick of each position, parallel to `tickUpper` and `positionBps`.
    /// @param tickUpper Upper tick of each position.
    /// @param positionBps Share of the pool supply per position in bps. Sums to `Constants.BPS`.
    ///        Zero positions, more than `Constants.MAX_LP_POSITIONS` or a wrong sum reverts
    ///        `InvalidPositions`; lengths differing reverts `ArrayLengthMismatch`.
    struct LockerConfigV2 {
        address locker;
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionBps;
    }

    /// @notice Anti sniper skim parameters.
    /// @param module IArtCoinsMevSkimV2 module whose `hook()` equals `PoolConfigV2.hook` and whose
    ///        `constantsHash()` matches. 0 for none, in which case the other two fields must be 0,
    ///        else `InvalidMevConfig`.
    /// @param startingSkimBps Skim at launch in bps of swap volume. 0 selects
    ///        `Constants.DEFAULT_START_SKIM_BPS`. The resulting value is at least
    ///        `FeeConfigV2.baselineSkimBps` and at most `Constants.MAX_SKIM_BPS`, else
    ///        `InvalidMevConfig`.
    /// @param windowSeconds Skim window in seconds. 0 selects `Constants.DEFAULT_MEV_WINDOW`. The
    ///        resulting value is within [`Constants.MIN_MEV_WINDOW`, `Constants.MAX_MEV_WINDOW`],
    ///        else `InvalidMevConfig`.
    struct MevConfigV2 {
        address module;
        uint24 startingSkimBps;
        uint32 windowSeconds;
    }

    /// @notice Launch restriction. The allowlist is this launch's locker, then its
    ///         launch extensions, then `allowed`. `allowed` must be empty when
    ///         `restricted` is false.
    /// @dev    List only a contract whose coin outflows its own logic fixes, such as
    ///         an airdrop or a vault. A listed router, aggregator, multicall or smart
    ///         wallet moves coin between any two wallets, because the token checks
    ///         only the two transfer parties. Standard routers trade a restricted
    ///         coin through the per swap PoolManager allowance.
    ///         A violation reverts `InvalidRestrictionConfig`, except the
    ///         PoolManager and the pool hook, which revert with the token's
    ///         `AllowedForbidden`.
    /// @param restricted Whether the coin ships with a transfer allowlist.
    /// @param allowed Extra allowlist entries. At most `Constants.MAX_ALLOWED`, nonzero.
    struct RestrictionConfigV2 {
        bool restricted;
        address[] allowed;
    }

    /// @notice Launch extension: receives a share of supply and optional eth.
    /// @param extension Extension contract. Must be enabled, else `ExtensionNotEnabled`.
    /// @param msgValue Eth in wei forwarded to the extension.
    /// @param extensionBps Share of total supply in bps. The sum over all extensions is at most
    ///        `Constants.MAX_EXTENSION_BPS`, else `MaxExtensionBpsExceeded`.
    /// @param extensionData Opaque payload decoded by the extension.
    struct ExtensionConfigV2 {
        address extension;
        uint256 msgValue;
        uint16 extensionBps;
        bytes extensionData;
    }

    /// @notice Complete launch configuration. `configHash` of this struct is
    ///         folded into the deploy salt.
    /// @dev    More than `Constants.MAX_EXTENSIONS` extensions reverts `MaxExtensionsExceeded`.
    struct DeploymentConfigV2 {
        TokenConfigV2 token;
        PoolConfigV2 pool;
        FeeConfigV2 fee;
        LockerConfigV2 locker;
        MevConfigV2 mev;
        RestrictionConfigV2 restriction;
        ExtensionConfigV2[] extensions;
    }

    /// @notice Stored launch record for a coin.
    /// @param token The coin.
    /// @param hook Hook the pool was created on.
    /// @param locker Locker holding the liquidity.
    /// @param mevModule Anti sniper module. 0 when none.
    /// @param escrow The pool's fee escrow, read from the hook at launch.
    /// @param poolId Pool id of the coin's native eth pool.
    /// @param configHash keccak256(abi.encode(launch config)).
    /// @param version Stack version at launch.
    /// @param launchedAt Launch block timestamp in seconds.
    /// @param restricted Whether the coin was launched with a transfer allowlist.
    /// @param extensions Extensions in config order.
    struct DeploymentInfoV2 {
        address token;
        address hook;
        address locker;
        address mevModule;
        address escrow;
        PoolId poolId;
        bytes32 configHash;
        uint16 version;
        uint40 launchedAt;
        bool restricted;
        address[] extensions;
    }

    // ── events ────────────────────────────────────────────────────────────

    /// @notice Full launch record. An indexer can rebuild every frozen field from
    ///         this log.
    /// @param sender Launching account.
    /// @param token Launched coin.
    /// @param poolId Pool id of the coin's native eth pool.
    /// @param stackVersion Stack version of this factory.
    /// @param configHash keccak256(abi.encode(config)).
    /// @param protocolRecipient Protocol skim leg recipient at launch.
    /// @param poolSupply Coin amount placed in the pool, in coin base units.
    /// @param extensionsSupply Coin amount sent to extensions, in coin base units.
    /// @param config The launch configuration as submitted.
    event TokenCreatedV2(
        address indexed sender,
        address indexed token,
        PoolId indexed poolId,
        uint16 stackVersion,
        bytes32 configHash,
        address protocolRecipient,
        uint256 poolSupply,
        uint256 extensionsSupply,
        DeploymentConfigV2 config
    );

    /// @notice An extension received its supply share and eth during a launch.
    /// @param token Launched coin.
    /// @param extension Extension that ran.
    /// @param extensionSupply Coin amount the extension pulled, in coin base units.
    /// @param msgValue Eth in wei forwarded to the extension.
    event ExtensionTriggered(
        address indexed token, address indexed extension, uint256 extensionSupply, uint256 msgValue
    );

    /// @notice The deploy fee was sent to the team fee recipient during a launch.
    /// @param recipient The team fee recipient.
    /// @param amount Fee in wei.
    event DeployFeePaid(address indexed recipient, uint256 amount);

    /// @notice The owner enabled or disabled a hook.
    event HookSet(address indexed hook, bool enabled);
    /// @notice The owner enabled or disabled a locker.
    event LockerSet(address indexed locker, bool enabled);
    /// @notice The owner enabled or disabled an anti sniper module.
    event MevModuleSet(address indexed module, bool enabled);
    /// @notice The owner enabled or disabled a launch extension.
    event ExtensionSet(address indexed extension, bool enabled);
    /// @notice The CREATE2 token deployer pointer changed.
    event TokenDeployerSet(address indexed oldDeployer, address indexed newDeployer);
    /// @notice The owner changed the deprecated flag.
    event DeprecatedSet(bool deprecated);
    /// @notice The owner changed the deploy fee. Values are in wei.
    event DeployFeeSet(uint256 oldFee, uint256 newFee);
    /// @notice The owner changed the protocol recipient.
    event ProtocolRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    /// @notice The owner changed the team fee recipient.
    event TeamFeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    /// @notice The owner moved eth or an erc20 out of the factory.
    /// @param token Erc20 address, or address(0) for eth.
    /// @param to Receiver.
    /// @param amount Amount in wei or token base units.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ── errors ────────────────────────────────────────────────────────────

    /// @notice A non-owner launched while the factory is deprecated.
    error Deprecated();
    /// @notice `deploymentInfo` was called for a token this factory did not launch.
    error NotFound();
    /// @notice A launch was attempted before the token deployer was set.
    error DeployerNotSet();
    /// @notice `setTokenDeployer` target is not bound to this factory or has no code.
    error InvalidDeployer(address deployer);
    /// @notice A required address argument or config address is zero.
    error ZeroAddress();
    /// @notice The configured hook is not enabled.
    error HookNotEnabled();
    /// @notice The configured locker is not enabled.
    error LockerNotEnabled();
    /// @notice The configured anti sniper module is not enabled.
    error MevModuleNotEnabled();
    /// @notice A configured extension is not enabled.
    error ExtensionNotEnabled();
    /// @notice `setExtension` target does not answer the IArtCoinsExtensionV2 erc-165 id.
    error InvalidExtension();
    /// @notice A launched coin's canonical hook, pool id, PoolManager or restriction
    ///         flag does not match the pool the factory just created.
    error CanonicalHookMismatch();
    /// @notice The module does not answer the IArtCoinsMevSkimV2 erc-165 id, or its
    ///         `hook()` differs from the launch hook.
    error InvalidMevModule(address module);
    /// @notice The mev config is outside its bounds, or sets values with no module.
    error InvalidMevConfig();
    /// @notice `msg.value` is below the deploy fee plus the sum of extension `msgValue`.
    /// @param expected Required minimum in wei.
    /// @param sent `msg.value` in wei.
    error MsgValueMismatch(uint256 expected, uint256 sent);
    /// @notice The deploy fee exceeds `Constants.MAX_DEPLOY_FEE`.
    error DeployFeeTooHigh();
    /// @notice `bountyBps` exceeds the allowed maximum.
    /// @param bountyBps Submitted value in bps.
    /// @param max Allowed maximum in bps.
    error BountyBpsTooHigh(uint16 bountyBps, uint16 max);
    /// @notice A nonzero `totalSupply` is below `Constants.MIN_TOKEN_SUPPLY`.
    error TotalSupplyTooLow();
    /// @notice More than `Constants.MAX_EXTENSIONS` extensions.
    error MaxExtensionsExceeded();
    /// @notice Extension supply shares sum above `Constants.MAX_EXTENSION_BPS`.
    error MaxExtensionBpsExceeded();
    /// @notice The restriction config is invalid: `allowed` is set on an unrestricted
    ///         launch, holds a zero address, or the assembled allowlist exceeds
    ///         `Constants.MAX_ALLOWED`.
    error InvalidRestrictionConfig();
    /// @notice The deploy fee is nonzero and `teamFeeRecipient` is the zero address.
    error TeamFeeRecipientNotSet();
    /// @notice An eth transfer failed.
    error NativeTransferFailed();
    /// @notice A fee recipient is a contract with no way to receive eth or claim
    ///         an escrow credit: the factory, the coin, the PoolManager, the
    ///         launch's hook, locker, locker PositionManager, hook fee escrow,
    ///         token deployer, mev module, pool extension, or a launch extension
    ///         in the config.
    error RecipientCannotReceive(address recipient);

    // ── launch ────────────────────────────────────────────────────────────

    /// @notice Launches a coin.
    /// @dev    `msg.value` must be at least the deploy fee plus the sum of extension
    ///         `msgValue`, else `MsgValueMismatch`. The excess is refunded to the
    ///         sender. Reverts `Deprecated` for a non-owner while deprecated.
    /// @param c Launch configuration.
    /// @return token The launched coin.
    function deployToken(DeploymentConfigV2 calldata c) external payable returns (address token);

    /// @notice Address `deployToken(c)` yields when called by `sender`. The
    ///         result depends on the full config and the current token deployer,
    ///         since the deployer is the CREATE2 origin.
    /// @dev    Reverts `DeployerNotSet` before a token deployer is wired.
    /// @param sender Launching account.
    /// @param c Launch configuration.
    /// @return The predicted coin address.
    function predictToken(address sender, DeploymentConfigV2 calldata c)
        external
        view
        returns (address);

    /// @notice keccak256(abi.encode(c)). Folded into the deploy salt with the sender.
    /// @param c Launch configuration.
    /// @return The config hash.
    function configHash(DeploymentConfigV2 calldata c) external pure returns (bytes32);

    // ── reads ─────────────────────────────────────────────────────────────

    /// @notice Stack version tag of this factory.
    function STACK_VERSION() external view returns (uint16);

    /// @notice The CREATE2 token deployer bound to this factory.
    function tokenDeployer() external view returns (address);

    /// @notice Whether this factory launched `token`.
    function isCoin(address token) external view returns (bool);

    /// @notice The launch record for a coin.
    /// @dev    Reverts `NotFound` for a token this factory did not launch.
    function deploymentInfo(address token) external view returns (DeploymentInfoV2 memory);

    /// @notice Whether public launches are closed. The owner can still launch.
    function deprecated() external view returns (bool);

    /// @notice Flat fee in wei charged per launch and sent to `teamFeeRecipient`.
    function deployFee() external view returns (uint256);

    /// @notice Recipient of the protocol skim leg for new launches.
    function protocolRecipient() external view returns (address payable);

    /// @notice Recipient of the deploy fee.
    function teamFeeRecipient() external view returns (address);

    /// @notice Whether `hook` may be used by new launches.
    function enabledHooks(address hook) external view returns (bool);

    /// @notice Whether `locker` may be used by new launches.
    function enabledLockers(address locker) external view returns (bool);

    /// @notice Whether `module` may be used by new launches.
    function enabledMevModules(address module) external view returns (bool);

    /// @notice Whether `extension` may be used by new launches.
    function enabledExtensions(address extension) external view returns (bool);

    // ── owner ─────────────────────────────────────────────────────────────

    /// @notice Enable or disable a hook for new launches. Owner only.
    /// @dev    Enabling requires a matching `constantsHash()` (`ConstantsMismatch`)
    ///         and a hook PoolManager equal to the factory's (`PoolManagerMismatch`).
    ///         Reverts `ZeroAddress` for address(0).
    function setHook(address hook, bool enabled) external;

    /// @notice Enable or disable a locker for new launches. Owner only.
    /// @dev    Enabling requires a matching `constantsHash()` (`ConstantsMismatch`).
    ///         Reverts `ZeroAddress` for address(0).
    function setLocker(address locker, bool enabled) external;

    /// @notice Enable or disable an anti sniper module for new launches. Owner only.
    /// @dev    Enabling requires the IArtCoinsMevSkimV2 erc-165 id (`InvalidMevModule`)
    ///         and a matching `constantsHash()` (`ConstantsMismatch`).
    ///         Reverts `ZeroAddress` for address(0).
    function setMevModule(address module, bool enabled) external;

    /// @notice Enable or disable a launch extension. Owner only.
    /// @dev    Enabling requires the IArtCoinsExtensionV2 erc-165 id (`InvalidExtension`)
    ///         and a matching `constantsHash()` (`ConstantsMismatch`).
    ///         Reverts `ZeroAddress` for address(0).
    function setExtension(address extension, bool enabled) external;

    /// @notice Point the factory at a token deployer bound to it. Owner only.
    /// @dev    Reverts `InvalidDeployer` unless the deployer reports this factory
    ///         as its `factory()` and a matching `constantsHash()`.
    function setTokenDeployer(address deployer) external;

    /// @notice Close or reopen public launches. Owner only.
    function setDeprecated(bool deprecated_) external;

    /// @notice Set the flat deploy fee. Owner only.
    /// @param fee Fee in wei. Above `Constants.MAX_DEPLOY_FEE` reverts `DeployFeeTooHigh`.
    function setDeployFee(uint256 fee) external;

    /// @notice Set the protocol recipient for new launches. Owner only.
    /// @dev    Reverts `ZeroAddress` for address(0).
    function setProtocolRecipient(address payable recipient) external;

    /// @notice Set the deploy fee recipient. Owner only.
    /// @dev    address(0) is accepted. A launch with a nonzero fee then reverts
    ///         `TeamFeeRecipientNotSet`.
    function setTeamFeeRecipient(address recipient) external;

    /// @notice Sends stray eth (`token == address(0)`) or erc20 held by the factory. Owner only.
    /// @dev    Reverts `ZeroAddress` for `to == address(0)` and `NativeTransferFailed`
    ///         when an eth send fails.
    /// @param token Erc20 address, or address(0) for eth.
    /// @param to Receiver.
    /// @param amount Amount in wei or token base units.
    function rescue(address token, address to, uint256 amount) external;
}
