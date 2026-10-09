// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IBurnRouterV2
/// @notice Buys one art coin with the native eth the router holds and burns the coin.
/// @dev    One burn per block across `processBurn` and `processBurnOpenTab`. Each burn offers
///         at most `maxBurnPerCall` wei and moves the pool price by at most `maxImpactBps` bps
///         (bps are 1/10,000). The output must reach the caller's `minOut` and the fee aware
///         spot floor (default BURN_SPOT_FLOOR_DEFAULT_BPS, 8000 bps of the pre swap spot
///         output). The keeper reward is `min(consumed * KEEPER_REWARD_BPS / 10,000,
///         KEEPER_REWARD_CAP)` wei on the eth consumed. Skim refunds credited to the router
///         in the fee escrow are excluded from the consumed amount.
interface IBurnRouterV2 {
    /// @notice The coin and pool were bound.
    /// @param coin The art coin.
    /// @param poolKey Key of the coin's native eth pool.
    event BurnRouterInitialized(address indexed coin, PoolKey poolKey);

    /// @notice A burn completed.
    /// @param caller Keeper that called the burn.
    /// @param ethIn Eth consumed by the swap, net of skim refunds, in wei.
    /// @param burned Coin burned, in coin base units. Includes coin held before the burn.
    /// @param reward Keeper reward paid to `caller`, in wei. Zero when the push failed.
    event Burned(address indexed caller, uint256 ethIn, uint256 burned, uint256 reward);

    /// @notice Escrowed skim refunds were claimed into the router.
    /// @param amount Wei received.
    event RefundClaimed(uint256 amount);

    /// @notice The owner changed `maxImpactBps`.
    /// @param oldBps Previous value in bps.
    /// @param newBps New value in bps.
    event MaxImpactBpsSet(uint16 oldBps, uint16 newBps);

    /// @notice The owner changed `minProcessThreshold`.
    /// @param oldThreshold Previous value in wei.
    /// @param newThreshold New value in wei.
    event MinProcessThresholdSet(uint96 oldThreshold, uint96 newThreshold);

    /// @notice The owner withdrew a token other than the coin.
    /// @param token Withdrawn token.
    /// @param to Receiver.
    /// @param amount Amount in base units.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice The keeper reward push failed and the reward stays in the router.
    /// @param caller Keeper that called the burn.
    /// @param amount Reward that was not paid, in wei.
    event KeeperRewardFailed(address indexed caller, uint256 amount);

    /// @notice The owner changed `openTabCaller`.
    /// @param oldCaller Previous caller.
    /// @param newCaller New caller, zero disables `processBurnOpenTab`.
    event OpenTabCallerSet(address indexed oldCaller, address indexed newCaller);

    /// @notice The owner changed the output floor.
    /// @param oldBps Previous value in bps.
    /// @param newBps New value in bps.
    event SpotFloorBpsSet(uint256 oldBps, uint256 newBps);

    /// @notice The owner changed `maxBurnPerCall`.
    /// @param oldMax Previous value in wei.
    /// @param newMax New value in wei.
    event MaxBurnPerCallSet(uint256 oldMax, uint256 newMax);

    /// @notice The pool fees used by the spot floor were read from the hook.
    /// @param poolId Pool id of the coin's pool.
    /// @param coin The art coin.
    /// @param baselineSkimBps Baseline skim in bps of volume.
    /// @param lpFeePips Lp fee in pips (1/1,000,000).
    event PoolFeesSynced(
        PoolId indexed poolId, address indexed coin, uint256 baselineSkimBps, uint256 lpFeePips
    );

    /// @notice `unlockCallback` caller is not the PoolManager.
    error NotPoolManager();
    /// @notice The swap returned a delta with an unexpected sign or size.
    error BadDelta();
    /// @notice `processBurnOpenTab` caller is not `openTabCaller`.
    error NotOpenTabCaller();

