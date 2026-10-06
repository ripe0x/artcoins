// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsFeeEscrowV2} from "../interfaces/IArtCoinsFeeEscrowV2.sol";
import {IBurnRouterV2} from "../interfaces/IBurnRouterV2.sol";
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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IBurnableCoin {
    function burn(uint256 amount) external;
}

/// @title  BurnRouterV2
/// @notice Buys one v2 art coin with the native eth it holds and burns it.
/// @dev    v1 differences (review LF-03, LF-04, LF-09, LF-12, DESIGN b6):
///         - one burn per block across both entry points (`lastBurnBlock`),
///           so the per call impact limit cannot be looped inside a tx.
///         - the swap is exact input with a price limit `maxImpactBps` below
///           the pre swap spot (owner bounded [BURN_IMPACT_MIN, MAX]); a big
///           balance partial fills and drains over later blocks, never in one.
///         - keeper reward is `min(consumed * KEEPER_REWARD_BPS / BPS, CAP)`
///           on the eth the swap actually consumed, reserved before the swap
///           and paid after it.
///         - output must clear the caller's `minOut` and `spotFloorBps` of
///           the spot implied output for the eth consumed; `floorFor` exposes
///           the identical computation.
///         - native eth quote, no weth. hook skim refunds (b3) credited to this
///           router in the escrow are pulled by `claimRefund` and at the start
///           of every burn.
///         The coin is burned with the token's own `burn`; every coin this
///         contract holds (including coin sent by the fee controller) is burned
///         on the next successful burn.
contract BurnRouterV2 is
    IBurnRouterV2,
    IConstantsBound,
    IUnlockCallback,
    Ownable2Step,
    ReentrancyGuardTransient
{
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice `unlockCallback` caller is not the PoolManager.
    error NotPoolManager();
    /// @notice The swap returned a delta with an unexpected sign or size.
    error BadDelta();

    /// @notice D31: `processBurnOpenTab` caller is not `openTabCaller`.
    error NotOpenTabCaller();

    event KeeperRewardFailed(address indexed caller, uint256 amount);
    /// @notice D31: owner set the only address allowed to call `processBurnOpenTab`.
    event OpenTabCallerSet(address indexed oldCaller, address indexed newCaller);
    /// @notice D32: owner moved the output floor (bps of the spot implied output).
    event SpotFloorBpsSet(uint256 oldBps, uint256 newBps);

    /// @notice Gas forwarded on the keeper reward push (no returndata copied).
    uint256 public constant KEEPER_GAS = 50_000;
    /// @notice Default minimum eth balance a burn needs.
    uint96 public constant DEFAULT_MIN_PROCESS_THRESHOLD = 0.01 ether;

    IPoolManager public immutable poolManager;
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
    /// @notice D32: output floor in bps of the spot implied output, owner
    ///         tunable within [SPOT_FLOOR_MIN_BPS, SPOT_FLOOR_MAX_BPS].
    uint16 internal _spotFloorBps;
    /// @notice D31: the only caller of `processBurnOpenTab`; zero disables it.
    address public openTabCaller;

    constructor(address owner_, address poolManager_, address feeEscrow_) Ownable(owner_) {
        if (poolManager_ == address(0) || feeEscrow_ == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(poolManager_);
        feeEscrow = feeEscrow_;
        maxImpactBps = Constants.BURN_IMPACT_DEFAULT;
        minProcessThreshold = DEFAULT_MIN_PROCESS_THRESHOLD;
        _spotFloorBps = uint16(Constants.SPOT_FLOOR_BPS);
        emit MaxImpactBpsSet(0, Constants.BURN_IMPACT_DEFAULT);
        emit MinProcessThresholdSet(0, DEFAULT_MIN_PROCESS_THRESHOLD);
        emit SpotFloorBpsSet(0, Constants.SPOT_FLOOR_BPS);
    }

    /// @notice Burn budget arrives as plain eth (fee controller, escrow refunds,
    ///         take of the swap is never eth here).
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
        (uint160 spot,,,) = poolManager.getSlot0(key.toId());
        if (spot == 0) revert InvalidPoolKey();
        coin = coin_;
        _poolKey = key;
        emit BurnRouterInitialized(coin_, key);
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
    /// @dev D31: only `openTabCaller` (owner set, default none). Must run
    ///      while that caller holds the PoolManager unlock; otherwise the
    ///      PoolManager reverts `ManagerLocked`.
    ///      Shares `lastBurnBlock` with `processBurn`, so an outer caller that
    ///      moves the price cannot repeat the burn in the same block.
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

    /// @notice Coin output floor a burn enforces for `ethIn` consumed at the
    ///         current spot. Same computation as the enforced check (LF-12);
    ///         the effective minimum is `max(minOut, floorFor(consumed))`.
    function floorFor(uint256 ethIn) external view returns (uint256) {
        if (coin == address(0)) return 0;
        (uint160 spot,,,) = poolManager.getSlot0(_poolKey.toId());
        return _spotFloor(ethIn, spot);
    }

    /// @notice D32: current output floor in bps.
    function spotFloorBps() external view returns (uint256) {
        return _spotFloorBps;
    }

    /// @notice Keeper reward for `consumed` eth.
    function rewardFor(uint256 consumed) public pure returns (uint256 reward) {
        reward = (consumed * Constants.KEEPER_REWARD_BPS) / Constants.BPS;
        if (reward > Constants.KEEPER_REWARD_CAP) reward = Constants.KEEPER_REWARD_CAP;
    }

    /// @notice What the next burn would offer the pool: balance plus pending
    ///         escrow refunds (claimed first by every burn) minus the reward
    ///         reserve. Zero when below `minProcessThreshold`.
    function swapBudget() external view returns (uint256) {
        uint256 bal = address(this).balance
            + IArtCoinsFeeEscrowV2(feeEscrow).balances(address(this), address(0));
        if (bal < minProcessThreshold) return 0;
        return bal - rewardFor(bal);
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    // ── owner ─────────────────────────────────────────────────────────────

    /// @inheritdoc IBurnRouterV2
    function setMaxImpactBps(uint16 bps) external onlyOwner {
        if (bps < Constants.BURN_IMPACT_MIN || bps > Constants.BURN_IMPACT_MAX) {
            revert OutOfBounds(bps, Constants.BURN_IMPACT_MIN, Constants.BURN_IMPACT_MAX);
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

    /// @notice D31: sets the only `processBurnOpenTab` caller; zero disables it.
    function setOpenTabCaller(address caller) external onlyOwner {
        emit OpenTabCallerSet(openTabCaller, caller);
        openTabCaller = caller;
    }

    /// @notice D32: sets the output floor within Constants bounds.
    function setSpotFloorBps(uint256 bps) external onlyOwner {
        if (bps < Constants.SPOT_FLOOR_MIN_BPS || bps > Constants.SPOT_FLOOR_MAX_BPS) {
            revert OutOfBounds(bps, Constants.SPOT_FLOOR_MIN_BPS, Constants.SPOT_FLOOR_MAX_BPS);
        }
        emit SpotFloorBpsSet(_spotFloorBps, bps);
        _spotFloorBps = uint16(bps);
    }

    /// @inheritdoc IBurnRouterV2
    /// @dev The coin and native eth (the burn budget) can never be rescued.
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0) || token == coin) revert CannotRescue(token);
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Rescued(token, to, amount);
    }

    // ── internals ─────────────────────────────────────────────────────────

    /// @dev Pacing first (effects before interactions), then refunds, then the
    ///      threshold, then the reward reserve.
    function _preflight() internal returns (uint256 budget, uint160 spot, uint256 coinBefore) {
        if (coin == address(0)) revert NotInitialized();
        if (lastBurnBlock == block.number) revert AlreadyBurnedThisBlock();
        lastBurnBlock = uint64(block.number);

        _claimRefund();
        uint256 bal = address(this).balance;
        uint96 threshold = minProcessThreshold;
        if (bal < threshold) revert BelowMinThreshold(bal, threshold);
        budget = bal - rewardFor(bal);

        (spot,,,) = poolManager.getSlot0(_poolKey.toId());
        coinBefore = SafeTransferLib.balanceOf(coin, address(this));
    }

    /// @dev Pulls this router's escrow credit (b3 skim refunds). Never reverts.
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
    ///      which also bounds post / pre >= 1 - bps / BPS. The v1 linear
    ///      `spot * (1 - x / 2)` let pre / post reach 1 + x + x^2 (LF-03, LF-09).
    ///      Must run inside an unlock. Settles exactly the eth consumed.
    function _swapAndSettle(uint256 budget, uint160 spot)
        internal
        returns (uint256 ethIn, uint256 coinOut)
    {
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
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        if (d0 > 0 || d1 < 0) revert BadDelta();
        ethIn = uint256(uint128(-d0));
        coinOut = uint256(uint128(d1));
        if (ethIn > budget) revert BadDelta();

        if (ethIn > 0) poolManager.settle{value: ethIn}();
        if (coinOut > 0) poolManager.take(Currency.wrap(coin), address(this), coinOut);
    }

    /// @dev Checks output against `minOut` and the spot floor using the coin
    ///      actually received (balance delta), burns every coin held, pays the
    ///      reward on consumed eth.
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

    /// @dev Expected coin (currency1) for `ethIn` (currency0) at spot, times
    ///      `spotFloorBps`. price = token1 per token0.
    function _spotFloor(uint256 ethIn, uint160 sqrtPriceX96) internal view returns (uint256) {
        if (ethIn == 0 || sqrtPriceX96 == 0) return 0;
        uint256 step = FullMath.mulDiv(ethIn, sqrtPriceX96, 1 << 96);
        uint256 expected = FullMath.mulDiv(step, sqrtPriceX96, 1 << 96);
        return (expected * _spotFloorBps) / Constants.BPS;
    }
}
