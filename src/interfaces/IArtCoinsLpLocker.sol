// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactory} from "../interfaces/IArtCoinsFactory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IArtCoinsLpLocker
/// @notice Interface for LP locker contracts that hold the pool's initial liquidity and
///         distribute fee rewards to configured recipients.
interface IArtCoinsLpLocker {
    /// @notice Stored reward distribution info for a token's locked LP.
    /// @param token The ArtCoins token.
    /// @param poolKey The Uniswap v4 pool key.
    /// @param positionId The NFT position id held by the locker.
    /// @param numPositions The number of LP positions created for this token.
    /// @param rewardBps Basis-point split among recipients (sums to `BPS`).
    /// @param rewardAdmins Addresses allowed to manage each reward share.
    /// @param rewardRecipients Recipient addresses paired with `rewardBps`.
    struct TokenRewardInfo {
        address token;
        PoolKey poolKey;
        uint256 positionId;
        uint256 numPositions;
        uint16[] rewardBps;
        address[] rewardAdmins;
        address[] rewardRecipients;
    }

    /// @notice Emitted when LP positions are added for a token.
    event TokenRewardAdded(
        address token,
        PoolKey poolKey,
        uint256 poolSupply,
        uint256 positionId,
        uint256 numPositions,
        uint16[] rewardBps,
        address[] rewardAdmins,
        address[] rewardRecipients,
        int24[] tickLower,
        int24[] tickUpper,
        uint16[] positionBps
    );

    /// @notice Emitted when rewards are collected and distributed.
    /// @param token The ArtCoins token.
    /// @param amount0 Total amount of pool token0 collected.
    /// @param amount1 Total amount of pool token1 collected.
    /// @param rewards0 Per-recipient amounts of token0.
    /// @param rewards1 Per-recipient amounts of token1.
    event ClaimedRewards(
        address indexed token,
        uint256 amount0,
        uint256 amount1,
        uint256[] rewards0,
        uint256[] rewards1
    );

    /// @notice Collects fees from the Uniswap v4 pool and distributes them to reward recipients.
    /// @param token The ArtCoins token whose pool to collect from.
    function collectRewards(address token) external;

    /// @notice Same as `collectRewards` but assumes the pool manager is already unlocked.
    /// @param token The ArtCoins token whose pool to collect from.
    function collectRewardsWithoutUnlock(address token) external;

    /// @notice Called by the factory to lock the initial LP and configure reward distribution.
    /// @param lockerConfig Locker-specific parameters (reward split, tick ranges, positions).
    /// @param poolConfig Pool parameters passed through from the factory.
    /// @param poolKey The Uniswap v4 pool key.
    /// @param poolSupply Amount of ArtCoins token to deploy as liquidity.
    /// @param token The ArtCoins token address.
    /// @return tokenId The locked position identifier.
    function placeLiquidity(
        IArtCoinsFactory.LockerConfig memory lockerConfig,
        IArtCoinsFactory.PoolConfig memory poolConfig,
        PoolKey memory poolKey,
        uint256 poolSupply,
        address token
    ) external returns (uint256 tokenId);

    /// @notice Returns stored reward distribution info for a given token.
    /// @param token The ArtCoins token.
    /// @return The reward info struct.
    function tokenRewards(address token) external view returns (TokenRewardInfo memory);

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
