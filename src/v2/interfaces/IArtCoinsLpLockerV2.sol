// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactoryV2} from "./IArtCoinsFactoryV2.sol";
import {IConstantsBound} from "./IConstantsBound.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IArtCoinsLpLockerV2
/// @notice Holds a coin's launch liquidity and splits collected lp fees.
///         Liquidity has no decrease path. The reward bps are set once at
///         launch. The coin admin may change a reward recipient until the coin
///         locks its recipients or renounces its admin. The protocol slot is
///         fixed at launch and is the last reward element when present
///         (`protocolSlotIndex`). Rewards are pushed; a failed push is credited
///         in the fee escrow.
///
///         Units: bps = 1/10,000; amounts in wei or token units.
interface IArtCoinsLpLockerV2 is IConstantsBound {
    /// @notice Per coin record. Position ids are
    ///         `positionId .. positionId + numPositions - 1`.
    struct TokenRewardInfoV2 {
        /// @dev The coin.
        address token;
        /// @dev Key of the coin's pool.
        PoolKey poolKey;
        /// @dev First position id.
        uint256 positionId;
        /// @dev Number of launch positions.
        uint256 numPositions;
        /// @dev Reward share per slot, bps. Fixed at launch; sums to 10,000.
        uint16[] rewardBps;
        /// @dev Reward recipient per slot, parallel to `rewardBps`. The coin admin
        ///      may change a slot except the protocol slot.
        address[] rewardRecipients;
    }

    // ── events ────────────────────────────────────────────────────────────

