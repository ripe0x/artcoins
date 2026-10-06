// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IConstantsBound} from "./IConstantsBound.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title  IArtCoinsFactoryV2
/// @notice Launches an art coin, its native eth Uniswap v4 pool on the v2
///         hook, and its locked liquidity in one call. Every per coin value is
///         frozen at launch. The token address is a function of
///         (factory, sender, full config).
interface IArtCoinsFactoryV2 is IConstantsBound {
    // ── launch config ─────────────────────────────────────────────────────

    struct TokenConfigV2 {
        address tokenAdmin;
        string name;
        string symbol;
        bytes32 salt; // vanity input, folded into configHash
        string image;
        string metadata;
        string context;
        uint256 totalSupply; // 0 = Constants.DEFAULT_TOKEN_SUPPLY
        address renderer;
    }

    /// @dev Paired currency is always native eth.
    struct PoolConfigV2 {
        address hook;
        int24 tickIfToken0IsArtCoin;
        int24 tickSpacing;
        address extension; // pool extension, frozen per pool, 0 for none
        bytes extensionData;
    }

    /// @dev protocolRecipient and referralPayout are injected by the factory.
    struct FeeConfigV2 {
        uint24 lpFee;
        uint24 baselineSkimBps;
        uint16 bountyBps; // <= BPS minus minProtocolSkimShareBps
        uint24 maxReferralBpsOfVolume;
        address payable bountyRecipient;
    }

    /// @dev Project slots only; the factory appends the protocol slot.
    struct LockerConfigV2 {
        address locker;
        address[] rewardRecipients;
        uint16[] rewardBps;
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionBps;
    }

    struct MevConfigV2 {
        address module; // IArtCoinsMevSkimV2 with matching constantsHash
        uint24 startingSkimBps;
        uint32 windowSeconds; // <= Constants.MAX_MEV_WINDOW
    }

    /// @notice A v2 or v3 style pool whose address the token derives from its
    ///         own address at construction.
    struct TaxVenue {
        uint8 kind; // 1 = v2 style CREATE2 pair, 2 = v3 style CREATE2 pool
        address factory; // pair or pool factory
        bytes32 initCodeHash; // factory init code hash
        address counterToken; // the other token of the pair
        uint24 v3Fee; // v3 fee tier, kind 2 only
    }

    struct TaxConfigV2 {
        uint8 mode; // Constants.TAX_MODE_NONE, _VENUE or _HARD
        uint16 taxBps;
        uint16 taxBpsMax; // <= Constants.TAX_BPS_ABSOLUTE_MAX
        address taxSink; // Constants.DEAD or the bounty recipient
        address venueAdmin; // 0 = token admin
        address[] exempt; // <= Constants.MAX_TAX_EXEMPT
        TaxVenue[] venues; // <= Constants.MAX_TAX_VENUES
    }

    /// @notice Launch extension: receives a share of supply and optional eth.
    struct ExtensionConfigV2 {
        address extension;
        uint256 msgValue;
        uint16 extensionBps;
        bytes extensionData;
    }

    struct DeploymentConfigV2 {
        TokenConfigV2 token;
        PoolConfigV2 pool;
        FeeConfigV2 fee;
        LockerConfigV2 locker;
        MevConfigV2 mev;
        TaxConfigV2 tax;
        ExtensionConfigV2[] extensions;
    }

    struct DeploymentInfoV2 {
        address token;
        address hook;
        address locker;
        address mevModule;
        PoolId poolId;
        uint16 version;
        uint40 launchedAt;
        address[] extensions;
    }

    // ── events ────────────────────────────────────────────────────────────

    /// @notice Full launch record. An indexer can rebuild every frozen field from this log.
    event TokenCreatedV2(
        address indexed sender,
        address indexed token,
        PoolId indexed poolId,
        uint16 stackVersion,
        bytes32 configHash,
        address protocolRecipient,
        address referralPayout,
        uint16 protocolBps,
        uint256 poolSupply,
        uint256 extensionsSupply,
        DeploymentConfigV2 config
    );
    event ExtensionTriggered(
        address indexed token, address indexed extension, uint256 extensionSupply, uint256 msgValue
    );
    event DeployFeePaid(address indexed recipient, uint256 amount);

