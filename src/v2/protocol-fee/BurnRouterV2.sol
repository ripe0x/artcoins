// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsFeeEscrowV2} from "../interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "../interfaces/IArtCoinsHookV2.sol";
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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  BurnRouterV2
/// @notice Buys one art coin with the native eth it holds and burns the coin.
/// @dev    Properties:
///         - one burn per block across both entry points (`lastBurnBlock`).
///         - the swap is exact input with a price limit `maxImpactBps` below the
///           pre swap spot (owner bounded to [PRICE_IMPACT_MIN, PRICE_IMPACT_MAX]).
///           A balance above the limit fills partially and drains over later blocks.
///         - the offered eth is `min(balance - reward reserve, maxBurnPerCall)`.
///         - keeper reward is `min(consumed * KEEPER_REWARD_BPS / BPS, KEEPER_REWARD_CAP)`
///           on the eth the swap consumed, reserved before the swap and paid after it.
///         - consumed eth excludes skim refunds the hook credited to this router
///           in the escrow.
///         - output must reach the caller's `minOut` and `spotFloorBps` of the spot
///           output for the eth consumed, net of pool baseline skim and lp fee.
///           `floorFor` exposes the same computation.
///         - the quote currency is native eth. Escrow refunds are pulled by
///           `claimRefund` and at the start of every burn.
///         The coin is burned with its own `burn`. Every coin held, including
///         coin sent by the fee controller, burns on the next successful burn.
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
    uint256 public constant MAX_BURN_PER_CALL_MIN = Constants.BURN_MAX_PER_CALL_MIN;
    /// @inheritdoc IBurnRouterV2
    uint256 public constant MAX_BURN_PER_CALL_MAX = Constants.BURN_MAX_PER_CALL_MAX;
    /// @inheritdoc IBurnRouterV2
    uint256 public constant DEFAULT_MAX_BURN_PER_CALL = Constants.BURN_MAX_PER_CALL_DEFAULT;

    /// @inheritdoc IBurnRouterV2
    uint256 public constant KEEPER_GAS = 50_000;
    /// @inheritdoc IBurnRouterV2
    uint96 public constant DEFAULT_MIN_PROCESS_THRESHOLD = 0.01 ether;

    /// @inheritdoc IBurnRouterV2
    IPoolManager public immutable poolManager;
    /// @inheritdoc IBurnRouterV2
    address public immutable feeEscrow;

    /// @inheritdoc IBurnRouterV2
    address public coin;
    PoolKey internal _poolKey;

    /// @inheritdoc IBurnRouterV2
    uint64 public lastBurnBlock;
    /// @inheritdoc IBurnRouterV2
    uint16 public maxImpactBps;
    /// @inheritdoc IBurnRouterV2
    uint96 public minProcessThreshold;
    /// @dev Output floor in bps of the fee net spot output. Owner tunable
    ///      within [SPOT_FLOOR_MIN_BPS, SPOT_FLOOR_MAX_BPS] (5000 to 9500).
    uint16 internal _spotFloorBps;
    /// @inheritdoc IBurnRouterV2
    address public openTabCaller;
    /// @inheritdoc IBurnRouterV2
    uint256 public maxBurnPerCall;
    /// @inheritdoc IBurnRouterV2
    uint24 public poolBaselineSkimBps;
    /// @inheritdoc IBurnRouterV2
    uint24 public poolLpFee;

    constructor(address owner_, address poolManager_, address feeEscrow_) Ownable(owner_) {
        if (poolManager_ == address(0) || feeEscrow_ == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(poolManager_);
        feeEscrow = feeEscrow_;
        maxImpactBps = Constants.PRICE_IMPACT_DEFAULT;
        minProcessThreshold = DEFAULT_MIN_PROCESS_THRESHOLD;
        _spotFloorBps = uint16(Constants.BURN_SPOT_FLOOR_DEFAULT_BPS);
        maxBurnPerCall = DEFAULT_MAX_BURN_PER_CALL;
        emit MaxImpactBpsSet(0, Constants.PRICE_IMPACT_DEFAULT);
        emit MinProcessThresholdSet(0, DEFAULT_MIN_PROCESS_THRESHOLD);
        emit SpotFloorBpsSet(0, Constants.BURN_SPOT_FLOOR_DEFAULT_BPS);
        emit MaxBurnPerCallSet(0, DEFAULT_MAX_BURN_PER_CALL);
    }

    /// @notice Accepts the burn budget: eth from the fee controller and escrow refunds.
    receive() external payable {}

    // ── init ──────────────────────────────────────────────────────────────

    /// @inheritdoc IBurnRouterV2
    /// @dev The pool must be native eth / `coin_` and already initialized.
    function initialize(address coin_, PoolKey calldata key) external onlyOwner {
        if (coin != address(0)) revert AlreadyInitialized();
        if (coin_ == address(0)) revert ZeroAddress();
        if (Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != coin_)
        {
            revert InvalidPoolKey();
        }
        // the escrow and (when present) the pool hook this router binds to must
        // report this build's constants hash. A hookless pool has nothing to check.
        _checkConstants(feeEscrow);
        if (address(key.hooks) != address(0)) _checkConstants(address(key.hooks));
        (uint160 spot,,,) = poolManager.getSlot0(key.toId());
        if (spot == 0) revert InvalidPoolKey();
        coin = coin_;
        _poolKey = key;
        emit BurnRouterInitialized(coin_, key);
        _syncFees(key);
    }

    /// @inheritdoc IBurnRouterV2
    function syncPoolFees() external {
        if (coin == address(0)) revert NotInitialized();
        _syncFees(_poolKey);
    }

    // ── permissionless ────────────────────────────────────────────────────

    /// @inheritdoc IBurnRouterV2
    function processBurn(uint256 minOut)
        external
        nonReentrant
        returns (uint256 ethIn, uint256 burned)
    {
        (uint256 budget, uint160 spot, uint256 coinBefore) = _preflight();
        uint256 coinOut;
        (ethIn, coinOut) =
            abi.decode(poolManager.unlock(abi.encode(budget, spot)), (uint256, uint256));
        burned = _finish(ethIn, coinOut, coinBefore, minOut, spot);
    }

    /// @inheritdoc IBurnRouterV2
    /// @dev `openTabCaller` is set by the owner and is zero by default. The call runs
    ///      while that caller holds the PoolManager unlock, otherwise the PoolManager
    ///      reverts `ManagerLocked`. It shares `lastBurnBlock` with `processBurn`.
    function processBurnOpenTab(uint256 minOut)
        external
        nonReentrant
        returns (uint256 ethIn, uint256 burned)
    {
        if (msg.sender != openTabCaller || msg.sender == address(0)) {
            revert NotOpenTabCaller();
        }
        (uint256 budget, uint160 spot, uint256 coinBefore) = _preflight();
        uint256 coinOut;
        (ethIn, coinOut) = _swapAndSettle(budget, spot);
        burned = _finish(ethIn, coinOut, coinBefore, minOut, spot);
    }

    /// @inheritdoc IBurnRouterV2
    function claimRefund() external nonReentrant returns (uint256 amount) {
        amount = _claimRefund();
    }

    /// @notice v4 unlock callback for `processBurn`.
    /// @dev Callable by the PoolManager only; reverts `NotPoolManager` otherwise.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 budget, uint160 spot) = abi.decode(data, (uint256, uint160));
        (uint256 ethIn, uint256 coinOut) = _swapAndSettle(budget, spot);
        return abi.encode(ethIn, coinOut);
    }

    // ── reads ─────────────────────────────────────────────────────────────

    /// @inheritdoc IBurnRouterV2
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @inheritdoc IBurnRouterV2
    function floorFor(uint256 ethIn) external view returns (uint256) {
        if (coin == address(0)) return 0;
        (uint160 spot,,,) = poolManager.getSlot0(_poolKey.toId());
        return _spotFloor(ethIn, spot);
    }

    /// @inheritdoc IBurnRouterV2
    function spotFloorBps() external view returns (uint256) {
        return _spotFloorBps;
    }

    /// @inheritdoc IBurnRouterV2
    function rewardFor(uint256 consumed) public pure returns (uint256 reward) {
        reward = (consumed * Constants.KEEPER_REWARD_BPS) / Constants.BPS;
        if (reward > Constants.KEEPER_REWARD_CAP) reward = Constants.KEEPER_REWARD_CAP;
    }

    /// @inheritdoc IBurnRouterV2
    function swapBudget() external view returns (uint256) {
        uint256 bal = address(this).balance
            + IArtCoinsFeeEscrowV2(feeEscrow).balances(address(this), address(0));
        if (bal < minProcessThreshold) return 0;
        return _budget(bal);
    }

    /// @inheritdoc IBurnRouterV2
    uint16 public constant STACK_VERSION = Constants.STACK_VERSION;

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    /// @dev `target.constantsHash()` must equal this build's hash.
    function _checkConstants(address target) private view {
        if (target == address(0)) revert ZeroAddress();
        (bool ok, bytes memory ret) =
            target.staticcall(abi.encodeCall(IConstantsBound.constantsHash, ()));
        if (!ok || ret.length != 32 || abi.decode(ret, (bytes32)) != Constants.hash()) {
            revert ConstantsMismatch(target);
        }
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
    function setMinProcessThreshold(uint96 threshold) external onlyOwner {
        if (threshold < Constants.BURN_THRESHOLD_FLOOR) {
            revert OutOfBounds(threshold, Constants.BURN_THRESHOLD_FLOOR, type(uint96).max);
        }
        emit MinProcessThresholdSet(minProcessThreshold, threshold);
        minProcessThreshold = threshold;
    }

    /// @inheritdoc IBurnRouterV2
    function setMaxBurnPerCall(uint256 maxEth) external onlyOwner {
        if (maxEth < Constants.BURN_MAX_PER_CALL_MIN || maxEth > Constants.BURN_MAX_PER_CALL_MAX) {
            revert OutOfBounds(
                maxEth, Constants.BURN_MAX_PER_CALL_MIN, Constants.BURN_MAX_PER_CALL_MAX
            );
        }
        emit MaxBurnPerCallSet(maxBurnPerCall, maxEth);
        maxBurnPerCall = maxEth;
    }

    /// @inheritdoc IBurnRouterV2
    function setOpenTabCaller(address caller) external onlyOwner {
        emit OpenTabCallerSet(openTabCaller, caller);
        openTabCaller = caller;
    }

    /// @inheritdoc IBurnRouterV2
    function setSpotFloorBps(uint256 bps) external onlyOwner {
        if (bps < Constants.SPOT_FLOOR_MIN_BPS || bps > Constants.SPOT_FLOOR_MAX_BPS) {
            revert OutOfBounds(bps, Constants.SPOT_FLOOR_MIN_BPS, Constants.SPOT_FLOOR_MAX_BPS);
        }
        emit SpotFloorBpsSet(_spotFloorBps, bps);
        _spotFloorBps = uint16(bps);
    }

    /// @inheritdoc IBurnRouterV2
    /// @dev Eth and the coin revert `CannotRescue`.
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0) || token == coin) revert CannotRescue(token);
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Rescued(token, to, amount);
    }

    // ── internals ─────────────────────────────────────────────────────────

    /// @dev Order: pacing check and `lastBurnBlock` write, refund claim, threshold
    ///      check, reward reserve.
    function _preflight() internal returns (uint256 budget, uint160 spot, uint256 coinBefore) {
        if (coin == address(0)) revert NotInitialized();
        if (lastBurnBlock == block.number) revert AlreadyBurnedThisBlock();
        lastBurnBlock = uint64(block.number);

        _claimRefund();
        uint256 bal = address(this).balance;
        uint96 threshold = minProcessThreshold;
        if (bal < threshold) revert BelowMinThreshold(bal, threshold);
        budget = _budget(bal);

        (spot,,,) = poolManager.getSlot0(_poolKey.toId());
        coinBefore = SafeTransferLib.balanceOf(coin, address(this));
    }

    /// @dev Balance minus the reward reserve, capped at `maxBurnPerCall`. The
    ///      reserve `rewardFor(bal) >= rewardFor(consumed)` keeps the reward
    ///      payable after any fill.
    function _budget(uint256 bal) internal view returns (uint256 b) {
        b = bal - rewardFor(bal);
        uint256 cap = maxBurnPerCall;
        if (b > cap) b = cap;
    }

    /// @dev Pulls this router's escrow eth credit (skim refunds). A failed claim is skipped.
    function _claimRefund() internal returns (uint256 amount) {
        IArtCoinsFeeEscrowV2 escrow = IArtCoinsFeeEscrowV2(feeEscrow);
        if (escrow.balances(address(this), address(0)) == 0) return 0;
        uint256 before = address(this).balance;
        try escrow.claim(address(this), address(0)) {
            amount = address(this).balance - before;
            emit RefundClaimed(amount);
        } catch {}
    }

    /// @dev Exact input eth (currency0) to coin (currency1). Buying the coin
    ///      lowers the price (coin per eth falls), so the limit is
    ///      spot / sqrt(1 + bps / BPS), rounded up: pre / post <= 1 + bps / BPS,
    ///      which also bounds post / pre >= 1 - bps / BPS.
    ///      Must run inside an unlock. Settles and takes exactly this
    ///      router's net PoolManager deltas (read before and after the swap),
    ///      not the swap's returned delta: a hook that refunds over charged
    ///      skim with `settleFor(router)` inside the swap lowers what is
    ///      owed without changing the returned delta. `ethIn` is the eth
    ///      actually consumed: what is owed minus any skim the hook refunded
    ///      to this router in the escrow instead.
    function _swapAndSettle(uint256 budget, uint160 spot)
        internal
        returns (uint256 ethIn, uint256 coinOut)
    {
        Currency eth = Currency.wrap(address(0));
        Currency c1 = Currency.wrap(coin);
        IArtCoinsFeeEscrowV2 escrow = IArtCoinsFeeEscrowV2(feeEscrow);
        uint256 credit0 = escrow.balances(address(this), address(0));
        int256 e0 = poolManager.currencyDelta(address(this), eth);
        int256 k0 = poolManager.currencyDelta(address(this), c1);

        uint256 factor =
            FixedPointMathLib.sqrt((Constants.BPS + maxImpactBps) * 1e36 / Constants.BPS);
        uint256 c = FullMath.mulDivRoundingUp(uint256(spot), 1e18, factor);
        uint160 limit =
            c <= uint256(TickMath.MIN_SQRT_PRICE) ? TickMath.MIN_SQRT_PRICE + 1 : uint160(c);

        BalanceDelta delta = poolManager.swap(
            _poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(budget), sqrtPriceLimitX96: limit
            }),
            ""
        );
        if (delta.amount0() > 0 || delta.amount1() < 0) revert BadDelta();

        int256 owed = poolManager.currencyDelta(address(this), eth) - e0;
        int256 got = poolManager.currencyDelta(address(this), c1) - k0;
        if (owed > 0 || got < 0) revert BadDelta();
        uint256 paid = uint256(-owed);
        coinOut = uint256(got);
        if (paid > budget) revert BadDelta();

        if (paid > 0) poolManager.settle{value: paid}();
        if (coinOut > 0) poolManager.take(c1, address(this), coinOut);

        uint256 credit1 = escrow.balances(address(this), address(0));
        uint256 refunded = credit1 > credit0 ? credit1 - credit0 : 0;
        ethIn = paid > refunded ? paid - refunded : 0;
    }

    /// @dev Checks output against `minOut` and the spot floor using the coin
    ///      actually received (balance delta), burns every coin held, pays the
    ///      reward on consumed eth (net of any skim refund).
    function _finish(
        uint256 ethIn,
        uint256 coinOut,
        uint256 coinBefore,
        uint256 minOut,
        uint160 spot
    ) internal returns (uint256 burned) {
        if (ethIn == 0 || coinOut == 0) revert NothingToBurn();
        address c = coin;
        burned = SafeTransferLib.balanceOf(c, address(this));
        uint256 got = burned - coinBefore;
        if (got < minOut) revert InsufficientOutput(got, minOut);
        uint256 floor = _spotFloor(ethIn, spot);
        if (got < floor) revert InsufficientOutput(got, floor);

        IBurnableCoin(c).burn(burned);

        uint256 reward = rewardFor(ethIn);
        if (reward > 0) {
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
        emit Burned(msg.sender, ethIn, burned, reward);
    }

    /// @dev The pool fees, read from `hook.skimConfig(poolId)`
    ///      (zero for a hookless pool or a hook that does not answer), clamped
    ///      to the Constants caps. `baselineSkimBps` in BPS of volume,
    ///      `lpFeePips` in pips (1/1,000,000).
    function _syncFees(PoolKey memory key) internal {
        uint256 s;
        uint256 f;
        address h = address(key.hooks);
        if (h.code.length != 0) {
            try IArtCoinsHookV2(h).skimConfig(key.toId()) returns (
                IArtCoinsHookV2.SkimConfig memory cfg
            ) {
                s = cfg.baselineSkimBps;
                f = cfg.lpFeePips;
            } catch {}
            if (s > Constants.MAX_BASELINE_SKIM_BPS) s = Constants.MAX_BASELINE_SKIM_BPS;
            if (f > Constants.MAX_LP_FEE) f = Constants.MAX_LP_FEE;
        }
        poolBaselineSkimBps = uint24(s);
        poolLpFee = uint24(f);
        emit PoolFeesSynced(key.toId(), Currency.unwrap(key.currency1), s, f);
    }

    /// @dev 1 - baseline skim - lp fee, in pips (at least 800,000 by the caps).
    function _netPpm() internal view returns (uint256) {
        uint256 skimPpm = uint256(poolBaselineSkimBps) * (Constants.FEE_DENOMINATOR / Constants.BPS);
        return Constants.FEE_DENOMINATOR - skimPpm - poolLpFee;
    }

    /// @dev Expected coin (currency1) for `ethIn` (currency0) at spot, times
    ///      (1 - baseline skim - lp fee) times `spotFloorBps`.
    ///      price = token1 per token0.
    function _spotFloor(uint256 ethIn, uint160 sqrtPriceX96) internal view returns (uint256) {
        if (ethIn == 0 || sqrtPriceX96 == 0) return 0;
        uint256 step = FullMath.mulDiv(ethIn, sqrtPriceX96, 1 << 96);
        uint256 expected = FullMath.mulDiv(step, sqrtPriceX96, 1 << 96);
        return FullMath.mulDiv(
            expected, _netPpm() * _spotFloorBps, Constants.FEE_DENOMINATOR * Constants.BPS
        );
    }
}
