// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IBurnRouterV2
/// @notice Buys the protocol coin (LAYER) with the eth and weth the router holds and burns it.
/// @dev    The coin and its weth pool are fixed at construction. One burn per block. Each burn
///         is an exact input swap with a price limit `maxImpactBps` (1/10,000) from the pre swap
///         spot, so a large balance fills partially and drains over blocks. The output must reach
///         the caller's `minOut` and `spotFloorBps` of the spot output net of the pool's buy
///         fee. The keeper reward, paid in eth, is `keeperTip` plus the burn's gas at the
///         basefee, capped at `rewardMaxBps` of the weth consumed, and zero when the basefee
///         is above `rewardMaxBaseFee`. The impact cap, the floor and every reward value are
///         owner tunable within Constants bounds. A nonzero hook `protocolFee` is charged on the
///         full input of an exact input swap and reduces the weth the floor prices at spot.
///         The deployment keeps the hook's `protocolFeeNumerator` at 0.
interface IBurnRouterV2 {
    /// @notice A burn completed.
    /// @param caller Keeper that called the burn.
    /// @param wethIn Weth consumed by the swap, in wei.
    /// @param burned Coin burned, in coin base units. Includes coin held before the burn.
    /// @param reward Keeper reward paid to `caller`, in wei. Zero when the push failed.
    event Burned(address indexed caller, uint256 wethIn, uint256 burned, uint256 reward);

    /// @notice The keeper reward push failed and the reward stays in the router.
    /// @param caller Keeper that called the burn.
    /// @param amount Reward that was not paid, in wei.
    event KeeperRewardFailed(address indexed caller, uint256 amount);

    /// @notice The owner changed `maxImpactBps`.
    /// @param oldBps Previous value in bps.
    /// @param newBps New value in bps.
    event MaxImpactBpsSet(uint16 oldBps, uint16 newBps);

    /// @notice The owner changed `spotFloorBps`.
    /// @param oldBps Previous value in bps.
    /// @param newBps New value in bps.
    event SpotFloorBpsSet(uint16 oldBps, uint16 newBps);

    /// @notice The owner changed the keeper reward values.
    /// @param tip Flat reward in wei.
    /// @param gasOverhead Gas added to the measured burn gas.
    /// @param maxBaseFee Highest basefee that pays a reward, in wei.
    /// @param maxBps Reward cap in bps of the weth consumed.
    event RewardConfigSet(uint256 tip, uint256 gasOverhead, uint256 maxBaseFee, uint16 maxBps);

    /// @notice The owner withdrew a token other than eth, weth and the coin.
    /// @param token Withdrawn token.
    /// @param to Receiver.
    /// @param amount Amount in base units.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice `unlockCallback` caller is not the PoolManager.
    error NotPoolManager();
    /// @notice The swap returned a delta with an unexpected sign or size.
    error BadDelta();
    /// @notice An address argument is the zero address.
    error ZeroAddress();
    /// @notice The pool key does not pair the coin with weth, or the pool is not initialized.
    error InvalidPoolKey();
    /// @notice A burn already ran in this block.
    error AlreadyBurnedThisBlock();
    /// @notice The router holds nothing to swap, or the swap moved nothing.
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
    /// @notice The token is eth, weth or the coin, which are the burn budget.
    /// @param token The requested token.
    error CannotRescue(address token);

    /// @notice Wraps the eth held, swaps the weth for the coin, burns every coin held, and pays
    ///         the caller the keeper reward.
    /// @dev Callable by anyone. The swap offers `balance - reward reserve` and a binding price
    ///      limit fills partially, leaving the remaining weth for later blocks. Reverts
    ///      `AlreadyBurnedThisBlock`, `NothingToBurn` and `InsufficientOutput`.
    /// @param minOut Minimum coin received, in coin base units.
    /// @return wethIn Weth consumed by the swap, in wei.
    /// @return burned Coin burned, in coin base units.
    function processBurn(uint256 minOut) external returns (uint256 wethIn, uint256 burned);

    /// @notice The coin this router buys and burns (LAYER).
    function coin() external view returns (address);

    /// @notice The pool's paired currency, wrapped eth.
    function weth() external view returns (address);

    /// @notice Key of the coin's weth pool.
    function poolKey() external view returns (PoolKey memory);

    /// @notice True when weth is `currency0` of the pool.
    function wethIsCurrency0() external view returns (bool);

    /// @notice Block of the last burn, zero before the first.
    function lastBurnBlock() external view returns (uint64);

    /// @notice Cap on the pool price move per burn, in bps. Owner tunable.
    function maxImpactBps() external view returns (uint16);

    /// @notice Sets the pool price move cap per burn.
    /// @dev Owner only. Reverts `OutOfBounds` outside [Constants.PRICE_IMPACT_MIN,
    ///      Constants.PRICE_IMPACT_MAX] (25 to 300 bps).
    /// @param bps New cap in bps.
    function setMaxImpactBps(uint16 bps) external;

