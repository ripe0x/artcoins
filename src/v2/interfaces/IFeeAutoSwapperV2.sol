// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IFeeAutoSwapperV2
/// @notice Occupies a locker reward slot for one art coin. `convert` swaps the
///         coin side fees to native eth on the coin's pool and `flushPaired`
///         forwards the eth side. Both forward the whole eth balance to the
///         immutable `endRecipient`.
/// @dev    The swapper sets escrow `selfClaimOnly` for itself and holds no eth
///         after `convert` or `flushPaired`. `supportsInterface` returns true
///         for `type(IFeeAutoSwapperV2).interfaceId`. Bps are 1/10,000.
interface IFeeAutoSwapperV2 is IERC165 {
    // ── events ────────────────────────────────────────────────────────────

    /// @notice The art coin was bound to this swapper.
    /// @param coin The art coin.
    event CoinBound(address indexed coin);

    /// @notice A `convert` call completed.
    /// @param caller Keeper that called `convert`.
    /// @param coinIn Coin consumed by the swap, in base units.
    /// @param pairedOut Gross eth received from the swap, in wei.
    /// @param pairedToRecipient Wei pushed to `endRecipient` (or credited in the escrow).
    /// @param pairedToKeeper Wei paid to `caller` as keeper reward.
    event Converted(
        address indexed caller,
        uint256 coinIn,
        uint256 pairedOut,
        uint256 pairedToRecipient,
        uint256 pairedToKeeper
    );

    /// @notice A `flushPaired` call completed.
    /// @param caller Keeper that called `flushPaired`.
    /// @param pairedOut Wei forwarded before the keeper reward.
    /// @param pairedToRecipient Wei pushed to `endRecipient` (or credited in the escrow).
    /// @param pairedToKeeper Wei paid to `caller` as keeper reward.
    event Flushed(
        address indexed caller, uint256 pairedOut, uint256 pairedToRecipient, uint256 pairedToKeeper
    );

    /// @notice The owner changed `maxSlippageBps`.
    /// @param oldBps Previous value in bps.
    /// @param newBps New value in bps.
    event MaxSlippageBpsSet(uint256 oldBps, uint256 newBps);

    /// @notice The owner changed `minBlocksBetweenConverts`.
    /// @param oldBlocks Previous value in blocks.
    /// @param newBlocks New value in blocks.
    event MinBlocksBetweenConvertsSet(uint256 oldBlocks, uint256 newBlocks);

    /// @notice The owner changed `maxStepIn`.
    /// @param oldMax Previous value in coin base units.
    /// @param newMax New value in coin base units.
    event MaxStepInSet(uint256 oldMax, uint256 newMax);

    /// @notice The owner withdrew a token that is neither eth nor the art coin.
    /// @param token Withdrawn token.
    /// @param to Receiver.
    /// @param amount Amount in base units.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice The owner changed the output floor.
    /// @param oldBps Previous value in bps.
    /// @param newBps New value in bps.
    event SpotFloorBpsSet(uint256 oldBps, uint256 newBps);

    /// @notice The owner changed `maxImpactBps`.
    /// @param oldBps Previous value in bps.
    /// @param newBps New value in bps.
    event MaxImpactBpsSet(uint256 oldBps, uint256 newBps);

    /// @notice The pool fees used by the spot floor were read from the hook.
    /// @param poolId Pool id of the coin's pool.
    /// @param coin The art coin.
    /// @param baselineSkimBps Baseline skim in bps of volume.
    /// @param lpFeePips Lp fee in pips (1/1,000,000).
    event PoolFeesSynced(
        PoolId indexed poolId, address indexed coin, uint256 baselineSkimBps, uint256 lpFeePips
    );

    // ── errors ────────────────────────────────────────────────────────────

    /// @notice An address argument is the zero address.
    error ZeroAddress();
    /// @notice The end recipient is this swapper or the fee escrow.
    error InvalidEndRecipient();
    /// @notice Caller of `setup` is not the deployer.
    error NotDeployer();
    /// @notice The coin is already bound.
    error AlreadyFinalized();
    /// @notice The coin is not yet bound.
    error NotFinalized();
    /// @notice `convert` was called before the pacing window elapsed.
    /// @param nextBlock First block at which `convert` is allowed.
    error ConvertTooEarly(uint256 nextBlock);
    /// @notice The coin balance, including escrowed coin, is zero.
    error NothingToConvert();
    /// @notice The eth balance, including escrowed eth, is zero.
    error NothingToFlush();
    /// @notice The swap output is below the caller supplied `minOut`.
    /// @param received Eth received, in wei.
    /// @param minOut Caller minimum, in wei.
    error InsufficientOutput(uint256 received, uint256 minOut);
    /// @notice The swap output is below the fee aware spot floor.
    /// @param minOut Eth received, in wei.
    /// @param floor Required minimum, in wei.
    error MinOutBelowFloor(uint256 minOut, uint256 floor);
    /// @notice The swap consumed more coin than requested.
    /// @param spent Coin consumed.
    /// @param requested Coin requested.
    error ExcessInputSpent(uint256 spent, uint256 requested);
    /// @notice A setter value is outside its Constants bounds.
    /// @param value Supplied value.
    /// @param min Lower bound, inclusive.
    /// @param max Upper bound, inclusive.
    error OutOfBounds(uint256 value, uint256 min, uint256 max);
    /// @notice The swap returned a delta with an unexpected sign.
    error BadDelta();
    /// @notice The token is eth or the art coin, which belong to `endRecipient`.
    /// @param token The requested token.
    error CannotRescue(address token);

