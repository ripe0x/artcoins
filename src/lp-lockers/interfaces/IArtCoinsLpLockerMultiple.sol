// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsLpLocker} from "../../interfaces/IArtCoinsLpLocker.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IArtCoinsLpLockerMultiple
/// @notice Interface for the multi-position, multi-recipient LP locker.
interface IArtCoinsLpLockerMultiple is IArtCoinsLpLocker {
    /// @notice Reverts when the caller is not authorized.
    error Unauthorized();
    /// @notice Reverts when reward arrays have mismatched lengths.
    error MismatchedRewardArrays();
    /// @notice Reverts when the reward bps don't sum to `BASIS_POINTS`.
    error InvalidRewardBps();
    /// @notice Reverts when a reward admin or recipient is the zero address.
    error ZeroRewardAddress();
    /// @notice Reverts when any reward bps entry is zero.
    error ZeroRewardAmount();
    /// @notice Reverts when more than `MAX_REWARD_PARTICIPANTS` recipients are configured.
    error TooManyRewardParticipants();
    /// @notice Reverts when no reward recipients are configured.
    error NoRewardRecipients();
    /// @notice Reverts when liquidity has already been placed for the token.
    error TokenAlreadyHasRewards();
    /// @notice Reverts when a position's `tickLower > tickUpper`.
    error TicksBackwards();
    /// @notice Reverts when a tick is outside `MIN_TICK..MAX_TICK`.
    error TicksOutOfTickBounds();
    /// @notice Reverts when a tick isn't a multiple of `tickSpacing`.
    error TicksNotMultipleOfTickSpacing();
    /// @notice Reverts when a position's lower tick is below the pool's starting tick.
    error TickRangeLowerThanStartingTick();
    /// @notice Reverts when the position bps don't sum to `BASIS_POINTS`.
    error InvalidPositionBps();
    /// @notice Reverts when position arrays have mismatched lengths.
    error MismatchedPositionInfos();
    /// @notice Reverts when no positions are configured.
    error NoPositions();
    /// @notice Reverts when more than `MAX_LP_POSITIONS` positions are configured.
    error TooManyPositions();

    /// @notice Emitted when the locker receives an LP NFT.
    /// @param from Sender (must be the factory).
    /// @param positionId The received NFT id.
    event Received(address indexed from, uint256 positionId);
    /// @notice Emitted when a reward recipient is replaced.
    /// @param token The ArtCoins token.
    /// @param rewardIndex Reward slot index.
    /// @param oldRecipient Previous recipient.
    /// @param newRecipient New recipient.
    event RewardRecipientUpdated(
        address indexed token,
        uint256 indexed rewardIndex,
        address oldRecipient,
        address newRecipient
    );
    /// @notice Emitted when a reward admin is replaced.
    /// @param token The ArtCoins token.
    /// @param rewardIndex Reward slot index.
    /// @param oldAdmin Previous admin.
    /// @param newAdmin New admin.
    event RewardAdminUpdated(
        address indexed token, uint256 indexed rewardIndex, address oldAdmin, address newAdmin
    );

    /// @notice Replaces a reward slot's admin. Only the slot's current admin may call.
    /// @param token The ArtCoins token.
    /// @param rewardIndex Reward slot index.
    /// @param newAdmin New admin address.
    function updateRewardAdmin(address token, uint256 rewardIndex, address newAdmin) external;

    /// @notice Replaces a reward slot's recipient. Only the slot's current admin may call.
    /// @param token The ArtCoins token.
    /// @param rewardIndex Reward slot index.
    /// @param newRecipient New recipient address.
    function updateRewardRecipient(address token, uint256 rewardIndex, address newRecipient)
        external;
}
