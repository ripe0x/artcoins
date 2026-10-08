// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactoryV2} from "./IArtCoinsFactoryV2.sol";
import {IConstantsBound} from "./IConstantsBound.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IArtCoinsLpLockerV2
/// @notice Holds a coin's launch liquidity forever and splits collected lp
///         fees. The split bps are set once at launch; the coin admin may
///         change a project reward recipient, the protocol slot stays frozen.
///         Rewards are pushed; a failed push is credited in the fee escrow.
///         There is no liquidity decrease path.
interface IArtCoinsLpLockerV2 is IConstantsBound {
    /// @notice Per coin record. The bps are set at launch; a project reward
    ///         recipient may be changed by the coin admin. Position ids are
    ///         `positionId .. positionId + numPositions - 1`.
    struct TokenRewardInfoV2 {
        address token;
        PoolKey poolKey;
        uint256 positionId;
        uint256 numPositions;
        uint16[] rewardBps;
        address[] rewardRecipients;
    }

    // ── events ────────────────────────────────────────────────────────────

    event TokenRewardAdded(
        address indexed token,
        PoolKey poolKey,
        uint256 poolSupply,
        uint256 positionId,
        uint256 numPositions,
        uint16[] rewardBps,
        address[] rewardRecipients,
        int24[] tickLower,
        int24[] tickUpper,
        uint16[] positionBps
    );
    event RewardsCollected(address indexed token, uint256 amount0, uint256 amount1);
    /// @notice One recipient share delivered; `escrowed` when the push failed.
    event RewardDelivered(
        address indexed token,
        address indexed currency,
        address indexed to,
        uint256 amount,
        bool escrowed
    );
    event KeeperRewarded(
        address indexed keeper, address indexed token, address indexed currency, uint256 amount
    );
    event KeeperRewardBpsSet(uint256 oldBps, uint256 newBps);
    event KeeperRewardCapSet(uint256 oldCap, uint256 newCap);
    /// @notice The coin admin changed a reward recipient slot.
    event RewardRecipientSet(
        address indexed token, uint256 indexed index, address oldRecipient, address newRecipient
    );
    event FeeEscrowSet(address indexed oldEscrow, address indexed newEscrow);
    event LauncherSet(address indexed launcher, bool enabled);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ── errors ────────────────────────────────────────────────────────────

    error NotLauncher();
    error ZeroAddress();
    error TokenAlreadyHasRewards();
    error TokenNotFound();
    error MismatchedRewardArrays();
    error TooManyRewardParticipants();
    error NoRewardRecipients();
    error ZeroRewardAmount();
    error InvalidRewardBps();
    error MismatchedPositionArrays();
    error TooManyPositions();
    error InvalidPositionBps();
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    error KeeperRewardBpsOutOfBounds(uint256 supplied, uint256 max);
    error KeeperRewardCapOutOfBounds(uint256 supplied, uint256 min, uint256 max);
    error EthTransferFailed();

    // ── launcher ──────────────────────────────────────────────────────────

    /// @notice Mints the launch positions and freezes the reward split.
    ///         Allowlisted launchers only; checks the pool hook's `constantsHash()`.
    /// @param  lockerConfig Split and positions, protocol slot already appended.
    /// @param  protocolSlotIndex Reward slot the launcher appended for the
    ///         protocol, frozen against `setRewardRecipient`; `type(uint256).max`
    ///         means no protocol slot.
    /// @return positionId First position id.
    function placeLiquidity(
        IArtCoinsFactoryV2.LockerConfigV2 calldata lockerConfig,
        IArtCoinsFactoryV2.PoolConfigV2 calldata poolConfig,
        PoolKey calldata poolKey,
        uint256 poolSupply,
        address token,
        uint256 protocolSlotIndex
    ) external returns (uint256 positionId);

    // ── permissionless ────────────────────────────────────────────────────

    /// @notice Collects lp fees for `token` and delivers every share.
    function collectRewards(address token) external;

    // ── coin admin ─────────────────────────────────────────────────────────

    /// @notice Sets reward recipient `index` for `token`. Coin admin only, until
    ///         the coin locks its recipients or renounces its admin. bps stay
    ///         fixed. The protocol slot stays frozen. Pending lp fees are
    ///         collected to the current recipients first. `newRecipient` must be
    ///         nonzero and not the coin, this locker, its fee escrow, the pool's
    ///         hook, the PoolManager, the PositionManager, the pool's mev module,
    ///         the factory or its token deployer.
    function setRewardRecipient(address token, uint256 index, address newRecipient) external;

    /// @notice The reward slot reserved for the protocol at launch. `exists` is
    ///         false when the launch appended no protocol slot. `setRewardRecipient`
    ///         refuses `index` when `exists`.
    function protocolSlotIndex(address token) external view returns (bool exists, uint256 index);

    // ── reads ─────────────────────────────────────────────────────────────

    function tokenRewards(address token) external view returns (TokenRewardInfoV2 memory);
    function rewardRecipients(address token) external view returns (address[] memory);
    function rewardBps(address token) external view returns (uint16[] memory);
    function keeperRewardBps() external view returns (uint256);
    function keeperRewardCap() external view returns (uint256);
    function feeEscrow() external view returns (address);
    function isLauncher(address launcher) external view returns (bool);

    // ── owner ─────────────────────────────────────────────────────────────

    /// @dev <= Constants.LOCKER_KEEPER_BPS_MAX.
    function setKeeperRewardBps(uint256 newBps) external;
    /// @dev Within [Constants.LOCKER_KEEPER_CAP_MIN, Constants.LOCKER_KEEPER_CAP_MAX].
    function setKeeperRewardCap(uint256 newCap) external;
    function setFeeEscrow(address escrow) external;
    function setLauncher(address launcher, bool enabled) external;
    /// @notice Sends stray eth (`token == address(0)`) or erc20. The locker holds nothing between calls.
    function rescue(address token, address to, uint256 amount) external;
}
