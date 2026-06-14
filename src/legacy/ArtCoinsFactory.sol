// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsDeployer} from "../utils/ArtCoinsDeployer.sol";
import {OwnerAdmins} from "../utils/OwnerAdmins.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IArtCoinsExtension} from "../interfaces/IArtCoinsExtension.sol";
import {IArtCoinsFactory} from "../interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../interfaces/IArtCoinsHook.sol";
import {IArtCoinsLpLocker} from "../interfaces/IArtCoinsLpLocker.sol";
import {IArtCoinsMevModule} from "../interfaces/IArtCoinsMevModule.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ArtCoinsFactory
/// @notice ArtCoins Token Launcher Factory — deploys tokens, initializes pools and lockers,
///         and triggers extension allocations in a single atomic transaction.
/// @dev Owner controls allowed hooks, lockers, extensions, and MEV modules via allowlists.
contract ArtCoinsFactory is OwnerAdmins, ReentrancyGuard, IArtCoinsFactory {
    /// @notice Contract version.
    string public constant version = "1";

    /// @notice Default token total supply used when a deployer specifies 0 (1B tokens).
    uint256 public constant DEFAULT_TOKEN_SUPPLY = 1_000_000_000e18; // 1B
    /// @notice Minimum total supply a deployer may specify.
    uint256 public constant MIN_TOKEN_SUPPLY = 1e18; // 1 token
    /// @notice Basis-point denominator (10,000 = 100%).
    uint256 public constant BPS = 10_000;
    /// @notice Maximum number of extensions per deployment.
    uint256 public constant MAX_EXTENSIONS = 10;
    /// @notice Maximum combined extension allocation in basis points (90%).
    uint16 public constant MAX_EXTENSION_BPS = 9000;
    /// @notice Maximum allowed protocol-fee bps share (30% of LP rewards).
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 3000;
    /// @notice Hard cap on the configurable deploy fee (1 ETH).
    /// @dev Prevents a misconfiguration from pricing every deployer out of the factory.
    uint256 public constant MAX_DEPLOY_FEE = 1 ether;

    /// @notice When true, public deployments are disabled; owner/admin deploys may proceed.
    bool public deprecated;
    /// @notice Recipient for protocol/team fees claimed from the factory.
    /// @dev Should point at a stable `ProtocolFeeController` address; the factory
    ///      copies this value into the locker's reward array as the protocol slot
    ///      at deploy time. Existing pools' locker arrays are immutable thereafter,
    ///      so changing this only affects future launches.
    address public teamFeeRecipient;
    /// @notice Default protocol-fee share (in bps) injected into every new pool's
    ///         locker reward array as a dedicated "protocol slot". Defaults to
    ///         2000 (20% of trading fee) — the canonical artcoins protocol share.
    ///         Updateable by owner within `[0, MAX_PROTOCOL_FEE_BPS]`. Setting
    ///         to 0 disables injection (legacy behavior, kept as an admin escape).
    /// @dev Affects future deployments only; per-coin slots are immutable post-deploy.
    uint16 public defaultProtocolFeeBps = 2000;
    /// @notice Flat ETH fee charged on every successful `deployToken`, forwarded
    ///         to `teamFeeRecipient` at deploy time. Defaults to 0.069 ETH and
    ///         is updateable by the factory owner within `[0, MAX_DEPLOY_FEE]`.
    ///         Set to 0 to disable.
    /// @dev `msg.value` must equal exactly `deployFee + sum(extensionMsgValues)`.
    ///      The fee transfer is part of the deploy transaction, so a revert
    ///      anywhere later (extension failure, locker rejection, etc.) rolls
    ///      it back — deployers only ever pay on full success.
    uint256 public deployFee = 0.069 ether;

    /// @notice Lookup of deployment info for each deployed token.
    mapping(address token => DeploymentInfo deploymentInfo) public deploymentInfoForToken;
    /// @notice Allowlist of hooks usable for new deployments.
    mapping(address hook => bool enabled) public enabledHooks;
    /// @notice Allowlist of lockers paired with specific hooks.
    mapping(address locker => mapping(address hook => bool enabled)) public enabledLockers;
    /// @notice Allowlist of extensions invocable at deploy time.
    mapping(address extension => bool enabled) public enabledExtensions;
    /// @notice Allowlist of MEV modules bindable to a pool.
    mapping(address mevModule => bool enabled) public enabledMevModules;

    /// @param owner_ Initial owner of the factory.
    constructor(address owner_) OwnerAdmins(owner_) {
        deprecated = true;
    }

    /// @notice Enables or disables public deployments. Owner only.
    /// @param deprecated_ True to block public deploys, false to enable public deploys.
    function setDeprecated(bool deprecated_) external onlyOwner {
        deprecated = deprecated_;
        emit SetDeprecated(deprecated_);
    }

    /// @notice Sets the recipient of fees claimed via `claimTeamFees`.
    /// @param teamFeeRecipient_ The new recipient.
    function setTeamFeeRecipient(address teamFeeRecipient_) external onlyOwner {
        address old = teamFeeRecipient;
        teamFeeRecipient = teamFeeRecipient_;
        emit SetTeamFeeRecipient(old, teamFeeRecipient_);
    }

    /// @notice Sets the default protocol-fee bps injected into the locker reward
    ///         array for future deployments. Affects future launches only —
    ///         per-coin reward arrays are immutable after deploy.
    /// @dev Bounded by `MAX_PROTOCOL_FEE_BPS` (3000 = 30%) to prevent the factory
    ///      from squeezing too much of the artist's fee share.
    /// @param defaultProtocolFeeBps_ New default in basis points.
    function setDefaultProtocolFeeBps(uint16 defaultProtocolFeeBps_) external onlyOwner {
        if (defaultProtocolFeeBps_ > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeBpsTooHigh();
        uint16 old = defaultProtocolFeeBps;
        defaultProtocolFeeBps = defaultProtocolFeeBps_;
        emit DefaultProtocolFeeBpsUpdated(old, defaultProtocolFeeBps_);
    }

    /// @notice Sets the flat ETH deploy fee charged on every `deployToken`.
    ///         Set to 0 to disable. Emits `DeployFeeUpdated`.
    /// @dev Bounded by `MAX_DEPLOY_FEE` (1 ETH) to prevent a misconfiguration
    ///      from pricing all deployers out of the factory.
    /// @param deployFee_ New deploy fee in wei.
    function setDeployFee(uint256 deployFee_) external onlyOwner {
        if (deployFee_ > MAX_DEPLOY_FEE) revert DeployFeeTooHigh();
        uint256 old = deployFee;
        deployFee = deployFee_;
        emit DeployFeeUpdated(old, deployFee_);
    }

    /// @notice Owner-only escape hatch for ETH stuck in the factory.
    /// @dev `deployToken` already enforces `msg.value` matches the sum of extension
    ///      `msgValue`s, but ETH can still arrive via `selfdestruct` or pre-deploy
    ///      coinbase rewards. This sweeps the contract's ETH to a chosen recipient.
    /// @param to Recipient address.
    function recoverETH(address payable to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert EthTransferFailed();
        emit RecoverEth(to, bal);
    }

    /// @notice Sweeps `token` fees held by the factory to the configured team fee recipient.
    /// @param token The token to claim.
    function claimTeamFees(address token) external onlyOwnerOrAdmin {
        if (teamFeeRecipient == address(0)) revert TeamFeeRecipientNotSet();
        uint256 balance = IERC20(token).balanceOf(address(this));
        SafeERC20.safeTransfer(IERC20(token), teamFeeRecipient, balance);
        emit ClaimTeamFees(token, teamFeeRecipient, balance);
    }

    /// @notice Returns the stored deployment info for a given token.
    /// @param token The token address to look up.
    /// @return The deployment info struct.
    function tokenDeploymentInfo(address token) external view returns (DeploymentInfo memory) {
        return deploymentInfoForToken[token];
    }

    /// @notice Enables or disables a hook in the allowlist. Must implement IArtCoinsHook.
    /// @param hook The hook contract address.
    /// @param enabled True to allow, false to disallow.
    function setHook(address hook, bool enabled) external onlyOwnerOrAdmin {
        if (!IArtCoinsHook(hook).supportsInterface(type(IArtCoinsHook).interfaceId)) {
            revert InvalidHook();
        }
        enabledHooks[hook] = enabled;
        emit SetHook(hook, enabled);
    }

    /// @notice Enables or disables a locker for a specific hook in the allowlist.
    /// @param locker The locker contract address (must implement IArtCoinsLpLocker).
    /// @param hook The hook the locker is paired with.
    /// @param enabled True to allow, false to disallow.
    function setLocker(address locker, address hook, bool enabled) external onlyOwnerOrAdmin {
        if (!IArtCoinsLpLocker(locker).supportsInterface(type(IArtCoinsLpLocker).interfaceId)) {
            revert InvalidLocker();
        }
        enabledLockers[locker][hook] = enabled;
        emit SetLocker(locker, hook, enabled);
    }

    /// @notice Enables or disables a MEV module in the allowlist. Must implement IArtCoinsMevModule.
    /// @param mevModule The MEV module contract address.
    /// @param enabled True to allow, false to disallow.
    function setMevModule(address mevModule, bool enabled) external onlyOwnerOrAdmin {
        if (!IArtCoinsMevModule(mevModule).supportsInterface(type(IArtCoinsMevModule).interfaceId))
        {
            revert InvalidMevModule();
        }
        enabledMevModules[mevModule] = enabled;
        emit SetMevModule(mevModule, enabled);
    }

    /// @notice Enables or disables an extension in the allowlist. Must implement IArtCoinsExtension.
    /// @param extension The extension contract address.
    /// @param enabled True to allow, false to disallow.
    function setExtension(address extension, bool enabled) external onlyOwnerOrAdmin {
        if (!IArtCoinsExtension(extension).supportsInterface(type(IArtCoinsExtension).interfaceId))
        {
            revert InvalidExtension();
        }
        enabledExtensions[extension] = enabled;
        emit SetExtension(extension, enabled);
    }

    /// @notice Atomically deploys a token, initializes a pool, places liquidity, and triggers extensions.
    /// @dev `msg.value` must equal the sum of each extension's `msgValue`. Reverts if public
    ///      deploys are disabled and caller is not owner/admin, or if any configured
    ///      component is not on the allowlist.
    /// @param deploymentConfig Full deployment configuration (token, pool, locker, MEV module, extensions).
    /// @return tokenAddress The address of the newly deployed token contract.
    function deployToken(DeploymentConfig memory deploymentConfig)
        public
        payable
        nonReentrant
        returns (address tokenAddress)
    {
        if (deprecated && msg.sender != owner() && !admins[msg.sender]) {
            revert Deprecated();
        }

        // Resolve total supply: 0 = default, otherwise deployer's choice within bounds
        uint256 totalSupply = deploymentConfig.tokenConfig.totalSupply;
        if (totalSupply == 0) {
            totalSupply = DEFAULT_TOKEN_SUPPLY;
        } else {
            if (totalSupply < MIN_TOKEN_SUPPLY) revert TotalSupplyTooLow();
        }

        tokenAddress = ArtCoinsDeployer.deployToken(deploymentConfig.tokenConfig, totalSupply);

        uint256 extensionsSupply =
            _prepareExtensions(deploymentConfig.extensionConfigs, totalSupply);
        uint256 poolSupply = totalSupply - extensionsSupply;

        // Forward the flat deploy fee to teamFeeRecipient before any further
        // state changes, so a failed extension still costs the deploy fee.
        _forwardDeployFee();

        // Inject the protocol-fee slot into the locker reward array if a protocol
        // share is configured and the factory has a teamFeeRecipient set. The
        // slot's rewardAdmin is the factory itself — since the factory exposes no
        // path that calls `locker.updateRewardRecipient`, the protocol slot is
        // effectively immutable per pool. Existing pools therefore can't be
        // silently re-routed by future changes to `teamFeeRecipient`.
        deploymentConfig.lockerConfig = _injectProtocolFeeSlot(deploymentConfig.lockerConfig);

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

    /// @dev Optional deploy-time sniper-extra recipient setup. The default
    ///      zero-value config preserves legacy deployments without touching
    ///      hook storage.
    function _configureSniperFee(DeploymentConfig memory dc, PoolKey memory poolKey) internal {
        SniperFeeConfig memory cfg = dc.sniperFeeConfig;
        if (cfg.recipient == address(0) && !cfg.lockRecipient) return;
        IArtCoinsHook(dc.poolConfig.hook)
            .factorySetSniperFeeRecipient(poolKey, cfg.recipient, cfg.lockRecipient);
    }

    /// @dev Binds the MEV module to the new pool. The MEV module is OPTIONAL —
    ///      passing `address(0)` skips initialization, so a deployer who doesn't
    ///      want anti-sniper protection can opt out cleanly.
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

    /// @dev Approves the locker, places liquidity, then resets the allowance to 0
    ///      so a buggy or future-malicious locker can't drain residual balances
    ///      that may transit the factory later.
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

    /// @dev Validates extension configs, computes the aggregate supply allocation,
    ///      and enforces that `msg.value == deployFee + sum(extension.msgValue)`.
    ///      With no extensions we still require `msg.value == deployFee` (zero
    ///      if the fee is disabled), otherwise ETH would be silently trapped.
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

    /// @dev Forwards the configured `deployFee` to `teamFeeRecipient`. Called
    ///      once per `deployToken` invocation, after `msg.value` validation
    ///      but before pool/locker/extensions run. Reverts if the recipient
    ///      is unset and a fee is configured — otherwise the ETH would be
    ///      trapped. (A revert anywhere later in `deployToken` rolls this
    ///      transfer back along with the rest of the call.)
    function _forwardDeployFee() internal {
        uint256 fee = deployFee;
        if (fee == 0) return;
        address recipient = teamFeeRecipient;
        if (recipient == address(0)) revert TeamFeeRecipientNotSet();
        (bool ok,) = recipient.call{value: fee}("");
        if (!ok) revert EthTransferFailed();
        emit DeployFeePaid(recipient, fee);
    }

    /// @dev Appends a protocol-fee slot to the locker reward array. The deployer
    ///      supplies the project-side slots whose `rewardBps` must sum to
    ///      `(10_000 - defaultProtocolFeeBps)`; the factory tops them up with a
    ///      slot routing the missing bps to `teamFeeRecipient`. The slot's
    ///      `rewardAdmin` is the factory, which has no public function calling
    ///      `locker.updateRewardRecipient`, so the slot is effectively immutable
    ///      per pool. If `defaultProtocolFeeBps == 0`, no slot is injected and
    ///      the deployer's array must already sum to 10_000 (legacy behavior).
    function _injectProtocolFeeSlot(LockerConfig memory lockerConfig)
        internal
        view
        returns (LockerConfig memory)
    {
        uint16 protocolBps = defaultProtocolFeeBps;
        if (protocolBps == 0) return lockerConfig;

        // Ensure teamFeeRecipient is set — otherwise we'd inject an invalid
        // (zero-recipient) slot which the locker rejects via ZeroRewardAddress.
        if (teamFeeRecipient == address(0)) revert TeamFeeRecipientNotSet();

        // Verify project-side bps sums to (10_000 - protocolBps). The locker
        // also checks the total = 10_000 after our injection.
        uint256 projectSum = 0;
        uint256 inLen = lockerConfig.rewardBps.length;
        for (uint256 i = 0; i < inLen; i++) {
            projectSum += lockerConfig.rewardBps[i];
        }
        if (projectSum + protocolBps != BPS) revert ProjectSideBpsMismatch();

        // Append the protocol slot.
        uint256 newLen = inLen + 1;
        address[] memory newAdmins = new address[](newLen);
        address[] memory newRecipients = new address[](newLen);
        uint16[] memory newBps = new uint16[](newLen);
        for (uint256 i = 0; i < inLen; i++) {
            newAdmins[i] = lockerConfig.rewardAdmins[i];
            newRecipients[i] = lockerConfig.rewardRecipients[i];
            newBps[i] = lockerConfig.rewardBps[i];
        }
        newAdmins[inLen] = address(this); // factory: no public path to update this slot
        newRecipients[inLen] = teamFeeRecipient;
        newBps[inLen] = protocolBps;

        lockerConfig.rewardAdmins = newAdmins;
        lockerConfig.rewardRecipients = newRecipients;
        lockerConfig.rewardBps = newBps;
        return lockerConfig;
    }

    /// @dev Approves each extension for its allocation, hands tokens (and any ETH)
    ///      via `receiveTokens`, then resets the allowance to 0 to close the door
    ///      on residual approvals if the extension under-pulls.
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