    /// @notice The router is already bound to a coin.
    error AlreadyInitialized();
    /// @notice The router is not yet bound to a coin.
    error NotInitialized();
    /// @notice An address argument is the zero address.
    error ZeroAddress();
    /// @notice The pool key is not a native eth / coin pool, or the pool is not initialized.
    error InvalidPoolKey();
    /// @notice A burn already ran in this block.
    error AlreadyBurnedThisBlock();
    /// @notice The eth balance is below `minProcessThreshold`.
    /// @param balance Eth balance after claiming refunds, in wei.
    /// @param minThreshold Required balance, in wei.
    error BelowMinThreshold(uint256 balance, uint256 minThreshold);
    /// @notice The swap consumed no eth or returned no coin.
    error NothingToBurn();
    /// @notice The coin received is below `minOut` or the spot floor.
    /// @param out Coin received, in coin base units.
    /// @param minOut The violated minimum, in coin base units.
    error InsufficientOutput(uint256 out, uint256 minOut);
    /// @notice A setter value is outside its bounds.
    /// @param value Supplied value.
    /// @param min Lower bound, inclusive.
    /// @param max Upper bound, inclusive.
    error OutOfBounds(uint256 value, uint256 min, uint256 max);
    /// @notice The token is eth or the coin, which are the burn budget.
    /// @param token The requested token.
    error CannotRescue(address token);

    /// @notice Binds the coin and its native eth pool.
    /// @dev Owner only, once. The pool must be native eth / `coin` and initialized. Reverts
    ///      `AlreadyInitialized`, `ZeroAddress` and `InvalidPoolKey`.
    /// @param coin The art coin.
    /// @param poolKey Key of the coin's pool, with `currency0` native eth and `currency1` the coin.
    function initialize(address coin, PoolKey calldata poolKey) external;

    /// @notice Swaps eth for the coin, burns every coin held, and pays the caller the keeper reward.
    /// @dev Callable by anyone. Claims escrowed refunds first. The swap offers
    ///      `min(balance - reward reserve, maxBurnPerCall)` wei and a binding price limit fills
    ///      partially, leaving the remaining eth for later blocks. Reverts `NotInitialized`,
    ///      `AlreadyBurnedThisBlock`, `BelowMinThreshold`, `NothingToBurn` and `InsufficientOutput`.
    /// @param minOut Minimum coin received, in coin base units.
    /// @return ethIn Eth consumed by the swap, net of skim refunds, in wei.
    /// @return burned Coin burned, in coin base units.
    function processBurn(uint256 minOut) external returns (uint256 ethIn, uint256 burned);

    /// @notice Same burn as `processBurn`, settled inside a PoolManager unlock held by the caller.
    /// @dev Callable by `openTabCaller` only. Reverts `NotOpenTabCaller` for other callers and
    ///      with the `processBurn` errors. The PoolManager reverts when the caller does not hold
    ///      the unlock.
    /// @param minOut Minimum coin received, in coin base units.
    /// @return ethIn Eth consumed by the swap, net of skim refunds, in wei.
    /// @return burned Coin burned, in coin base units.
    function processBurnOpenTab(uint256 minOut) external returns (uint256 ethIn, uint256 burned);

    /// @notice Claims the router's eth credit from the fee escrow (hook skim refunds).
    /// @dev Callable by anyone. Returns zero when nothing is credited or the escrow claim fails.
    /// @return amount Wei received.
    function claimRefund() external returns (uint256 amount);

    /// @notice The bound art coin, zero before `initialize`.
    function coin() external view returns (address);

    /// @notice Key of the bound pool.
    function poolKey() external view returns (PoolKey memory);

    /// @notice Block of the last burn, zero before the first.
    function lastBurnBlock() external view returns (uint64);

    /// @notice Cap on the pool price move per burn, in bps. Owner tunable.
    function maxImpactBps() external view returns (uint16);

    /// @notice Minimum eth balance a burn requires, in wei. Owner tunable.
    function minProcessThreshold() external view returns (uint96);

    /// @notice Sets the pool price move cap per burn.
    /// @dev Owner only. Reverts `OutOfBounds` outside [Constants.PRICE_IMPACT_MIN,
    ///      Constants.PRICE_IMPACT_MAX] (25 to 300 bps).
    /// @param bps New cap in bps.
    function setMaxImpactBps(uint16 bps) external;

    /// @notice Sets the minimum eth balance a burn requires.
    /// @dev Owner only. Reverts `OutOfBounds` below Constants.BURN_THRESHOLD_FLOOR (0.001 ether).
    /// @param threshold New minimum in wei.
    function setMinProcessThreshold(uint96 threshold) external;