    /// @notice Sends a token other than eth, weth and the coin to `to`.
    /// @dev Owner only. Reverts `ZeroAddress` when `to` is zero and `CannotRescue` for eth, weth
    ///      or the coin.
    /// @param token Token to send.
    /// @param to Receiver.
    /// @param amount Amount in base units.
    function rescue(address token, address to, uint256 amount) external;

    /// @notice Lp fee the pool charges a coin buy (weth in), in pips (1/1,000,000). Read from
    ///         the pool's hook when it exposes a per direction fee (`pairedFee`), else from the pool.
    function poolBuyFeePips() external view returns (uint24);

    /// @notice Minimum coin output of a full fill that consumes `wethIn` wei at the current spot:
    ///         spot output, net of `poolBuyFeePips` and the hook's `protocolFee()` charge on
    ///         `wethIn`, times `spotFloorBps`.
    /// @dev Equals `floorForPartial(wethIn, wethIn)`. The effective minimum is `max(minOut, floor)`.
    /// @param wethIn Weth consumed, in wei.
    function floorFor(uint256 wethIn) external view returns (uint256);

    /// @notice Minimum coin output a burn enforces when it offers `budget` and consumes `consumed`.
    /// @dev The hook charge is taken on `budget`, the weth priced at spot is `consumed` less that
    ///      charge. Equals `floorFor(consumed)` when `consumed == budget`.
    /// @param budget Weth offered to the swap, in wei.
    /// @param consumed Weth the swap consumed, in wei.
    function floorForPartial(uint256 budget, uint256 consumed) external view returns (uint256);

    /// @notice Keeper reward in wei: zero when `baseFee > rewardMaxBaseFee`, else
    ///         `min(keeperTip + gasUsed * baseFee, consumed * rewardMaxBps / 10,000)`.
    /// @param consumed Weth consumed by the swap, in wei.
    /// @param gasUsed Gas the burn used, `keeperGasOverhead` included.
    /// @param baseFee Block basefee in wei.
    function rewardFor(uint256 consumed, uint256 gasUsed, uint256 baseFee)
        external
        view
        returns (uint256 reward);

    /// @notice Weth the next burn would offer the pool, in wei: eth plus weth held minus the
    ///         reward reserve (`rewardMaxBps` of that total).
    function swapBudget() external view returns (uint256);

    /// @notice Output floor in bps of the fee net spot output. Owner tunable.
    function spotFloorBps() external view returns (uint16);

    /// @notice Flat part of the keeper reward, in wei. Owner tunable.
    function keeperTip() external view returns (uint256);

    /// @notice Gas added to the measured burn gas for the reimbursement: the transaction base
    ///         cost, calldata and the reward push. Owner tunable.
    function keeperGasOverhead() external view returns (uint256);

    /// @notice Highest block basefee at which a burn pays a keeper reward, in wei. Owner tunable.
    function rewardMaxBaseFee() external view returns (uint256);

    /// @notice Cap on the keeper reward, in bps of the weth consumed; also the share of the
    ///         balance reserved for it. Owner tunable.
    function rewardMaxBps() external view returns (uint16);

    /// @notice Sets the output floor.
    /// @dev Owner only. Reverts `OutOfBounds` outside [Constants.SPOT_FLOOR_MIN_BPS,
    ///      Constants.SPOT_FLOOR_MAX_BPS] (5000 to 9500).
    /// @param bps New floor in bps of the fee net spot output.
    function setSpotFloorBps(uint16 bps) external;

    /// @notice Sets the keeper reward values.
    /// @dev Owner only. Reverts `OutOfBounds` above Constants.BURN_TIP_MAX (0.01 ether),
    ///      BURN_GAS_OVERHEAD_MAX (300,000), BURN_BASEFEE_GATE_MAX (100 gwei) or
    ///      BURN_REWARD_BPS_MAX (5000). Zero is allowed for each: a zero tip and gate turns
    ///      the reward off.
    /// @param tip Flat reward in wei.
    /// @param gasOverhead Gas added to the measured burn gas.
    /// @param maxBaseFee Highest basefee that pays a reward, in wei.
    /// @param maxBps Reward cap and reserve, in bps of the weth consumed.
    function setRewardConfig(uint256 tip, uint256 gasOverhead, uint256 maxBaseFee, uint16 maxBps)
        external;

    /// @notice Uniswap v4 PoolManager. Immutable.
    function poolManager() external view returns (IPoolManager);

    /// @notice Gas forwarded on the keeper reward push (no returndata copied).
    function KEEPER_GAS() external view returns (uint256);

    /// @notice Stack version tag (Constants.STACK_VERSION).
    function STACK_VERSION() external view returns (uint16);
}