    event HookSet(address indexed hook, bool enabled);
    event LockerSet(address indexed locker, bool enabled);
    event MevModuleSet(address indexed module, bool enabled);
    event ExtensionSet(address indexed extension, bool enabled);
    event EscrowSet(address indexed escrow, bool enabled);
    event DeprecatedSet(bool deprecated);
    event DeployFeeSet(uint256 oldFee, uint256 newFee);
    event DefaultProtocolFeeBpsSet(uint16 oldBps, uint16 newBps);
    event MinProtocolSkimShareBpsSet(uint16 oldBps, uint16 newBps);
    event ProtocolRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    event ReferralPayoutSet(address indexed oldPayout, address indexed newPayout);
    event TeamFeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ── errors ────────────────────────────────────────────────────────────

    error Deprecated();
    error NotFound();
    error ZeroAddress();
    error HookNotEnabled();
    error LockerNotEnabled();
    error MevModuleNotEnabled();
    error ExtensionNotEnabled();
    error InvalidMevModule(address module);
    error InvalidMevConfig();
    error MsgValueMismatch(uint256 expected, uint256 sent);
    error DeployFeeTooHigh();
    error ProtocolFeeBpsTooHigh();
    error MinProtocolSkimShareTooHigh();
    error BountyBpsTooHigh(uint16 bountyBps, uint16 max);
    error ProjectSideBpsMismatch();
    error TotalSupplyTooLow();
    error MaxExtensionsExceeded();
    error MaxExtensionBpsExceeded();
    error InvalidTaxConfig();
    error TaxSinkNotAllowed(address sink);
    error TeamFeeRecipientNotSet();
    error EthTransferFailed();

    // ── launch ────────────────────────────────────────────────────────────

    /// @notice Public launch. `msg.value` = deployFee + sum of extension msgValue.
    function deployToken(DeploymentConfigV2 calldata c) external payable returns (address token);

    /// @notice Owner only launch; the only path that overrides the protocol slot bps.
    function deployTokenAsOwner(DeploymentConfigV2 calldata c, uint16 protocolBps)
        external
        payable
        returns (address token);

    /// @notice Address `deployToken(c)` yields when called by `sender`.
    function predictToken(address sender, DeploymentConfigV2 calldata c)
        external
        view
        returns (address);

    /// @notice keccak256(abi.encode(c)). Folded into the deploy salt with the sender.
    function configHash(DeploymentConfigV2 calldata c) external pure returns (bytes32);

    // ── reads ─────────────────────────────────────────────────────────────

    function STACK_VERSION() external view returns (uint16);
    function isArtCoin(address token) external view returns (bool);
    function deploymentInfo(address token) external view returns (DeploymentInfoV2 memory);
    function deprecated() external view returns (bool);
    function deployFee() external view returns (uint256);
    function defaultProtocolFeeBps() external view returns (uint16);
    function minProtocolSkimShareBps() external view returns (uint16);
    function protocolRecipient() external view returns (address payable);
    function referralPayout() external view returns (address payable);
    function teamFeeRecipient() external view returns (address);
    function enabledHooks(address hook) external view returns (bool);
    function enabledLockers(address locker) external view returns (bool);
    function enabledMevModules(address module) external view returns (bool);
    function enabledExtensions(address extension) external view returns (bool);
    function enabledEscrows(address escrow) external view returns (bool);

    // ── owner ─────────────────────────────────────────────────────────────

    /// @dev Enabling checks `constantsHash()` of the target.
    function setHook(address hook, bool enabled) external;
    function setLocker(address locker, bool enabled) external;
    function setMevModule(address module, bool enabled) external;
    function setExtension(address extension, bool enabled) external;
    function setEscrow(address escrow, bool enabled) external;
    function setDeprecated(bool deprecated_) external;
    /// @dev <= Constants.MAX_DEPLOY_FEE.
    function setDeployFee(uint256 fee) external;
    /// @dev <= Constants.MAX_PROTOCOL_FEE_BPS.
    function setDefaultProtocolFeeBps(uint16 bps) external;
    /// @dev Minimum protocol share of the skim; caps launch bountyBps.
    function setMinProtocolSkimShareBps(uint16 bps) external;
    function setProtocolRecipient(address payable recipient) external;
    function setReferralPayout(address payable payout) external;
    function setTeamFeeRecipient(address recipient) external;
    /// @notice Sends stray eth (`token == address(0)`) or erc20 held by the factory.
    function rescue(address token, address to, uint256 amount) external;
}