    /// @notice `unlockCallback` caller is not the PoolManager.
    error NotPoolManager();
    /// @notice `convert` was called a second time in one block.
    error AlreadyConvertedThisBlock();

    // ── permissionless ────────────────────────────────────────────────────

    /// @notice Claims escrowed coin, swaps up to `maxStepIn` coin to eth, forwards the output
    ///         plus any held eth to `endRecipient`, and pays the caller a keeper reward.
    /// @dev Callable by anyone. The reward is `min(pairedOut * KEEPER_REWARD_BPS / 10,000,
    ///      KEEPER_REWARD_CAP)` in wei. The swap price limit moves the pool price by at most
    ///      `min(maxImpactBps, maxSlippageBps)` bps and a limited swap fills partially.
    ///      The output must reach `minOut` and the fee aware spot floor: `spotFloorBps`
    ///      (default CONVERT_SPOT_FLOOR_DEFAULT_BPS, 9500) of the pre swap spot output for
    ///      the coin consumed, net of the pool baseline skim and lp fee.
    ///      One convert per block, then `minBlocksBetweenConverts` blocks between converts.
    ///      Reverts `NotFinalized`, `AlreadyConvertedThisBlock`, `ConvertTooEarly`,
    ///      `NothingToConvert`, `ExcessInputSpent`, `InsufficientOutput`, `MinOutBelowFloor`
    ///      and `BadDelta`.
    /// @param minOut Minimum eth output in wei.
    /// @return pairedOut Gross eth received from the swap, in wei.
    function convert(uint256 minOut) external returns (uint256 pairedOut);

    /// @notice Claims escrowed eth if any, then forwards the whole eth balance to `endRecipient`
    ///         and pays the caller a keeper reward.
    /// @dev Callable by anyone, before or after `setup`. Reverts `NothingToFlush` when the
    ///      eth balance is zero.
    /// @return pairedOut Wei forwarded before the keeper reward.
    function flushPaired() external returns (uint256 pairedOut);

    // ── setup ─────────────────────────────────────────────────────────────

    /// @notice Binds the art coin after the factory launch and reads the pool fees from the hook.
    /// @dev Callable once by the deployer. Reverts `NotDeployer`, `AlreadyFinalized` and
    ///      `ZeroAddress` when `coin_` is zero.
    /// @param coin_ The art coin.
    function setup(address coin_) external;

    /// @notice True once the coin is bound.
    function setupFinalized() external view returns (bool);

    // ── reads ─────────────────────────────────────────────────────────────

    /// @notice The bound art coin, zero before `setup`.
    function coin() external view returns (address);

    /// @notice Receiver of all forwarded eth. Immutable.
    function endRecipient() external view returns (address);

    /// @notice Fee escrow used as push fallback and claim source. Immutable.
    function feeEscrow() external view returns (address);

    /// @notice Key of the coin's native eth pool.
    function poolKey() external view returns (PoolKey memory);

    /// @notice Cap on the pool price move per convert, in bps. Owner tunable.
    function maxSlippageBps() external view returns (uint256);

    /// @notice Minimum blocks between two converts. Owner tunable.
    function minBlocksBetweenConverts() external view returns (uint256);

    /// @notice Maximum coin swapped per convert, in coin base units. Owner tunable.
    function maxStepIn() external view returns (uint256);

    /// @notice First block at which `convert` passes the pacing check.
    function nextConvertibleBlock() external view returns (uint256);

    /// @notice Coin held plus coin credited in the escrow, in coin base units.
    function accruedCoin() external view returns (uint256);

    /// @notice Eth held plus eth credited in the escrow, in wei.
    function accruedPaired() external view returns (uint256);

    // ── owner (within Constants bounds) ───────────────────────────────────

