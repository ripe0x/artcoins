// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsDeployer} from "./utils/ArtCoinsDeployer.sol";
import {OwnerAdmins} from "./utils/OwnerAdmins.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IArtCoinsExtension} from "./interfaces/IArtCoinsExtension.sol";
import {IArtCoinsFactory} from "./interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "./interfaces/IArtCoinsHook.sol";
import {IArtCoinsLpLocker} from "./interfaces/IArtCoinsLpLocker.sol";
import {IArtCoinsMevModuleBase} from "./interfaces/IArtCoinsMevModuleBase.sol";
import {TaxConfig} from "./interfaces/IArtCoinsTaxable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  ArtCoinsFactory
/// @notice ArtCoins Token Launcher Factory. A `deployTokenWithProtocolBps(
///         config, protocolBps)` entry point lets the deployer override the
///         factory's default protocol-fee bps on a per-deploy basis; the
///         standard `deployToken(config)` uses `defaultProtocolFeeBps`.
/// @dev    Per-deploy override is bounded by the same `MAX_PROTOCOL_FEE_BPS`
///         (3000 = 30%) cap as the global setter, so deployers can't push
///         the protocol's slice past what the factory considers acceptable.
contract ArtCoinsFactory is OwnerAdmins, ReentrancyGuard, IArtCoinsFactory {
    /// @notice Contract version.
    string public constant version = "1";

    /// @notice Default token total supply used when a deployer specifies 0 (1B tokens).
    uint256 public constant DEFAULT_TOKEN_SUPPLY = 1_000_000_000e18;
    /// @notice Minimum total supply a deployer may specify.
    uint256 public constant MIN_TOKEN_SUPPLY = 1e18;
    /// @notice Basis-point denominator (10,000 = 100%).
    uint256 public constant BPS = 10_000;
    /// @notice Maximum number of extensions per deployment.
    uint256 public constant MAX_EXTENSIONS = 10;
    /// @notice Maximum combined extension allocation in basis points (90%).
    uint16 public constant MAX_EXTENSION_BPS = 9000;
    /// @notice Maximum allowed protocol-fee bps share (30% of LP rewards).
    ///         Bounds BOTH the global default setter AND the per-deploy override.
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 3000;
    /// @notice Hard cap on the configurable deploy fee (1 ETH).
    uint256 public constant MAX_DEPLOY_FEE = 1 ether;

    bool public deprecated;
    address public teamFeeRecipient;
    /// @notice Default protocol-fee share (in bps) injected into every new pool's
    ///         locker reward array as a dedicated "protocol slot" UNLESS the
    ///         deployer calls `deployTokenWithProtocolBps` with an override.
    uint16 public defaultProtocolFeeBps = 2000;
    uint256 public deployFee = 0.069 ether;

    mapping(address token => DeploymentInfo deploymentInfo) public deploymentInfoForToken;
    mapping(address hook => bool enabled) public enabledHooks;
    mapping(address locker => mapping(address hook => bool enabled)) public enabledLockers;
    mapping(address extension => bool enabled) public enabledExtensions;
    mapping(address mevModule => bool enabled) public enabledMevModules;

    constructor(address owner_) OwnerAdmins(owner_) {
        deprecated = true;
    }

    /// @notice Accepts native ETH defensively, so an unexpected native-ETH send
    ///         to the factory cannot revert. The protocol takes its cut via the
    ///         locker reward array's protocol slot, not a hook-level skim, so no
    ///         path is expected to route fees here. Any ETH that lands here can
    ///         be swept by the owner via `recoverETH(to)`.
    receive() external payable {}

    // ─── admin setters ───────────────────────────────────────────────────

    function setDeprecated(bool deprecated_) external onlyOwner {
        deprecated = deprecated_;
        emit SetDeprecated(deprecated_);
    }

    function setTeamFeeRecipient(address teamFeeRecipient_) external onlyOwner {
        address old = teamFeeRecipient;
        teamFeeRecipient = teamFeeRecipient_;
        emit SetTeamFeeRecipient(old, teamFeeRecipient_);
    }

    function setDefaultProtocolFeeBps(uint16 defaultProtocolFeeBps_) external onlyOwner {
        if (defaultProtocolFeeBps_ > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeBpsTooHigh();
        uint16 old = defaultProtocolFeeBps;
        defaultProtocolFeeBps = defaultProtocolFeeBps_;
        emit DefaultProtocolFeeBpsUpdated(old, defaultProtocolFeeBps_);
    }

    function setDeployFee(uint256 deployFee_) external onlyOwner {
        if (deployFee_ > MAX_DEPLOY_FEE) revert DeployFeeTooHigh();
        uint256 old = deployFee;
        deployFee = deployFee_;
        emit DeployFeeUpdated(old, deployFee_);
    }

    function recoverETH(address payable to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert EthTransferFailed();
        emit RecoverEth(to, bal);
    }

    function claimTeamFees(address token) external onlyOwnerOrAdmin {
        if (teamFeeRecipient == address(0)) revert TeamFeeRecipientNotSet();
        uint256 balance = IERC20(token).balanceOf(address(this));
        SafeERC20.safeTransfer(IERC20(token), teamFeeRecipient, balance);
        emit ClaimTeamFees(token, teamFeeRecipient, balance);
    }

    function tokenDeploymentInfo(address token) external view returns (DeploymentInfo memory) {
        return deploymentInfoForToken[token];
    }

    function setHook(address hook, bool enabled) external onlyOwnerOrAdmin {
        if (!IArtCoinsHook(hook).supportsInterface(type(IArtCoinsHook).interfaceId)) {
            revert InvalidHook();
        }
        enabledHooks[hook] = enabled;
        emit SetHook(hook, enabled);
    }

    function setLocker(address locker, address hook, bool enabled) external onlyOwnerOrAdmin {
        if (!IArtCoinsLpLocker(locker).supportsInterface(type(IArtCoinsLpLocker).interfaceId)) {
            revert InvalidLocker();
        }
        enabledLockers[locker][hook] = enabled;
        emit SetLocker(locker, hook, enabled);
    }

    function setMevModule(address mevModule, bool enabled) external onlyOwnerOrAdmin {
        if (!IArtCoinsMevModuleBase(mevModule)
                .supportsInterface(type(IArtCoinsMevModuleBase).interfaceId)) {
            revert InvalidMevModule();
        }
        enabledMevModules[mevModule] = enabled;
        emit SetMevModule(mevModule, enabled);
    }

    function setExtension(address extension, bool enabled) external onlyOwnerOrAdmin {
        if (!IArtCoinsExtension(extension).supportsInterface(type(IArtCoinsExtension).interfaceId))
        {
            revert InvalidExtension();
        }
        enabledExtensions[extension] = enabled;
        emit SetExtension(extension, enabled);
    }

    // ─── deploy entry points ─────────────────────────────────────────────

    /// @notice Atomically deploys a token using the factory's `defaultProtocolFeeBps`.
    function deployToken(DeploymentConfig memory deploymentConfig)
        public
        payable
        nonReentrant
        returns (address tokenAddress)
    {
        TaxConfig memory noTax;
        return _doDeploy(deploymentConfig, defaultProtocolFeeBps, noTax);
    }

    /// @notice Atomically deploys a token with a per-deploy protocol-fee bps
    ///         override. Bounded by `MAX_PROTOCOL_FEE_BPS` (same cap as the
    ///         global setter). Use this when a specific launch needs a
    ///         different protocol share than the factory default (e.g.
    ///         lowering the LAYER cut for a flagship deploy).
    /// @param  deploymentConfig Full deployment configuration.
    /// @param  protocolBpsOverride Protocol slot bps for THIS deploy only.
    ///         Pass 0 to disable the protocol slot entirely (deployer's
    ///         project-side bps must then sum to 10_000).
    /// @return tokenAddress The address of the newly deployed token contract.
    function deployTokenWithProtocolBps(
        DeploymentConfig memory deploymentConfig,
        uint16 protocolBpsOverride
    ) public payable nonReentrant returns (address tokenAddress) {
        if (protocolBpsOverride > MAX_PROTOCOL_FEE_BPS) {
            revert ProtocolFeeBpsTooHigh();
        }
        TaxConfig memory noTax;
        return _doDeploy(deploymentConfig, protocolBpsOverride, noTax);
    }

    /// @notice Variant of `deployTokenWithProtocolBps` that ALSO configures a
    ///         venue-scoped buy-side transfer tax on the deployed token. The
    ///         tax is a default-off feature: pass an `enabled = false`
    ///         `taxConfig` and the token behaves identically to the standard
    ///         path. Currently used only by PERMANENT COLLECTION's 111PUNKS
    ///         launch. `taxConfig` fields are token-INDEPENDENT (venue pool
    ///         addresses + the canonical pool id are derived inside the token
    ///         constructor from `address(this)`), so there is no CREATE2
    ///         circular dependency.
    /// @param  deploymentConfig Same shape as `deployTokenWithProtocolBps`.
    /// @param  protocolBpsOverride Protocol slot bps for THIS deploy only.
    /// @param  taxConfig Venue-scoped transfer-tax configuration.
    /// @return tokenAddress The address of the newly deployed token contract.
    function deployTokenWithProtocolBpsAndTax(
        DeploymentConfig memory deploymentConfig,
        uint16 protocolBpsOverride,
        TaxConfig memory taxConfig
    ) public payable nonReentrant returns (address tokenAddress) {
        if (protocolBpsOverride > MAX_PROTOCOL_FEE_BPS) {
            revert ProtocolFeeBpsTooHigh();
        }
        return _doDeploy(deploymentConfig, protocolBpsOverride, taxConfig);
    }

    /// @dev Shared deploy implementation. The `protocolBps` parameter is the
    ///      bps used for the protocol slot injection — comes from either the
    ///      global default (via `deployToken`) or the per-deploy override
    ///      (via `deployTokenWithProtocolBps[AndTax]`). `taxConfig` is dormant
    ///      (`enabled = false`) for every path except
    ///      `deployTokenWithProtocolBpsAndTax`.
    function _doDeploy(
        DeploymentConfig memory deploymentConfig,
        uint16 protocolBps,
        TaxConfig memory taxConfig
    ) internal returns (address tokenAddress) {
        if (deprecated && msg.sender != owner() && !admins[msg.sender]) {
            revert Deprecated();
        }

        uint256 totalSupply = deploymentConfig.tokenConfig.totalSupply;
        if (totalSupply == 0) {
            totalSupply = DEFAULT_TOKEN_SUPPLY;
        } else {
            if (totalSupply < MIN_TOKEN_SUPPLY) revert TotalSupplyTooLow();
        }

        tokenAddress = ArtCoinsDeployer.deployTokenWithTax(
            deploymentConfig.tokenConfig, totalSupply, taxConfig
        );

        uint256 extensionsSupply =
            _prepareExtensions(deploymentConfig.extensionConfigs, totalSupply);
        uint256 poolSupply = totalSupply - extensionsSupply;

        _forwardDeployFee();

        deploymentConfig.lockerConfig =
            _injectProtocolFeeSlot(deploymentConfig.lockerConfig, protocolBps);

        PoolKey memory poolKey = _initializePool({
            poolConfig: deploymentConfig.poolConfig,
            locker: deploymentConfig.lockerConfig.locker,
            mevModule: deploymentConfig.mevModuleConfig.mevModule,
            newToken: tokenAddress
        });

        _configureSniperFee(deploymentConfig, poolKey);

        _initializeLiquidity(
            deploymentConfig.lockerConfig,
            deploymentConfig.poolConfig,
            poolKey,
            poolSupply,
            tokenAddress
        );

        _triggerExtensions(deploymentConfig, poolKey, tokenAddress, totalSupply);
        _initializeMevModule(deploymentConfig, poolKey);

        address[] memory extensions = new address[](deploymentConfig.extensionConfigs.length);
        for (uint256 i = 0; i < deploymentConfig.extensionConfigs.length; i++) {
            extensions[i] = deploymentConfig.extensionConfigs[i].extension;
        }

        deploymentInfoForToken[tokenAddress] = DeploymentInfo({
            locker: deploymentConfig.lockerConfig.locker,
            token: tokenAddress,
            hook: deploymentConfig.poolConfig.hook,
            extensions: extensions
        });

        emit TokenCreated({
            msgSender: msg.sender,
            tokenAddress: tokenAddress,
            tokenAdmin: deploymentConfig.tokenConfig.tokenAdmin,
            tokenMetadata: deploymentConfig.tokenConfig.metadata,
            tokenImage: deploymentConfig.tokenConfig.image,
            tokenName: deploymentConfig.tokenConfig.name,
            tokenSymbol: deploymentConfig.tokenConfig.symbol,
            tokenContext: deploymentConfig.tokenConfig.context,
            poolHook: deploymentConfig.poolConfig.hook,
            poolId: poolKey.toId(),
            startingTick: deploymentConfig.poolConfig.tickIfToken0IsArtCoins,
            pairedToken: deploymentConfig.poolConfig.pairedToken,
            locker: deploymentConfig.lockerConfig.locker,
            mevModule: deploymentConfig.mevModuleConfig.mevModule,
            extensionsSupply: extensionsSupply,
            extensions: extensions
        });
    }

    function _configureSniperFee(DeploymentConfig memory dc, PoolKey memory poolKey) internal {
        SniperFeeConfig memory cfg = dc.sniperFeeConfig;
        if (cfg.recipient == address(0) && !cfg.lockRecipient) return;
        IArtCoinsHook(dc.poolConfig.hook)
            .factorySetSniperFeeRecipient(poolKey, cfg.recipient, cfg.lockRecipient);
    }

    function _initializeMevModule(DeploymentConfig memory dc, PoolKey memory poolKey) internal {
        address mod = dc.mevModuleConfig.mevModule;
        if (mod == address(0)) return;
        if (!enabledMevModules[mod]) revert MevModuleNotEnabled();
        IArtCoinsHook(dc.poolConfig.hook)
            .initializeMevModule(poolKey, dc.mevModuleConfig.mevModuleData);
    }

    function _initializePool(
        PoolConfig memory poolConfig,
        address locker,
        address mevModule,
        address newToken
    ) internal returns (PoolKey memory poolKey) {
        if (!enabledHooks[poolConfig.hook]) revert HookNotEnabled();
        poolKey = IArtCoinsHook(poolConfig.hook)
            .initializePool(
                newToken,
                poolConfig.pairedToken,
                poolConfig.tickIfToken0IsArtCoins,
                poolConfig.tickSpacing,
                locker,
                mevModule,
                poolConfig.poolData
            );
    }

    function _initializeLiquidity(
        LockerConfig memory lockerConfig,
        PoolConfig memory poolConfig,
        PoolKey memory poolKey,
        uint256 poolSupply,
        address token
    ) internal {
        if (!enabledLockers[lockerConfig.locker][poolConfig.hook]) {
            revert LockerNotEnabled();
        }
        SafeERC20.forceApprove(IERC20(token), address(lockerConfig.locker), poolSupply);
        IArtCoinsLpLocker(lockerConfig.locker)
            .placeLiquidity(lockerConfig, poolConfig, poolKey, poolSupply, token);
        SafeERC20.forceApprove(IERC20(token), address(lockerConfig.locker), 0);
    }

    function _prepareExtensions(ExtensionConfig[] memory extensions, uint256 totalSupply)
        internal
        view
        returns (uint256 extensionSupply)
    {
        uint256 fee = deployFee;

        if (extensions.length == 0) {
            if (msg.value != fee) revert ExtensionMsgValueMismatch();
            return 0;
        }
        if (extensions.length > MAX_EXTENSIONS) revert MaxExtensionsExceeded();

        uint256 pct = 0;
        uint256 eth = 0;
        for (uint256 i = 0; i < extensions.length; i++) {
            pct += extensions[i].extensionBps;
            eth += extensions[i].msgValue;
            if (!enabledExtensions[extensions[i].extension]) revert ExtensionNotEnabled();
        }
        if (pct > MAX_EXTENSION_BPS) revert MaxExtensionBpsExceeded();
        if (eth + fee != msg.value) revert ExtensionMsgValueMismatch();

        extensionSupply = pct * totalSupply / BPS;
    }

    function _forwardDeployFee() internal {
        uint256 fee = deployFee;
        if (fee == 0) return;
        address recipient = teamFeeRecipient;
        if (recipient == address(0)) revert TeamFeeRecipientNotSet();
        (bool ok,) = recipient.call{value: fee}("");
        if (!ok) revert EthTransferFailed();
        emit DeployFeePaid(recipient, fee);
    }

    /// @dev Appends a protocol-fee slot to the locker reward array using the
    ///      supplied `protocolBps`. This variant takes the bps
    ///      as a parameter rather than reading from storage — enabling
    ///      per-deploy overrides via `deployTokenWithProtocolBps`.
    function _injectProtocolFeeSlot(LockerConfig memory lockerConfig, uint16 protocolBps)
        internal
        view
        returns (LockerConfig memory)
    {
        if (protocolBps == 0) return lockerConfig;

        if (teamFeeRecipient == address(0)) revert TeamFeeRecipientNotSet();

        uint256 projectSum = 0;
        uint256 inLen = lockerConfig.rewardBps.length;
        for (uint256 i = 0; i < inLen; i++) {
            projectSum += lockerConfig.rewardBps[i];
        }
        if (projectSum + protocolBps != BPS) revert ProjectSideBpsMismatch();

        uint256 newLen = inLen + 1;
        address[] memory newAdmins = new address[](newLen);
        address[] memory newRecipients = new address[](newLen);
        uint16[] memory newBps = new uint16[](newLen);
        for (uint256 i = 0; i < inLen; i++) {
            newAdmins[i] = lockerConfig.rewardAdmins[i];
            newRecipients[i] = lockerConfig.rewardRecipients[i];
            newBps[i] = lockerConfig.rewardBps[i];
        }
        newAdmins[inLen] = address(this);
        newRecipients[inLen] = teamFeeRecipient;
        newBps[inLen] = protocolBps;

        lockerConfig.rewardAdmins = newAdmins;
        lockerConfig.rewardRecipients = newRecipients;
        lockerConfig.rewardBps = newBps;
        return lockerConfig;
    }

    function _triggerExtensions(
        DeploymentConfig memory dc,
        PoolKey memory poolKey,
        address token,
        uint256 totalSupply
    ) internal {
        for (uint256 i = 0; i < dc.extensionConfigs.length; i++) {
            uint256 supply = dc.extensionConfigs[i].extensionBps * totalSupply / BPS;
            address extension = dc.extensionConfigs[i].extension;
            SafeERC20.forceApprove(IERC20(token), extension, supply);
            IArtCoinsExtension(extension).receiveTokens{value: dc.extensionConfigs[i].msgValue}(
                dc, poolKey, token, supply, i
            );
            SafeERC20.forceApprove(IERC20(token), extension, 0);
            emit ExtensionTriggered(extension, supply, dc.extensionConfigs[i].msgValue);
        }
    }
}
