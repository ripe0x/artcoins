// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactoryV2} from "./IArtCoinsFactoryV2.sol";
import {IConstantsBound} from "./IConstantsBound.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IArtCoinsLpLockerV2
/// @notice Holds a coin's launch liquidity. The positions have no decrease
///         path and the pool charges no lp fee, so nothing accrues to them.
///
///         Units: bps = 1/10,000; amounts in wei or token units.
interface IArtCoinsLpLockerV2 is IConstantsBound {
    /// @notice Per coin record. Position ids are
    ///         `positionId .. positionId + numPositions - 1`.
    struct LockedLiquidity {
        /// @dev The coin.
        address token;
        /// @dev Key of the coin's pool.
        PoolKey poolKey;
        /// @dev First position id.
        uint256 positionId;
        /// @dev Number of launch positions.
        uint256 numPositions;
    }

    // ── events ────────────────────────────────────────────────────────────

    /// @notice A coin's liquidity was placed and locked.
    /// @param token The coin.
    /// @param poolKey Key of the coin's pool.
    /// @param poolSupply Coin amount placed, token units.
    /// @param positionId First position id.
    /// @param numPositions Number of positions.
    /// @param tickLower Lower tick per position, as if the coin were token0.
    /// @param tickUpper Upper tick per position, as if the coin were token0.
    /// @param positionBps Share of `poolSupply` per position, bps.
    event LiquidityLocked(
        address indexed token,
        PoolKey poolKey,
        uint256 poolSupply,
        uint256 positionId,
        uint256 numPositions,
        int24[] tickLower,
        int24[] tickUpper,
        uint16[] positionBps
    );

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
    /// @notice A required address is zero.
    error ZeroAddress();
    /// @notice The coin already has locked liquidity.
    error TokenAlreadyLocked();
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
    /// @notice An eth transfer in `rescue` failed.
    error NativeTransferFailed();
    /// @notice Pool key is not a native eth pair of `token` with the configured
    ///         hook and tick spacing.
    error UnsupportedPoolKey();
    /// @notice `rescue` was called with the PositionManager as `token`; lp nfts have no exit.
    error RescueForbidden();

    // ── launcher ──────────────────────────────────────────────────────────

    /// @notice Mints the launch positions and locks them.
    /// @dev    Callable by allowlisted launchers only. Pulls `poolSupply` of
    ///         `token` from the caller, so the caller must have approved it.
    ///         The pool hook must report this build's `constantsHash()`. Reverts
    ///         with `NotLauncher`, `ZeroAddress`, `TokenAlreadyLocked`,
    ///         `ConstantsMismatch`, `UnsupportedPoolKey`, `MismatchedPositionArrays`,
    ///         `TooManyPositions`, `InvalidPositionBps` or `InvalidTickRange`.
    /// @param  lockerConfig Positions.
    /// @param  poolConfig Pool parameters; its hook and tick spacing must match `poolKey`.
    /// @param  poolKey Key of the coin's pool.
    /// @param  poolSupply Coin amount to place, token units.
    /// @param  token The coin.
    /// @return positionId First position id.
    function placeLiquidity(
        IArtCoinsFactoryV2.LockerConfigV2 calldata lockerConfig,
        IArtCoinsFactoryV2.PoolConfigV2 calldata poolConfig,
        PoolKey calldata poolKey,
        uint256 poolSupply,
        address token
    ) external returns (uint256 positionId);

    // ── reads ─────────────────────────────────────────────────────────────

    /// @notice Locked liquidity record of a coin. All fields are zero for an unknown coin.
    /// @param token The coin.
    /// @return The record.
    function lockedLiquidity(address token) external view returns (LockedLiquidity memory);

    /// @notice Whether `launcher` may call `placeLiquidity`.
    /// @param launcher Address to check.
    /// @return True when enabled.
    function isLauncher(address launcher) external view returns (bool);

    // ── owner ─────────────────────────────────────────────────────────────

    /// @notice Enables or disables a launcher. Owner only.
    /// @dev    Reverts with `ZeroAddress` when `launcher` is zero.
    /// @param launcher Launcher address.
    /// @param enabled New state.
    function setLauncher(address launcher, bool enabled) external;

    /// @notice Sends stray eth (`token == address(0)`) or erc20 held by the
    ///         locker. The locker holds nothing between calls. Owner only.
    /// @dev    Reverts with `ZeroAddress` when `to` is zero, `RescueForbidden`
    ///         for the PositionManager and `NativeTransferFailed` when an eth
    ///         send fails.
    /// @param token Token, or 0 for eth.
    /// @param to Recipient.
    /// @param amount Amount, token units or wei.
    function rescue(address token, address to, uint256 amount) external;

    /// @notice Stack version tag (Constants.STACK_VERSION).
    /// @return The stack version.
    function STACK_VERSION() external view returns (uint16);
}