    /// @notice Sets the pool price move cap per convert.
    /// @dev Owner only. Reverts `OutOfBounds` outside [SWAPPER_SLIPPAGE_MIN, SWAPPER_SLIPPAGE_MAX]
    ///      (50 to 1000 bps).
    /// @param bps New cap in bps.
    function setMaxSlippageBps(uint256 bps) external;

    /// @notice Sets the pacing between converts.
    /// @dev Owner only. Reverts `OutOfBounds` outside [SWAPPER_MIN_BLOCKS_MIN, SWAPPER_MIN_BLOCKS_MAX]
    ///      (1 to 50,400 blocks).
    /// @param blocks New value in blocks.
    function setMinBlocksBetweenConverts(uint256 blocks) external;

    /// @notice Sets the maximum coin swapped per convert.
    /// @dev Owner only. Reverts `OutOfBounds` when `maxIn` is zero or above the int128 maximum.
    /// @param maxIn New value in coin base units.
    function setMaxStepIn(uint256 maxIn) external;

    /// @notice Sends a token other than eth and the art coin to `to`.
    /// @dev Owner only. Reverts `ZeroAddress` when `to` is zero, `NotFinalized` before `setup`,
    ///      and `CannotRescue` for eth or the art coin.
    /// @param token Token to send.
    /// @param to Receiver.
    /// @param amount Amount in base units.
    function rescue(address token, address to, uint256 amount) external;

    /// @notice Re reads the pool baseline skim and lp fee from the hook.
    /// @dev Callable by anyone; the stored values come from `hook.skimConfig`, clamped to
    ///      MAX_BASELINE_SKIM_BPS and MAX_LP_FEE. Reverts `NotFinalized` before `setup`.
    function syncPoolFees() external;

    /// @notice Minimum eth output `convert` enforces for `artIn` coin consumed at the
    ///         current spot, in wei. Zero before `setup`.
    /// @param artIn Coin consumed, in coin base units.
    function floorFor(uint256 artIn) external view returns (uint256);

    /// @notice Sets the price impact cap per convert.
    /// @dev Owner only. Reverts `OutOfBounds` outside [PRICE_IMPACT_MIN, PRICE_IMPACT_MAX].
    /// @param bps New cap in bps.
    function setMaxImpactBps(uint256 bps) external;

    /// @notice Sets the output floor.
    /// @dev Owner only. Reverts `OutOfBounds` outside [SPOT_FLOOR_MIN_BPS, SPOT_FLOOR_MAX_BPS].
    /// @param bps New floor in bps of the fee net spot output.
    function setSpotFloorBps(uint256 bps) external;

    /// @notice Uniswap v4 PoolManager. Immutable.
    function poolManager() external view returns (IPoolManager);

    /// @notice Hook of the coin's pool. Immutable.
    function hook() external view returns (address);

    /// @notice Pool fee field of the pool key. Immutable.
    function poolFee() external view returns (uint24);

    /// @notice Tick spacing of the pool key. Immutable.
    function tickSpacing() external view returns (int24);

    /// @notice Block of the last successful `convert`, zero before the first.
    function lastConvertBlock() external view returns (uint256);

    /// @notice Output floor in bps of the fee net spot output. Owner tunable
    ///         within [SPOT_FLOOR_MIN_BPS, SPOT_FLOOR_MAX_BPS] (5000 to 9500).
    function spotFloorBps() external view returns (uint256);

    /// @notice Price impact cap per convert in bps. Owner tunable within
    ///         [PRICE_IMPACT_MIN, PRICE_IMPACT_MAX] (25 to 300). The swap price
    ///         limit uses the lower of this and `maxSlippageBps`.
    function maxImpactBps() external view returns (uint256);

    /// @notice Pool baseline skim in bps of volume, subtracted by the spot floor.
    function poolBaselineSkimBps() external view returns (uint24);

    /// @notice Pool lp fee in pips (1/1,000,000), subtracted by the spot floor.
    function poolLpFee() external view returns (uint24);

    /// @notice Gas forwarded on the push to `endRecipient`. A failed push is
    ///         credited to `endRecipient` in the escrow.
    function END_RECIPIENT_GAS() external view returns (uint256);

    /// @notice Gas forwarded on the keeper reward push. A failed push sends the
    ///         reward to `endRecipient`.
    function KEEPER_GAS() external view returns (uint256);

    /// @notice Upper bound of `maxStepIn`, in coin base units (v4 swap amounts are int128).
    function MAX_STEP_IN_CEILING() external view returns (uint256);

    /// @notice Initial `spotFloorBps`: 9500 bps of the fee net spot output.
    function CONVERT_SPOT_FLOOR_DEFAULT_BPS() external view returns (uint256);

    /// @notice Stack version tag (Constants.STACK_VERSION).
    function STACK_VERSION() external view returns (uint16);
}
