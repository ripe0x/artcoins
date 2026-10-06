// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../Constants.sol";
import {ArtCoinsTokenV2} from "./ArtCoinsTokenV2.sol";
import {IArtCoinsExtensionV2} from "./interfaces/IArtCoinsExtensionV2.sol";
import {IArtCoinsFactoryV2} from "./interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "./interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsLpLockerV2} from "./interfaces/IArtCoinsLpLockerV2.sol";
import {IArtCoinsMevSkimV2} from "./interfaces/IArtCoinsMevSkimV2.sol";
import {IArtCoinsTokenV2} from "./interfaces/IArtCoinsTokenV2.sol";
import {IConstantsBound} from "./interfaces/IConstantsBound.sol";
import {ArtCoinsDeployerV2} from "./utils/ArtCoinsDeployerV2.sol";

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev v4-periphery `BaseHook` exposes its PoolManager as a public immutable.
interface IHookPoolManager {
    function poolManager() external view returns (address);
}

/// @title  ArtCoinsFactoryV2
/// @notice Launches an art coin, its native eth Uniswap v4 pool on the v2 hook
///         and its locked liquidity in one call. Every per coin value is frozen
///         in the launch tx. The token address is a function of
///         (factory, sender, full config): salt = keccak256(abi.encode(sender, configHash(c))).
///
///         Launch flow (`deployToken`, `deployTokenAsOwner`):
///         1. deprecated gate (owner bypasses).
///         2. config validated against `Constants` and factory state.
///         3. `msg.value >= deployFee + sum(extension msgValue)`; the excess is
///            refunded to the sender at the end of the call.
///         4. token deployed by CREATE2 with the sender bound salt.
///         5. `hook.initializePool` with the skim config; protocolRecipient and
///            referralPayout are injected from factory storage. The token's
///            canonical hook, pool id, PoolManager, tax mode and sink are
///            checked against the pool just created (FT-06).
///         6. launch record (`isArtCoin`, `deploymentInfo`) written.
///         7. pool supply approved to the locker, `placeLiquidity` with the
///            protocol slot appended; the locker must pull exactly the pool supply.
///         8. extensions: each gets exactly its own `msgValue` and its own
///            supply share, and must pull exactly that share.
///         9. `hook.initializeMevModule`, always (after extensions, as v1: a
///            launch extension such as a dev buy is the deployer's own action;
///            the call also runs the pool extension's post locker setup).
///         10. `TokenCreatedV2` with the full config; deploy fee pushed to
///            `teamFeeRecipient`; excess eth refunded to the sender.
///
///         Supply rounding: each extension gets `floor(bps * supply / BPS)`;
///         the pool supply is `supply - sum(extension shares)`, so rounding
///         dust goes to the pool. The factory holds no coin after a launch.
///         Eth: the factory holds no eth after a launch (fee pushed, excess
///         refunded). It has no `receive`; stray eth (forced sends) or erc20
///         can be moved by the owner with `rescue`.
contract ArtCoinsFactoryV2 is IArtCoinsFactoryV2, Ownable2Step, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // ── additive errors (not in the frozen interface) ────────────────────

    /// @notice Parallel arrays of different lengths (FT-10).
    error ArrayLengthMismatch();
    /// @notice Position count is 0 or above `Constants.MAX_LP_POSITIONS`, or position bps do not sum to BPS.
    error InvalidPositions();
    /// @notice Reward slot count (project slots plus protocol slot) is 0 or above
    ///         `Constants.MAX_REWARD_PARTICIPANTS`, or a project slot has 0 bps.
    error InvalidRewardSlots();
    /// @notice lpFee, baselineSkimBps or maxReferralBpsOfVolume above its Constants cap.
    error FeeConfigOutOfBounds();
    /// @notice The hook answers a different PoolManager than the factory's.
    error PoolManagerMismatch(address hook);
    /// @notice An extension or the locker did not pull exactly its share.
    error SupplyNotPulled(address puller);
    /// @notice Ownership cannot be renounced (FT-13).
    error RenounceDisabled();

    // ── immutables ────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsFactoryV2
    uint16 public constant STACK_VERSION = Constants.STACK_VERSION;

    /// @dev D30 string caps, equal to `ArtCoinsTokenV2.MAX_*_BYTES` (the test
    ///      suite asserts the match).
    uint256 private constant _MAX_NAME = 64;
    uint256 private constant _MAX_SYMBOL = 16;
    uint256 private constant _MAX_IMAGE = 2048;
    uint256 private constant _MAX_METADATA = 4096;
    uint256 private constant _MAX_CONTEXT = 4096;

    /// @notice The Uniswap v4 PoolManager every enabled hook must answer.
    address public immutable poolManager;
    /// @notice CREATE2 token deployer, created in this constructor and bound to this factory.
    ArtCoinsDeployerV2 public immutable tokenDeployer;

    // ── owner state ───────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsFactoryV2
    bool public deprecated;
    /// @inheritdoc IArtCoinsFactoryV2
    uint16 public defaultProtocolFeeBps;
    /// @inheritdoc IArtCoinsFactoryV2
    uint16 public minProtocolSkimShareBps;
    /// @inheritdoc IArtCoinsFactoryV2
    uint256 public deployFee;
    /// @inheritdoc IArtCoinsFactoryV2
    address payable public protocolRecipient;
    /// @inheritdoc IArtCoinsFactoryV2
    address payable public referralPayout;
    /// @inheritdoc IArtCoinsFactoryV2
    address public teamFeeRecipient;

    /// @inheritdoc IArtCoinsFactoryV2
    mapping(address => bool) public enabledHooks;
    /// @inheritdoc IArtCoinsFactoryV2
    mapping(address => bool) public enabledLockers;
    /// @inheritdoc IArtCoinsFactoryV2
    mapping(address => bool) public enabledMevModules;
    /// @inheritdoc IArtCoinsFactoryV2
    mapping(address => bool) public enabledExtensions;
    /// @inheritdoc IArtCoinsFactoryV2
    mapping(address => bool) public enabledEscrows;

    // ── launch records ────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsFactoryV2
    mapping(address => bool) public isArtCoin;
    mapping(address => DeploymentInfoV2) internal _deploymentInfo;

    /// @param owner_         Initial owner (Ownable2Step).
    /// @param poolManager_   Uniswap v4 PoolManager.
    /// @param protocolBps_   Initial `defaultProtocolFeeBps` (<= MAX_PROTOCOL_FEE_BPS).
    /// @param deployFee_     Initial `deployFee` (<= MAX_DEPLOY_FEE).
    /// @dev   Ships deprecated; the owner flips it after wiring.
    constructor(address owner_, address poolManager_, uint16 protocolBps_, uint256 deployFee_)
        Ownable(owner_)
    {
        if (poolManager_ == address(0)) revert ZeroAddress();
        if (protocolBps_ > Constants.MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeBpsTooHigh();
        if (deployFee_ > Constants.MAX_DEPLOY_FEE) revert DeployFeeTooHigh();
        poolManager = poolManager_;
        tokenDeployer = new ArtCoinsDeployerV2(address(this));
        defaultProtocolFeeBps = protocolBps_;
        deployFee = deployFee_;
        deprecated = true;
        emit DeprecatedSet(true);
        emit DefaultProtocolFeeBpsSet(0, protocolBps_);
        emit DeployFeeSet(0, deployFee_);
    }

    // ══════════════════════════════════════════════════════════════════════
    // launch
    // ══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IArtCoinsFactoryV2
    /// @dev Uses `defaultProtocolFeeBps`. `msg.value` must be at least
    ///      `deployFee + sum(extension msgValue)`; any excess is refunded to the sender.
    function deployToken(DeploymentConfigV2 calldata c)
        external
        payable
        nonReentrant
        returns (address token)
    {
        return _launch(c, defaultProtocolFeeBps);
    }

    /// @inheritdoc IArtCoinsFactoryV2
    /// @dev Owner only (FT-03). `protocolBps` in [0, MAX_PROTOCOL_FEE_BPS]; 0 appends no protocol slot.
    function deployTokenAsOwner(DeploymentConfigV2 calldata c, uint16 protocolBps)
        external
        payable
        onlyOwner
        nonReentrant
        returns (address token)
    {
        if (protocolBps > Constants.MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeBpsTooHigh();
        return _launch(c, protocolBps);
    }

    /// @inheritdoc IArtCoinsFactoryV2
    function predictToken(address sender, DeploymentConfigV2 calldata c)
        external
        view
        returns (address)
    {
        return tokenDeployer.predict(
            c.token, _supply(c.token.totalSupply), c.tax, _canon(c), address(this), _salt(sender, c)
        );
    }

    /// @inheritdoc IArtCoinsFactoryV2
    function configHash(DeploymentConfigV2 calldata c) public pure returns (bytes32) {
        return keccak256(abi.encode(c));
    }

    function _canon(DeploymentConfigV2 calldata c)
        internal
        view
        returns (ArtCoinsTokenV2.CanonicalPool memory)
    {
        return ArtCoinsTokenV2.CanonicalPool({
            hook: c.pool.hook,
            poolManager: poolManager,
            tickSpacing: c.pool.tickSpacing,
            bountyRecipient: c.fee.bountyRecipient
        });
    }

    function _salt(address sender, DeploymentConfigV2 calldata c) internal pure returns (bytes32) {
        return keccak256(abi.encode(sender, configHash(c)));
    }

    function _supply(uint256 requested) internal pure returns (uint256) {
        if (requested == 0) return Constants.DEFAULT_TOKEN_SUPPLY;
        if (requested < Constants.MIN_TOKEN_SUPPLY) revert TotalSupplyTooLow();
        return requested;
    }

    function _launch(DeploymentConfigV2 calldata c, uint16 protocolBps)
        internal
        returns (address token)
    {
        if (deprecated && msg.sender != owner()) revert Deprecated();

        uint256 supply = _supply(c.token.totalSupply);
        (uint256 extensionsSupply, uint256 extensionsValue) = _validate(c, supply, protocolBps);

        uint256 fee = deployFee;
        uint256 required = fee + extensionsValue;
        if (msg.value < required) revert MsgValueMismatch(required, msg.value);

        bytes32 h = configHash(c);
        token = tokenDeployer.deploy(
            c.token, supply, c.tax, _canon(c), address(this), keccak256(abi.encode(msg.sender, h))
        );

        PoolKey memory poolKey = _initializePool(c, token);
        PoolId poolId = poolKey.toId();
        _checkCanonical(c, token, poolId);

        _record(c, token, poolId);

        uint256 poolSupply = supply - extensionsSupply;
        _placeLiquidity(c, poolKey, poolSupply, token, protocolBps);
        _runExtensions(c, poolKey, token, supply);

        // always called: it also runs the pool extension's post locker setup
        // and arms the hook's per pool `started` flag. Empty config when there
        // is no module (the hook skips the module call).
        IArtCoinsHookV2(c.pool.hook)
            .initializeMevModule(
                poolKey,
                c.mev.module == address(0)
                    ? bytes("")
                    : abi.encode(c.mev.startingSkimBps, c.mev.windowSeconds)
            );

        emit TokenCreatedV2(
            msg.sender,
            token,
            poolId,
            STACK_VERSION,
            h,
            protocolRecipient,
            referralPayout,
            protocolBps,
            poolSupply,
            extensionsSupply,
            c
        );

        _settleEth(fee, msg.value - required);
    }

    // ── validation ────────────────────────────────────────────────────────

    /// @return extensionsSupply Sum of per extension floors.
    /// @return extensionsValue  Sum of extension msgValue.
    function _validate(DeploymentConfigV2 calldata c, uint256 supply, uint16 protocolBps)
        internal
        view
        returns (uint256 extensionsSupply, uint256 extensionsValue)
    {
        if (c.token.tokenAdmin == address(0)) revert ZeroAddress();
        // mirrors the token constructor so the revert is clear (not DeployFailed)
        if (c.token.renderer != address(0) && c.token.renderer.code.length == 0) {
            revert IArtCoinsTokenV2.InvalidRenderer();
        }
        _validateStrings(c.token);
        if (!enabledHooks[c.pool.hook]) revert HookNotEnabled();
        if (protocolRecipient == address(0) || referralPayout == address(0)) revert ZeroAddress();

        _validateFee(c.fee);
        _validateLocker(c.locker, protocolBps);
        _validateMev(c.mev, c.pool.hook, c.fee.baselineSkimBps);
        _validateTax(c.tax, c.fee.bountyRecipient);
        return _validateExtensions(c.extensions, supply);
    }

    /// @dev D30: the token's own string caps, checked up front so a long
    ///      field fails with the token's `StringTooLong(field, len)` before any
    ///      deploy work. Field codes match `ArtCoinsTokenV2.FIELD_*`.
    function _validateStrings(TokenConfigV2 calldata t) internal pure {
        _cap(bytes(t.name).length, _MAX_NAME, 0);
        _cap(bytes(t.symbol).length, _MAX_SYMBOL, 1);
        _cap(bytes(t.image).length, _MAX_IMAGE, 2);
        _cap(bytes(t.metadata).length, _MAX_METADATA, 3);
        _cap(bytes(t.context).length, _MAX_CONTEXT, 4);
    }

    function _cap(uint256 len, uint256 max, uint8 field) internal pure {
        if (len > max) revert IArtCoinsTokenV2.StringTooLong(field, len);
    }

    function _validateFee(FeeConfigV2 calldata f) internal view {
        if (f.bountyRecipient == address(0)) revert ZeroAddress();
        if (
            f.lpFee > Constants.MAX_LP_FEE || f.baselineSkimBps > Constants.MAX_BASELINE_SKIM_BPS
                || f.maxReferralBpsOfVolume > Constants.MAX_REFERRAL_CAP_OF_VOLUME
        ) revert FeeConfigOutOfBounds();
        uint256 maxBounty = Constants.BPS - minProtocolSkimShareBps;
        if (maxBounty > Constants.MAX_BOUNTY_BPS) maxBounty = Constants.MAX_BOUNTY_BPS;
        // casting to uint16 is safe: maxBounty <= MAX_BOUNTY_BPS (9999)
        // forge-lint: disable-next-line(unsafe-typecast)
        if (f.bountyBps > maxBounty) revert BountyBpsTooHigh(f.bountyBps, uint16(maxBounty));
    }

    function _validateLocker(LockerConfigV2 calldata l, uint16 protocolBps) internal view {
        if (!enabledLockers[l.locker]) revert LockerNotEnabled();

        // reward split (FT-10: lengths must match before the protocol slot is appended)
        uint256 n = l.rewardRecipients.length;
        if (n != l.rewardBps.length) revert ArrayLengthMismatch();
        uint256 slots = n + (protocolBps == 0 ? 0 : 1);
        if (slots == 0 || slots > Constants.MAX_REWARD_PARTICIPANTS) revert InvalidRewardSlots();
        uint256 sum = protocolBps;
        for (uint256 i; i < n; ++i) {
            if (l.rewardRecipients[i] == address(0)) revert ZeroAddress();
            if (l.rewardBps[i] == 0) revert InvalidRewardSlots();
            sum += l.rewardBps[i];
        }
        if (sum != Constants.BPS) revert ProjectSideBpsMismatch();

        // positions
        uint256 p = l.tickLower.length;
        if (p != l.tickUpper.length || p != l.positionBps.length) revert ArrayLengthMismatch();
        if (p == 0 || p > Constants.MAX_LP_POSITIONS) revert InvalidPositions();
        sum = 0;
        for (uint256 i; i < p; ++i) {
            sum += l.positionBps[i];
        }
        if (sum != Constants.BPS) revert InvalidPositions();
    }

    function _validateMev(MevConfigV2 calldata m, address hook, uint24 baseline) internal view {
        if (m.module == address(0)) {
            if (m.startingSkimBps != 0 || m.windowSeconds != 0) revert InvalidMevConfig();
            return;
        }
        if (!enabledMevModules[m.module]) revert MevModuleNotEnabled();
        if (IArtCoinsMevSkimV2(m.module).hook() != hook) revert InvalidMevModule(m.module);
        if (
            m.windowSeconds < Constants.MIN_MEV_WINDOW || m.windowSeconds > Constants.MAX_MEV_WINDOW
                || m.startingSkimBps > Constants.MAX_SKIM_BPS || m.startingSkimBps < baseline
        ) revert InvalidMevConfig();
    }

    /// @dev d4 / D10: a sink is DEAD or the bounty recipient. Mirrors the token's
    ///      constructor rules so a bad config fails here with a factory error:
    ///      NONE carries no tax data (the launch event never shows a tax that does
    ///      not exist); VENUE needs 0 < taxBpsMax <= TAX_BPS_ABSOLUTE_MAX and
    ///      taxBps <= taxBpsMax; HARD has no rate and no exempt set, its sink is
    ///      display only and may be 0.
    function _validateTax(TaxConfigV2 calldata t, address bountyRecipient) internal view {
        uint8 mode = t.mode;
        if (mode == Constants.TAX_MODE_NONE) {
            if (
                t.taxBps != 0 || t.taxBpsMax != 0 || t.taxSink != address(0)
                    || t.venueAdmin != address(0) || t.exempt.length != 0 || t.venues.length != 0
            ) revert InvalidTaxConfig();
            return;
        }
        if (mode == Constants.TAX_MODE_VENUE) {
            if (
                t.taxBpsMax == 0 || t.taxBpsMax > Constants.TAX_BPS_ABSOLUTE_MAX
                    || t.taxBps > t.taxBpsMax
            ) revert InvalidTaxConfig();
            if (t.taxSink != Constants.DEAD && t.taxSink != bountyRecipient) {
                revert TaxSinkNotAllowed(t.taxSink);
            }
        } else if (mode == Constants.TAX_MODE_HARD) {
            if (t.taxBps != 0 || t.taxBpsMax != 0 || t.exempt.length != 0) {
                revert InvalidTaxConfig();
            }
            if (
                t.taxSink != address(0) && t.taxSink != Constants.DEAD
                    && t.taxSink != bountyRecipient
            ) revert TaxSinkNotAllowed(t.taxSink);
        } else {
            revert InvalidTaxConfig();
        }
        if (
            t.exempt.length > Constants.MAX_TAX_EXEMPT || t.venues.length > Constants.MAX_TAX_VENUES
        ) {
            revert InvalidTaxConfig();
        }
        // mirrors the token (FT-07): exempt entries are contracts that exist at
        // launch (so never the token itself) and appear once.
        uint256 n = t.exempt.length;
        for (uint256 i; i < n; ++i) {
            address a = t.exempt[i];
            if (a.code.length == 0) revert InvalidTaxConfig();
            for (uint256 j; j < i; ++j) {
                if (t.exempt[j] == a) revert InvalidTaxConfig();
            }
        }
        // mirrors `TaxVenues.derive` and the token's duplicate check: a known
        // kind, a nonzero pair factory, and no two entries deriving the same
        // pool (kind 1 ignores v3Fee). Bounded: n <= MAX_TAX_VENUES.
        n = t.venues.length;
        bytes32[] memory keys = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            TaxVenue calldata v = t.venues[i];
            if ((v.kind != 1 && v.kind != 2) || v.factory == address(0)) revert InvalidTaxConfig();
            bytes32 k = keccak256(
                abi.encode(v.kind, v.factory, v.initCodeHash, v.counterToken, v.kind == 2 ? v.v3Fee : 0)
            );
            for (uint256 j; j < i; ++j) {
                if (keys[j] == k) revert InvalidTaxConfig();
            }
            keys[i] = k;
        }
    }

    function _validateExtensions(ExtensionConfigV2[] calldata e, uint256 supply)
        internal
        view
        returns (uint256 extensionsSupply, uint256 extensionsValue)
    {
        uint256 n = e.length;
        if (n > Constants.MAX_EXTENSIONS) revert MaxExtensionsExceeded();
        uint256 bps;
        for (uint256 i; i < n; ++i) {
            if (!enabledExtensions[e[i].extension]) revert ExtensionNotEnabled();
            bps += e[i].extensionBps;
            extensionsValue += e[i].msgValue;
            extensionsSupply += e[i].extensionBps * supply / Constants.BPS;
        }
        if (bps > Constants.MAX_EXTENSION_BPS) revert MaxExtensionBpsExceeded();
    }

    // ── launch steps ──────────────────────────────────────────────────────

    function _initializePool(DeploymentConfigV2 calldata c, address token)
        internal
        returns (PoolKey memory)
    {
        IArtCoinsHookV2.PoolInitParams memory p;
        p.token = token;
        p.tickIfToken0IsArtCoin = c.pool.tickIfToken0IsArtCoin;
        p.tickSpacing = c.pool.tickSpacing;
        p.locker = c.locker.locker;
        p.mevModule = c.mev.module;
        p.extension = c.pool.extension;
        p.extensionData = c.pool.extensionData;
        p.skim = IArtCoinsHookV2.SkimConfig({
            baselineSkimBps: c.fee.baselineSkimBps,
            bountyBps: c.fee.bountyBps,
            maxReferralBpsOfVolume: c.fee.maxReferralBpsOfVolume,
            lpFee: c.fee.lpFee,
            bountyRecipient: c.fee.bountyRecipient,
            protocolRecipient: protocolRecipient,
            referralPayout: referralPayout,
            quoteToken: address(0)
        });
        return IArtCoinsHookV2(c.pool.hook).initializePool(p);
    }

    /// @dev FT-06: the token's canonical pool must be the pool this factory just created.
    ///      The token derives it from the same hook, tickSpacing and PoolManager, so
    ///      this is a cross check that also catches a hook that keys pools differently.
    function _checkCanonical(DeploymentConfigV2 calldata c, address token, PoolId poolId)
        internal
        view
    {
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(token);
        if (
            t.canonicalHook() != c.pool.hook || t.canonicalPoolId() != PoolId.unwrap(poolId)
                || t.poolManager() != poolManager || t.taxMode() != c.tax.mode
                || t.taxSink() != c.tax.taxSink
        ) revert InvalidTaxConfig();
    }

    function _record(DeploymentConfigV2 calldata c, address token, PoolId poolId) internal {
        isArtCoin[token] = true;
        DeploymentInfoV2 storage info = _deploymentInfo[token];
        info.token = token;
        info.hook = c.pool.hook;
        info.locker = c.locker.locker;
        info.mevModule = c.mev.module;
        info.poolId = poolId;
        info.version = STACK_VERSION;
        info.launchedAt = uint40(block.timestamp);
        for (uint256 i; i < c.extensions.length; ++i) {
            info.extensions.push(c.extensions[i].extension);
        }
    }

    function _placeLiquidity(
        DeploymentConfigV2 calldata c,
        PoolKey memory poolKey,
        uint256 poolSupply,
        address token,
        uint16 protocolBps
    ) internal {
        LockerConfigV2 memory l = c.locker;
        if (protocolBps != 0) {
            uint256 n = l.rewardRecipients.length;
            address[] memory recipients = new address[](n + 1);
            uint16[] memory bps = new uint16[](n + 1);
            for (uint256 i; i < n; ++i) {
                recipients[i] = l.rewardRecipients[i];
                bps[i] = l.rewardBps[i];
            }
            recipients[n] = protocolRecipient;
            bps[n] = protocolBps;
            l.rewardRecipients = recipients;
            l.rewardBps = bps;
        }

        IERC20 coin = IERC20(token);
        uint256 before = coin.balanceOf(address(this));
        coin.forceApprove(l.locker, poolSupply);
        IArtCoinsLpLockerV2(l.locker).placeLiquidity(l, c.pool, poolKey, poolSupply, token);
        if (coin.allowance(address(this), l.locker) != 0) coin.forceApprove(l.locker, 0);
        if (before - coin.balanceOf(address(this)) != poolSupply) revert SupplyNotPulled(l.locker);
    }

    /// @dev Each extension gets exactly its own `msgValue` (never another's) and an
    ///      allowance of exactly its own supply share, which it must pull in full.
    ///      Reentry into the launch entrypoints is blocked by `nonReentrant`.
    function _runExtensions(
        DeploymentConfigV2 calldata c,
        PoolKey memory poolKey,
        address token,
        uint256 supply
    ) internal {
        IERC20 coin = IERC20(token);
        for (uint256 i; i < c.extensions.length; ++i) {
            ExtensionConfigV2 calldata e = c.extensions[i];
            uint256 share = e.extensionBps * supply / Constants.BPS;
            uint256 before = coin.balanceOf(address(this));
            if (share != 0) coin.forceApprove(e.extension, share);
            IArtCoinsExtensionV2(e.extension).receiveTokens{value: e.msgValue}(
                c, poolKey, token, share, i
            );
            if (coin.allowance(address(this), e.extension) != 0) {
                coin.forceApprove(e.extension, 0);
            }
            if (before - coin.balanceOf(address(this)) != share) {
                revert SupplyNotPulled(e.extension);
            }
            emit ExtensionTriggered(token, e.extension, share, e.msgValue);
        }
    }

    /// @dev Deploy fee pushed to `teamFeeRecipient`, excess refunded to the sender.
    function _settleEth(uint256 fee, uint256 excess) internal {
        if (fee != 0) {
            address recipient = teamFeeRecipient;
            if (recipient == address(0)) revert TeamFeeRecipientNotSet();
            _sendEth(recipient, fee);
            emit DeployFeePaid(recipient, fee);
        }
        if (excess != 0) _sendEth(msg.sender, excess);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    // ══════════════════════════════════════════════════════════════════════
    // reads
    // ══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IArtCoinsFactoryV2
    /// @dev Reverts `NotFound` for a token this factory did not launch.
    function deploymentInfo(address token) external view returns (DeploymentInfoV2 memory) {
        if (!isArtCoin[token]) revert NotFound();
        return _deploymentInfo[token];
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    // ══════════════════════════════════════════════════════════════════════
    // owner
    // ══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IArtCoinsFactoryV2
    /// @dev Enabling checks `constantsHash()` and that the hook's PoolManager is ours.
    ///      Disabling never calls the target (FT-04).
    function setHook(address hook, bool enabled) external onlyOwner {
        if (hook == address(0)) revert ZeroAddress();
        if (enabled) {
            _checkConstants(hook);
            if (IHookPoolManager(hook).poolManager() != poolManager) {
                revert PoolManagerMismatch(hook);
            }
        }
        enabledHooks[hook] = enabled;
        emit HookSet(hook, enabled);
    }

    /// @inheritdoc IArtCoinsFactoryV2
    function setLocker(address locker, bool enabled) external onlyOwner {
        if (locker == address(0)) revert ZeroAddress();
        if (enabled) _checkConstants(locker);
        enabledLockers[locker] = enabled;
        emit LockerSet(locker, enabled);
    }

    /// @inheritdoc IArtCoinsFactoryV2
    /// @dev Enabling requires `supportsInterface(type(IArtCoinsMevSkimV2).interfaceId)`
    ///      (refuses v1 lp fee modules, D22) and a matching `constantsHash()`.
    function setMevModule(address module, bool enabled) external onlyOwner {
        if (module == address(0)) revert ZeroAddress();
        if (enabled) {
            if (!_supports(module, type(IArtCoinsMevSkimV2).interfaceId)) {
                revert InvalidMevModule(module);
            }
            _checkConstants(module);
        }
        enabledMevModules[module] = enabled;
        emit MevModuleSet(module, enabled);
    }

    /// @inheritdoc IArtCoinsFactoryV2
    function setExtension(address extension, bool enabled) external onlyOwner {
        if (extension == address(0)) revert ZeroAddress();
        if (enabled) {
            if (!_supports(extension, type(IArtCoinsExtensionV2).interfaceId)) {
                revert ExtensionNotEnabled();
            }
            _checkConstants(extension);
        }
        enabledExtensions[extension] = enabled;
        emit ExtensionSet(extension, enabled);
    }

    /// @inheritdoc IArtCoinsFactoryV2
    function setEscrow(address escrow, bool enabled) external onlyOwner {
        if (escrow == address(0)) revert ZeroAddress();
        if (enabled) _checkConstants(escrow);
        enabledEscrows[escrow] = enabled;
        emit EscrowSet(escrow, enabled);
    }

    /// @inheritdoc IArtCoinsFactoryV2
    function setDeprecated(bool deprecated_) external onlyOwner {
        deprecated = deprecated_;
        emit DeprecatedSet(deprecated_);
    }

    /// @inheritdoc IArtCoinsFactoryV2
    function setDeployFee(uint256 fee) external onlyOwner {
        if (fee > Constants.MAX_DEPLOY_FEE) revert DeployFeeTooHigh();
        emit DeployFeeSet(deployFee, fee);
        deployFee = fee;
    }

    /// @inheritdoc IArtCoinsFactoryV2
    function setDefaultProtocolFeeBps(uint16 bps) external onlyOwner {
        if (bps > Constants.MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeBpsTooHigh();
        emit DefaultProtocolFeeBpsSet(defaultProtocolFeeBps, bps);
        defaultProtocolFeeBps = bps;
    }

    /// @inheritdoc IArtCoinsFactoryV2
    /// @dev <= BPS. Launch bountyBps is capped at min(MAX_BOUNTY_BPS, BPS - this).
    function setMinProtocolSkimShareBps(uint16 bps) external onlyOwner {
        if (bps > Constants.BPS) revert MinProtocolSkimShareTooHigh();
        emit MinProtocolSkimShareBpsSet(minProtocolSkimShareBps, bps);
        minProtocolSkimShareBps = bps;
    }

    /// @inheritdoc IArtCoinsFactoryV2
    /// @dev Injected into new pools only: the skim protocol leg and the locker protocol slot.
    function setProtocolRecipient(address payable recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        emit ProtocolRecipientSet(protocolRecipient, recipient);
        protocolRecipient = recipient;
    }

    /// @inheritdoc IArtCoinsFactoryV2
    /// @dev Injected into new pools only.
    function setReferralPayout(address payable payout) external onlyOwner {
        if (payout == address(0)) revert ZeroAddress();
        emit ReferralPayoutSet(referralPayout, payout);
        referralPayout = payout;
    }

    /// @inheritdoc IArtCoinsFactoryV2
    /// @dev Receives the deploy fee. 0 is allowed only while `deployFee == 0`
    ///      (a launch with a fee and no recipient reverts `TeamFeeRecipientNotSet`).
    function setTeamFeeRecipient(address recipient) external onlyOwner {
        emit TeamFeeRecipientSet(teamFeeRecipient, recipient);
        teamFeeRecipient = recipient;
    }

    /// @inheritdoc IArtCoinsFactoryV2
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) _sendEth(to, amount);
        else IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @notice Disabled: an ownerless factory would freeze allowlists and rescue (FT-13).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev A target with no code, a reverting answer or a short answer is a mismatch.
    function _checkConstants(address target) internal view {
        (bool ok, bytes memory ret) =
            target.staticcall(abi.encodeCall(IConstantsBound.constantsHash, ()));
        if (!ok || ret.length != 32 || abi.decode(ret, (bytes32)) != Constants.hash()) {
            revert ConstantsMismatch(target);
        }
    }

    /// @dev Never reverts: a reverting or non erc165 target answers false.
    function _supports(address target, bytes4 id) internal view returns (bool) {
        try IERC165(target).supportsInterface(id) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}