    /// @notice A coin's liquidity was placed and its reward split recorded.
    /// @param token The coin.
    /// @param poolKey Key of the coin's pool.
    /// @param poolSupply Coin amount placed, token units.
    /// @param positionId First position id.
    /// @param numPositions Number of positions.
    /// @param rewardBps Reward share per slot, bps.
    /// @param rewardRecipients Reward recipient per slot.
    /// @param tickLower Lower tick per position, as if the coin were token0.
    /// @param tickUpper Upper tick per position, as if the coin were token0.
    /// @param positionBps Share of `poolSupply` per position, bps.
    /// @param hasProtocolSlot True when the last reward element is the protocol
    ///        slot, which `setRewardRecipient` refuses.
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
        uint16[] positionBps,
        bool hasProtocolSlot
    );

    /// @notice Fees were collected from a coin's positions.
    /// @param token The coin.
    /// @param amount0 Eth collected, wei.
    /// @param amount1 Coin collected, token units.
    event RewardsCollected(address indexed token, uint256 amount0, uint256 amount1);

    /// @notice One recipient share was delivered. `escrowed` is true when the
    ///         push failed and the amount was credited to `to` in the fee escrow.
    /// @param token The coin.
    /// @param currency Share currency: the coin, or 0 for eth.
    /// @param to Recipient.
    /// @param amount Share amount, token units or wei.
    /// @param escrowed Whether the amount was credited in the fee escrow.
    event RewardDelivered(
        address indexed token,
        address indexed currency,
        address indexed to,
        uint256 amount,
        bool escrowed
    );

    /// @notice A keeper was paid from the eth side of a collect.
    /// @param keeper Caller of `collectRewards`.
    /// @param token The coin.
    /// @param currency Reward currency, always 0 (eth).
    /// @param amount Reward, wei.
    event KeeperRewarded(
        address indexed keeper, address indexed token, address indexed currency, uint256 amount
    );

    /// @notice The keeper reward rate changed.
    /// @param oldBps Previous rate, bps of the collected eth.
    /// @param newBps New rate, bps of the collected eth.
    event KeeperRewardBpsSet(uint256 oldBps, uint256 newBps);

    /// @notice The keeper reward cap changed.
    /// @param oldCap Previous cap, wei.
    /// @param newCap New cap, wei.
    event KeeperRewardCapSet(uint256 oldCap, uint256 newCap);

    /// @notice The coin admin changed a reward recipient slot.
    /// @param token The coin.
    /// @param index Reward slot index.
    /// @param oldRecipient Previous recipient.
    /// @param newRecipient New recipient.
    event RewardRecipientSet(
        address indexed token, uint256 indexed index, address oldRecipient, address newRecipient
    );

    /// @notice The fee escrow changed.
    /// @param oldEscrow Previous escrow.
    /// @param newEscrow New escrow.
    event FeeEscrowSet(address indexed oldEscrow, address indexed newEscrow);

    /// @notice A launcher was enabled or disabled.
    /// @param launcher Launcher address.
    /// @param enabled New state.
    event LauncherSet(address indexed launcher, bool enabled);

    /// @notice Stray eth or erc20 was sent out by the owner.
    /// @param token Token, or 0 for eth.
    /// @param to Recipient.
    /// @param amount Amount, token units or wei.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ── errors ────────────────────────────────────────────────────────────

    /// @notice The caller is not an allowlisted launcher.
    error NotLauncher();

    /// @notice A required address is zero, or a reward recipient is zero or the locker.
    error ZeroAddress();

    /// @notice The coin already has a reward record.
    error TokenAlreadyHasRewards();

    /// @notice The coin has no reward record.
    error TokenNotFound();

    /// @notice `rewardBps` and `rewardRecipients` differ in length.
    error MismatchedRewardArrays();

    /// @notice The reward arrays exceed Constants.MAX_REWARD_PARTICIPANTS.
    error TooManyRewardParticipants();

    /// @notice The reward arrays are empty.
    error NoRewardRecipients();

    /// @notice A reward slot has zero bps.
    error ZeroRewardAmount();

    /// @notice The reward bps do not sum to 10,000.
    error InvalidRewardBps();

    /// @notice `tickLower`, `tickUpper` and `positionBps` differ in length.
    error MismatchedPositionArrays();

    /// @notice The position arrays exceed Constants.MAX_LP_POSITIONS.
    error TooManyPositions();

    /// @notice A position has zero bps, or the position bps do not sum to 10,000.
    error InvalidPositionBps();

    /// @notice A position tick range is empty, outside the tick bounds, off the
    ///         tick spacing, or below the starting tick.
    /// @param tickLower The lower tick.
    /// @param tickUpper The upper tick.
    error InvalidTickRange(int24 tickLower, int24 tickUpper);

    /// @notice A bounded owner setter received a value outside [min, max].
    /// @param value The rejected value.
    /// @param min Lower bound.
    /// @param max Upper bound.
    error OutOfBounds(uint256 value, uint256 min, uint256 max);

    /// @notice An eth transfer in `rescue` failed.
    error NativeTransferFailed();

    /// @notice A collect was attempted while the PoolManager is unlocked by another caller.
    error PoolManagerUnlocked();
    /// @notice Pool key is not a native eth pair of `token` with the configured
    ///         hook and tick spacing.
    error UnsupportedPoolKey();
    /// @notice `rescue` was called with the PositionManager as `token`; lp nfts have no exit.
    error RescueForbidden();
    /// @notice Eth arrived from an address other than the PoolManager.
    error UnexpectedEth();
    /// @notice The caller is not the coin's current admin.
    error NotCoinAdmin();
    /// @notice The coin's recipients are frozen (the coin called `lockRecipients`
    ///         or renounced its admin).
    error RecipientsLocked();
    /// @notice The `setRewardRecipient` index is not a reward slot.
    error RewardIndexOutOfRange();
    /// @notice The `setRewardRecipient` index is the protocol slot, which is fixed at launch.
    error ProtocolSlotFrozen();
    /// @notice `setRewardRecipient` rejected a recipient that cannot hold a reward:
    ///         the coin, this locker, its fee escrow, the pool hook's fee escrow,
    ///         the pool's hook, the PoolManager, the PositionManager, the pool's
    ///         mev module, the factory or its token deployer.
    /// @param recipient The rejected recipient.
    error RecipientCannotReceive(address recipient);
    /// @notice A reject-set lookup (token deployer, pool mev module or pool hook
    ///         fee escrow) reverted, so the recipient could not be verified. The
    ///         setter refuses the change.
    error RecipientCheckFailed();

    // ── launcher ──────────────────────────────────────────────────────────

    /// @notice Mints the launch positions and records the reward split.
    /// @dev    Callable by allowlisted launchers only. Pulls `poolSupply` of
    ///         `token` from the caller, so the caller must have approved it.
    ///         The pool hook must report this build's `constantsHash()`. Reverts
    ///         with `NotLauncher`, `ZeroAddress`, `TokenAlreadyHasRewards`,
    ///         `ConstantsMismatch`, `MismatchedRewardArrays`,
    ///         `NoRewardRecipients`, `TooManyRewardParticipants`,
    ///         `ZeroRewardAmount`, `InvalidRewardBps`, `MismatchedPositionArrays`,
    ///         `TooManyPositions`, `InvalidPositionBps` or `InvalidTickRange`.
    /// @param  lockerConfig Reward split and positions, protocol slot already
    ///         appended as the last reward element when present.
    /// @param  poolConfig Pool parameters; its hook and tick spacing must match `poolKey`.
    /// @param  poolKey Key of the coin's pool.
    /// @param  poolSupply Coin amount to place, token units.
    /// @param  token The coin.
    /// @param  hasProtocolSlot True when the last reward element is the protocol
    ///         slot, which `setRewardRecipient` refuses.
    /// @return positionId First position id.
    function placeLiquidity(
        IArtCoinsFactoryV2.LockerConfigV2 calldata lockerConfig,
        IArtCoinsFactoryV2.PoolConfigV2 calldata poolConfig,
        PoolKey calldata poolKey,
        uint256 poolSupply,
        address token,
        bool hasProtocolSlot
    ) external returns (uint256 positionId);

    // ── permissionless ────────────────────────────────────────────────────

    /// @notice Collects lp fees for `token` and delivers every reward share.
    /// @dev    Callable by anyone. The caller receives a keeper reward from the
    ///         eth side, at most `keeperRewardBps` of it and at most
    ///         `keeperRewardCap`. Reverts with `TokenNotFound`.
    /// @param token The coin.
    function collectRewards(address token) external;

    // ── coin admin ─────────────────────────────────────────────────────────

    /// @notice Sets reward recipient `index` for `token`. Coin admin only, until
    ///         the coin locks its recipients or renounces its admin.
    /// @dev    The reward bps are unchanged. Pending lp fees are collected to the
    ///         current recipients first. `newRecipient` must be nonzero and not
    ///         the coin, this locker, the locker or pool hook fee escrow, the
    ///         pool's hook, the PoolManager, the PositionManager, the pool's mev
    ///         module, the factory or its token deployer. The token deployer, mev
    ///         module and hook fee escrow lookups fail closed: a lookup that
    ///         reverts refuses the change. Reverts with `TokenNotFound`,
    ///         `NotCoinAdmin`, `RecipientsLocked`, `RewardIndexOutOfRange`,
    ///         `ProtocolSlotFrozen`, `ZeroAddress`, `RecipientCannotReceive` or
    ///         `RecipientCheckFailed`.
    /// @param token The coin.
    /// @param index Reward slot index.
    /// @param newRecipient New recipient for the slot.
    function setRewardRecipient(address token, uint256 index, address newRecipient) external;

    /// @notice The reward slot reserved for the protocol at launch. When present
    ///         it is the last reward element and `setRewardRecipient` refuses it.
    /// @param token The coin.
    /// @return exists False when the launch appended no protocol slot.
    /// @return index Slot index; 0 when `exists` is false.
    function protocolSlotIndex(address token) external view returns (bool exists, uint256 index);

    // ── reads ─────────────────────────────────────────────────────────────

    /// @notice Reward record of a coin. All fields are zero for an unknown coin.
    /// @param token The coin.
    /// @return The reward record.
    function tokenRewards(address token) external view returns (TokenRewardInfoV2 memory);

    /// @notice Current reward recipients of a coin, one per slot.
    /// @param token The coin.
    /// @return The recipients.
    function rewardRecipients(address token) external view returns (address[] memory);

    /// @notice Reward share per slot of a coin, bps.
    /// @param token The coin.
    /// @return The shares.
    function rewardBps(address token) external view returns (uint16[] memory);

    /// @notice Keeper reward rate, bps of the collected eth.
    /// @return The rate in bps.
    function keeperRewardBps() external view returns (uint256);

    /// @notice Keeper reward cap per collect, wei.
    /// @return The cap in wei.
    function keeperRewardCap() external view returns (uint256);

    /// @notice Fee escrow that credits shares whose push failed.
    /// @return The escrow address.
    function feeEscrow() external view returns (address);

    /// @notice Whether `launcher` may call `placeLiquidity`.
    /// @param launcher Address to check.
    /// @return True when enabled.
    function isLauncher(address launcher) external view returns (bool);

    // ── owner ─────────────────────────────────────────────────────────────

    /// @notice Sets the keeper reward rate. Owner only.
    /// @dev    Reverts with `OutOfBounds` above Constants.LOCKER_KEEPER_BPS_MAX.
    /// @param newBps New rate, bps of the collected eth.
    function setKeeperRewardBps(uint256 newBps) external;

    /// @notice Sets the keeper reward cap. Owner only.
    /// @dev    Reverts with `OutOfBounds` outside
    ///         [Constants.LOCKER_KEEPER_CAP_MIN, Constants.LOCKER_KEEPER_CAP_MAX].
    /// @param newCap New cap, wei.
    function setKeeperRewardCap(uint256 newCap) external;

    /// @notice Sets the fee escrow. Owner only.
    /// @dev    The escrow must report this build's `constantsHash()`. Reverts
    ///         with `ZeroAddress` or `ConstantsMismatch`.
    /// @param escrow New fee escrow.
    function setFeeEscrow(address escrow) external;

    /// @notice Enables or disables a launcher. Owner only.
    /// @dev    Reverts with `ZeroAddress` when `launcher` is zero.
    /// @param launcher Launcher address.
    /// @param enabled New state.
    function setLauncher(address launcher, bool enabled) external;

    /// @notice Sends stray eth (`token == address(0)`) or erc20 held by the
    ///         locker. The locker holds nothing between calls. Owner only.
    /// @dev    Reverts with `ZeroAddress` when `to` is zero and with
    ///         `NativeTransferFailed` when an eth send fails.
    /// @param token Token, or 0 for eth.
    /// @param to Recipient.
    /// @param amount Amount, token units or wei.
    function rescue(address token, address to, uint256 amount) external;

    /// @notice Stack version tag (Constants.STACK_VERSION).
    /// @return The stack version.
    function STACK_VERSION() external view returns (uint16);
}