    /// @notice Sends a token other than eth and the coin to `to`.
    /// @dev Owner only. Reverts `ZeroAddress` when `to` is zero and `CannotRescue` for eth or the coin.
    /// @param token Token to send.
    /// @param to Receiver.
    /// @param amount Amount in base units.
    function rescue(address token, address to, uint256 amount) external;

    /// @notice Re reads the pool baseline skim and lp fee from the hook.
    /// @dev Callable by anyone; the stored values come from `hook.skimConfig`, clamped to
    ///      MAX_BASELINE_SKIM_BPS and MAX_LP_FEE. Reverts `NotInitialized` before `initialize`.
    function syncPoolFees() external;

    /// @notice Minimum coin output a burn enforces for `ethIn` wei consumed at the
    ///         current spot. Zero before `initialize`.
    /// @dev The effective minimum is `max(minOut, floorFor(consumed))`.
    /// @param ethIn Eth consumed, in wei.
    function floorFor(uint256 ethIn) external view returns (uint256);

    /// @notice Current output floor in bps of the fee net spot output.
    function spotFloorBps() external view returns (uint256);

    /// @notice Keeper reward for `consumed` wei: `min(consumed * KEEPER_REWARD_BPS / BPS,
    ///         KEEPER_REWARD_CAP)`, in wei.
    /// @param consumed Eth consumed by the swap, in wei.
    function rewardFor(uint256 consumed) external pure returns (uint256 reward);

    /// @notice Eth the next burn would offer the pool, in wei: balance plus pending
    ///         escrow refunds minus the reward reserve, capped at `maxBurnPerCall`.
    ///         Zero below `minProcessThreshold`.
    function swapBudget() external view returns (uint256);

    /// @notice Sets the eth cap per burn.
    /// @dev Owner only. Reverts `OutOfBounds` outside [Constants.BURN_MAX_PER_CALL_MIN,
    ///      Constants.BURN_MAX_PER_CALL_MAX] (0.1 to 100 ether).
    /// @param maxEth New cap in wei.
    function setMaxBurnPerCall(uint256 maxEth) external;

    /// @notice Sets the only `processBurnOpenTab` caller; zero disables it.
    /// @dev Owner only.
    /// @param caller New caller.
    function setOpenTabCaller(address caller) external;

    /// @notice Sets the output floor.
    /// @dev Owner only. Reverts `OutOfBounds` outside [SPOT_FLOOR_MIN_BPS, SPOT_FLOOR_MAX_BPS].
    /// @param bps New floor in bps of the fee net spot output.
    function setSpotFloorBps(uint256 bps) external;

    /// @notice Uniswap v4 PoolManager. Immutable.
    function poolManager() external view returns (IPoolManager);

    /// @notice Fee escrow holding skim refunds credited to this router. Immutable.
    function feeEscrow() external view returns (address);

    /// @notice The only caller of `processBurnOpenTab`; zero disables it.
    function openTabCaller() external view returns (address);

    /// @notice Maximum eth offered to the pool per burn, in wei. Owner tunable
    ///         within [MAX_BURN_PER_CALL_MIN, MAX_BURN_PER_CALL_MAX].
    function maxBurnPerCall() external view returns (uint256);

    /// @notice Pool baseline skim in bps of volume, subtracted by the spot floor.
    function poolBaselineSkimBps() external view returns (uint24);

    /// @notice Pool lp fee in pips (1/1,000,000), subtracted by the spot floor.
    function poolLpFee() external view returns (uint24);

    /// @notice Lower bound of `maxBurnPerCall`, in wei.
    function MAX_BURN_PER_CALL_MIN() external view returns (uint256);

    /// @notice Upper bound of `maxBurnPerCall`, in wei.
    function MAX_BURN_PER_CALL_MAX() external view returns (uint256);

    /// @notice Initial `maxBurnPerCall`, in wei.
    function DEFAULT_MAX_BURN_PER_CALL() external view returns (uint256);

    /// @notice Gas forwarded on the keeper reward push (no returndata copied).
    function KEEPER_GAS() external view returns (uint256);

    /// @notice Initial `minProcessThreshold`, in wei.
    function DEFAULT_MIN_PROCESS_THRESHOLD() external view returns (uint96);

    /// @notice Stack version tag (Constants.STACK_VERSION).
    function STACK_VERSION() external view returns (uint16);
}
