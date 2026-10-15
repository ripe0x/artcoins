// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsHookStaticFee} from "../../hooks/interfaces/IArtCoinsHookStaticFee.sol";
import {IBurnRouterV2} from "../interfaces/IBurnRouterV2.sol";
import {IBurnableCoin} from "../interfaces/IBurnableCoin.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

/// @title  BurnRouterV2
/// @notice Buys the protocol coin (LAYER) with the eth it receives and burns it.
/// @dev    The coin and its weth pool are constructor immutables. The constructor
///         accepts any initialized key for that pair. The deployment uses the
///         LAYER pool on the legacy static fee hook, whose `pairedFee` is the buy
///         fee (weth in) that `poolBuyFeePips` returns. A pool hook without
///         `pairedFee` falls back to the pool's lp fee.
///         `processBurn` is callable by anyone, once per block (`lastBurnBlock`).
///         It swaps exact input with a price limit `maxImpactBps` from the pre
///         swap spot, requires the output to meet `minOut` and `spotFloorBps` of
///         the spot output net of the buy fee, burns every coin held and pays the
///         caller a reward in eth.
///         The owner sets `maxImpactBps` within [PRICE_IMPACT_MIN, PRICE_IMPACT_MAX],
///         `spotFloorBps` within [SPOT_FLOOR_MIN_BPS, SPOT_FLOOR_MAX_BPS] and the
///         reward values within Constants bounds. Eth, weth and the coin cannot
///         be rescued.
///         The pool's hook must keep `protocolFeeNumerator` at 0. The legacy hook
///         charges it in beforeSwap on the full input of an exact input swap,
///         before the price limit cuts the fill. A nonzero value is paid on the
///         whole budget of every partial fill and counts against the floor, so a
///         large balance fails the floor until it is reset to 0.
contract BurnRouterV2 is
    IBurnRouterV2,
    IConstantsBound,
    IUnlockCallback,
    Ownable2Step,
    ReentrancyGuardTransient
{
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @inheritdoc IBurnRouterV2
    uint256 public constant KEEPER_GAS = 50_000;
    /// @inheritdoc IBurnRouterV2
    uint16 public constant STACK_VERSION = Constants.STACK_VERSION;
    /// @dev Gas for the hook's per direction fee read; a hook without the
    ///      getter falls back to the pool's current lp fee.
    uint256 private constant _FEE_READ_GAS = 30_000;

    /// @inheritdoc IBurnRouterV2
    IPoolManager public immutable poolManager;
    /// @inheritdoc IBurnRouterV2
    address public immutable weth;
    /// @inheritdoc IBurnRouterV2
    address public immutable coin;
    PoolKey internal _poolKey;

    /// @inheritdoc IBurnRouterV2
    uint64 public lastBurnBlock;
    /// @inheritdoc IBurnRouterV2
    uint16 public maxImpactBps;
    /// @inheritdoc IBurnRouterV2
    uint16 public spotFloorBps;
    /// @inheritdoc IBurnRouterV2
    uint16 public rewardMaxBps;
    /// @inheritdoc IBurnRouterV2
    uint256 public keeperTip;
    /// @inheritdoc IBurnRouterV2
    uint256 public keeperGasOverhead;
    /// @inheritdoc IBurnRouterV2
    uint256 public rewardMaxBaseFee;

    /// @param owner_ Owner (Ownable2Step).
    /// @param poolManager_ Uniswap v4 PoolManager.
    /// @param weth_ Wrapped eth, the pool's paired currency.
    /// @param coin_ The coin to buy and burn.
    /// @param key Key of the coin's weth pool. Must be initialized.
    constructor(
        address owner_,
        address poolManager_,
        address weth_,
        address coin_,
        PoolKey memory key
    ) Ownable(owner_) {
        if (poolManager_ == address(0) || weth_ == address(0) || coin_ == address(0)) {
            revert ZeroAddress();
        }
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool weth0 = c0 == weth_ && c1 == coin_;
        if (!weth0 && !(c0 == coin_ && c1 == weth_)) revert InvalidPoolKey();
        (uint160 spot,,,) = IPoolManager(poolManager_).getSlot0(key.toId());
        if (spot == 0) revert InvalidPoolKey();

        poolManager = IPoolManager(poolManager_);
        weth = weth_;
        coin = coin_;
        _poolKey = key;
        maxImpactBps = Constants.PRICE_IMPACT_DEFAULT;
        spotFloorBps = uint16(Constants.BURN_SPOT_FLOOR_BPS);
        rewardMaxBps = Constants.BURN_REWARD_BPS_DEFAULT;
        keeperTip = Constants.BURN_TIP_DEFAULT;
        keeperGasOverhead = Constants.BURN_GAS_OVERHEAD_DEFAULT;
        rewardMaxBaseFee = Constants.BURN_BASEFEE_GATE_DEFAULT;
        emit MaxImpactBpsSet(0, Constants.PRICE_IMPACT_DEFAULT);
        emit SpotFloorBpsSet(0, uint16(Constants.BURN_SPOT_FLOOR_BPS));
        emit RewardConfigSet(
            Constants.BURN_TIP_DEFAULT,
            Constants.BURN_GAS_OVERHEAD_DEFAULT,
            Constants.BURN_BASEFEE_GATE_DEFAULT,
            Constants.BURN_REWARD_BPS_DEFAULT
        );
    }

    /// @notice Accepts the burn budget (eth from the fee controller) and weth unwrapped for rewards.
    receive() external payable {}

    // ── permissionless ────────────────────────────────────────────────────

    /// @inheritdoc IBurnRouterV2
    /// @dev Wraps all eth held. The swap budget is the weth balance minus a reserve
    ///      of `rewardMaxBps` of the balance. A balance above the price limit fills partially and
    ///      drains over later blocks. The reward is `keeperTip` plus the burn's
    ///      gas at the basefee, capped at `rewardMaxBps` of the weth consumed, and
    ///      is zero when `block.basefee` exceeds `rewardMaxBaseFee`.
    function processBurn(uint256 minOut)
        external
        nonReentrant
        returns (uint256 wethIn, uint256 burned)
    {
        uint256 gasStart = gasleft();
        if (lastBurnBlock == block.number) revert AlreadyBurnedThisBlock();
        lastBurnBlock = uint64(block.number);

        uint256 ethBal = address(this).balance;
        if (ethBal != 0) IWETH9(payable(weth)).deposit{value: ethBal}();
        uint256 budget = _budget(SafeTransferLib.balanceOf(weth, address(this)));
        if (budget == 0) revert NothingToBurn();

        (uint160 spot,,,) = poolManager.getSlot0(_poolKey.toId());
        uint256 coinBefore = SafeTransferLib.balanceOf(coin, address(this));
        uint256 coinOut;
        (wethIn, coinOut) =
            abi.decode(poolManager.unlock(abi.encode(budget, spot)), (uint256, uint256));
        if (wethIn == 0 || coinOut == 0) revert NothingToBurn();

        burned = SafeTransferLib.balanceOf(coin, address(this));
        uint256 got = burned - coinBefore;
        if (got < minOut) revert InsufficientOutput(got, minOut);
        uint256 floor = _spotFloor(wethIn, spot);
        if (got < floor) revert InsufficientOutput(got, floor);

        IBurnableCoin(coin).burn(burned);

        uint256 reward = rewardFor(wethIn, gasStart - gasleft() + keeperGasOverhead, block.basefee);
        if (reward != 0) {
            IWETH9(payable(weth)).withdraw(reward);
            address keeper = msg.sender;
            uint256 gasCap = KEEPER_GAS;
            bool ok;
            assembly ("memory-safe") {
                ok := call(gasCap, keeper, reward, codesize(), 0x00, codesize(), 0x00)
            }
            if (!ok) {
                emit KeeperRewardFailed(keeper, reward);
                reward = 0;
            }
        }
        emit Burned(msg.sender, wethIn, burned, reward);
    }

    /// @notice v4 unlock callback for `processBurn`.
    /// @dev Callable by the PoolManager only; reverts `NotPoolManager` otherwise.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 budget, uint160 spot) = abi.decode(data, (uint256, uint160));
        (uint256 wethIn, uint256 coinOut) = _swapAndSettle(budget, spot);
        return abi.encode(wethIn, coinOut);
    }

    // ── reads ─────────────────────────────────────────────────────────────

    /// @inheritdoc IBurnRouterV2
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @inheritdoc IBurnRouterV2
    function wethIsCurrency0() public view returns (bool) {
        return Currency.unwrap(_poolKey.currency0) == weth;
    }

    /// @inheritdoc IBurnRouterV2
    function poolBuyFeePips() public view returns (uint24) {
        return _buyFeePips();
    }

    /// @inheritdoc IBurnRouterV2
    function floorFor(uint256 wethIn) external view returns (uint256) {
        (uint160 spot,,,) = poolManager.getSlot0(_poolKey.toId());
        return _spotFloor(wethIn, spot);
    }

    /// @inheritdoc IBurnRouterV2
    function rewardFor(uint256 consumed, uint256 gasUsed, uint256 baseFee)
        public
        view
        returns (uint256 reward)
    {
        if (baseFee > rewardMaxBaseFee) return 0;
        reward = keeperTip + gasUsed * baseFee;
        uint256 cap = (consumed * rewardMaxBps) / Constants.BPS;
        if (reward > cap) reward = cap;
    }

    /// @inheritdoc IBurnRouterV2
    function swapBudget() external view returns (uint256) {
        return _budget(address(this).balance + SafeTransferLib.balanceOf(weth, address(this)));
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    // ── owner ─────────────────────────────────────────────────────────────

    /// @inheritdoc IBurnRouterV2
    function setMaxImpactBps(uint16 bps) external onlyOwner {
        if (bps < Constants.PRICE_IMPACT_MIN || bps > Constants.PRICE_IMPACT_MAX) {
            revert OutOfBounds(bps, Constants.PRICE_IMPACT_MIN, Constants.PRICE_IMPACT_MAX);
        }
        emit MaxImpactBpsSet(maxImpactBps, bps);
        maxImpactBps = bps;
    }

    /// @inheritdoc IBurnRouterV2
    function setSpotFloorBps(uint16 bps) external onlyOwner {
        if (bps < Constants.SPOT_FLOOR_MIN_BPS || bps > Constants.SPOT_FLOOR_MAX_BPS) {
            revert OutOfBounds(bps, Constants.SPOT_FLOOR_MIN_BPS, Constants.SPOT_FLOOR_MAX_BPS);
        }
        emit SpotFloorBpsSet(spotFloorBps, bps);
        spotFloorBps = bps;
    }

    /// @inheritdoc IBurnRouterV2
    function setRewardConfig(uint256 tip, uint256 gasOverhead, uint256 maxBaseFee, uint16 maxBps)
        external
        onlyOwner
    {
        if (tip > Constants.BURN_TIP_MAX) revert OutOfBounds(tip, 0, Constants.BURN_TIP_MAX);
        if (gasOverhead > Constants.BURN_GAS_OVERHEAD_MAX) {
            revert OutOfBounds(gasOverhead, 0, Constants.BURN_GAS_OVERHEAD_MAX);
        }
        if (maxBaseFee > Constants.BURN_BASEFEE_GATE_MAX) {
            revert OutOfBounds(maxBaseFee, 0, Constants.BURN_BASEFEE_GATE_MAX);
        }
        if (maxBps > Constants.BURN_REWARD_BPS_MAX) {
            revert OutOfBounds(maxBps, 0, Constants.BURN_REWARD_BPS_MAX);
        }
        keeperTip = tip;
        keeperGasOverhead = gasOverhead;
        rewardMaxBaseFee = maxBaseFee;
        rewardMaxBps = maxBps;
        emit RewardConfigSet(tip, gasOverhead, maxBaseFee, maxBps);
    }

    /// @inheritdoc IBurnRouterV2
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0) || token == weth || token == coin) revert CannotRescue(token);
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Rescued(token, to, amount);
    }

    // ── internals ─────────────────────────────────────────────────────────

    /// @dev Balance minus the reward reserve, `rewardMaxBps` of the balance.
    ///      The reward is capped at `rewardMaxBps` of the consumed weth, and
    ///      consumed <= budget < balance, so the reserve covers it after any fill.
    function _budget(uint256 bal) internal view returns (uint256) {
        return bal - (bal * rewardMaxBps) / Constants.BPS;
    }

    /// @dev Exact input weth to coin with the price limit `maxImpactBps` from
    ///      `spot`. Weth as currency0 lowers the price, so the limit is
    ///      spot / sqrt(1 + bps / BPS) rounded up. Weth as currency1 raises it,
    ///      so the limit is spot * sqrt(1 + bps / BPS) rounded down. Runs inside
    ///      the unlock and settles the net PoolManager deltas of the swap.
    function _swapAndSettle(uint256 budget, uint160 spot)
        internal
        returns (uint256 wethIn, uint256 coinOut)
    {
        Currency cw = Currency.wrap(weth);
        Currency cc = Currency.wrap(coin);
        int256 w0 = poolManager.currencyDelta(address(this), cw);
        int256 c0 = poolManager.currencyDelta(address(this), cc);

        bool zeroForOne = wethIsCurrency0();
        uint256 factor =
            FixedPointMathLib.sqrt((Constants.BPS + maxImpactBps) * 1e36 / Constants.BPS);
        uint160 limit;
        if (zeroForOne) {
            uint256 c = FullMath.mulDivRoundingUp(uint256(spot), 1e18, factor);
            limit = c <= uint256(TickMath.MIN_SQRT_PRICE) ? TickMath.MIN_SQRT_PRICE + 1 : uint160(c);
        } else {
            uint256 c = FullMath.mulDiv(uint256(spot), factor, 1e18);
            limit = c >= uint256(TickMath.MAX_SQRT_PRICE) ? TickMath.MAX_SQRT_PRICE - 1 : uint160(c);
        }

        poolManager.swap(
            _poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(budget), sqrtPriceLimitX96: limit
            }),
            ""
        );

        int256 owed = poolManager.currencyDelta(address(this), cw) - w0;
        int256 got = poolManager.currencyDelta(address(this), cc) - c0;
        if (owed > 0 || got < 0) revert BadDelta();
        wethIn = uint256(-owed);
        coinOut = uint256(got);
        if (wethIn > budget) revert BadDelta();

        if (wethIn != 0) {
            poolManager.sync(cw);
            SafeTransferLib.safeTransfer(weth, address(poolManager), wethIn);
            poolManager.settle();
        }
        if (coinOut != 0) poolManager.take(cc, address(this), coinOut);
    }

    /// @dev The pool's fee on a coin buy: the static fee hook's `pairedFee`, the
    ///      fee it sets when the paired currency (weth) is the input. A failed
    ///      read or a value above MAX_LP_FEE uses the pool's current lp fee,
    ///      clamped to MAX_LP_FEE.
    function _buyFeePips() internal view returns (uint24) {
        PoolId pid = _poolKey.toId();
        address h = address(_poolKey.hooks);
        if (h.code.length != 0) {
            (bool ok, bytes memory ret) = h.staticcall{gas: _FEE_READ_GAS}(
                abi.encodeCall(IArtCoinsHookStaticFee.pairedFee, (pid))
            );
            if (ok && ret.length == 32) {
                uint256 f = abi.decode(ret, (uint256));
                if (f <= Constants.MAX_LP_FEE) return uint24(f);
            }
        }
        (,,, uint24 lpFee) = poolManager.getSlot0(pid);
        return lpFee > Constants.MAX_LP_FEE ? Constants.MAX_LP_FEE : lpFee;
    }

    /// @dev Expected coin for `wethIn` at `sqrtPriceX96`, times (1 - buy fee),
    ///      times `spotFloorBps`. price = currency1 per currency0.
    function _spotFloor(uint256 wethIn, uint160 sqrtPriceX96) internal view returns (uint256) {
        if (wethIn == 0 || sqrtPriceX96 == 0) return 0;
        uint256 expected;
        if (wethIsCurrency0()) {
            uint256 step = FullMath.mulDiv(wethIn, sqrtPriceX96, 1 << 96);
            expected = FullMath.mulDiv(step, sqrtPriceX96, 1 << 96);
        } else {
            uint256 step = FullMath.mulDiv(wethIn, 1 << 96, sqrtPriceX96);
            expected = FullMath.mulDiv(step, 1 << 96, sqrtPriceX96);
        }
        uint256 netPpm = Constants.FEE_DENOMINATOR - _buyFeePips();
        return
            FullMath.mulDiv(
                expected, netPpm * spotFloorBps, Constants.FEE_DENOMINATOR * Constants.BPS
            );
    }
}
