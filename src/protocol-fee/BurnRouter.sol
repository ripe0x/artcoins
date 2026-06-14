// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

/// @title  BurnRouter
/// @notice LAYER buy-and-burn engine. Accumulated WETH (and any native ETH,
///         wrapped on entry) is swapped for LAYER and burned. Two permissionless
///         entrypoints, both paying a small keeper reward off the top and both
///         executing the SAME direct `poolManager.swap` on the LAYER pool:
///           - `processBurnWeth`        — opens its own `poolManager.unlock`,
///                                        for standalone (top-level) keeper calls.
///           - `processBurnWethOpenTab` — swaps on an already-open V4 tab (no
///                                        nested unlock), so a per-swap pool
///                                        extension can drive the burn keeper-less.
///         There is no Universal Router / Permit2 dependency — the contract
///         settles its own swap deltas (`sync`/`settle`/`take`) directly.
///
///         Slippage is protected by two complementary, fully on-chain
///         mechanisms — no manual tuning, no admin knob, nothing to keep current:
///           - a per-call price-impact clamp (`MAX_SWAP_IMPACT_BPS`) on the
///             swap's `sqrtPriceLimitX96`, set BELOW the LAYER pool's
///             round-trip fee moat: a single burn can move the pool by at most
///             this much, so it can't move the price enough to repay a
///             sandwicher's buy/sell round trip — the sandwich is uneconomic
///             by construction. A large balance fills PARTIALLY and drains over
///             several calls instead of dumping at a bad rate (and never gets
///             stuck on a thin/launch pool);
///           - an output floor (`FLOOR_BPS` of the spot-implied LAYER out for
///             the amount ACTUALLY consumed) as a post-swap backstop.
///
/// @dev    The keeper reward is taken from the WETH balance before the swap:
///         a small slice is unwrapped to native ETH and sent to msg.sender
///         after the swap+burn completes. If the recipient rejects ETH,
///         the unwrapped balance stays in the contract; the next call's
///         pre-wrap step folds it into the next burn cycle.
contract BurnRouter is Ownable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ─── errors ──────────────────────────────────────────────────────────

    error AlreadyInitialized();
    error NotInitialized();
    error ZeroAddress();
    error InvalidPoolKey();
    error BlockedToken(address token);
    error BelowMinThreshold(uint256 wethBalance, uint256 minThreshold);
    error MinThresholdTooLow();
    error NothingToBurn();
    error EthTransferFailed();
    /// @notice `unlockCallback` was called by anything other than the PoolManager.
    error OnlyPoolManager();
    /// @notice The swap produced less LAYER than the effective minimum (the
    ///         larger of the caller's `minLayerOut` and the spot-derived floor).
    ///         Enforced post-swap because a direct `poolManager.swap` has no
    ///         built-in `amountOutMinimum`.
    error InsufficientLayerOut(uint256 layerOut, uint256 requiredMinLayerOut);

    // ─── events ──────────────────────────────────────────────────────────

    event BurnRouterInitialized(address indexed layerToken, address indexed weth, PoolKey poolKey);
    event LayerBurnedDirectly(uint256 amount);
    event WethProcessedForLayerBurn(uint256 wethIn, uint256 layerOut);
    /// @notice Emitted when WETH is processed for a LAYER burn via the
    ///         open-tab direct-swap path (`processBurnWethOpenTab`), driven
    ///         from inside another pool's already-open V4 swap. `wethIn` is
    ///         the WETH actually consumed by the swap (may be below the
    ///         requested input on a partial fill).
    event WethProcessedForLayerBurnOpenTab(uint256 wethIn, uint256 layerOut);
    event LayerPurchasedAndBurned(uint256 layerAmount);
    event MinThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event EthReceived(address indexed from, uint256 amount);
    /// @notice Emitted when an admin sweeps a held non-LAYER, non-WETH token.
    event HeldTokenSwept(address indexed token, address indexed to, uint256 amount);
    /// @notice Emitted when the per-call keeper reward is paid to msg.sender.
    event KeeperReward(address indexed caller, uint256 amount);
    /// @notice Emitted when the keeper-reward send fails (recipient rejects
    ///         ETH). The unwrapped ETH stays in the contract; the next call's
    ///         pre-wrap step folds it into the next burn cycle.
    event KeeperRewardFailed(address indexed caller, uint256 amount);

    // ─── keeper-reward constants ─────────────────────────────────────────

    /// @notice Keeper reward as a bps fraction of the WETH being burned.
    ///         0.5% — matches the PERMANENT COLLECTION adapters' shape so
    ///         keeper economics are consistent across the protocol family.
    uint256 public constant KEEPER_REWARD_BPS = 50;
    /// @notice Absolute fixed-wei cap on the keeper reward. Whichever bound
    ///         (bps or cap) binds first wins.
    uint256 public constant KEEPER_REWARD_CAP = 0.01 ether;

    // ─── slippage constants ──────────────────────────────────────────────

    /// @notice Maximum pool-price impact a single burn may cause, in bps,
    ///         enforced via the swap's `sqrtPriceLimitX96`. This is the sole
    ///         sandwich guard. It is set BELOW the LAYER pool's measured
    ///         round-trip fee moat, so a
    ///         single permissionless burn can't move the price far enough to
    ///         repay a sandwicher's buy/sell round trip: the sandwich is
    ///         uneconomic by construction. A burn larger than the cap fills
    ///         PARTIALLY (the unspent WETH stays for the next call), so a big
    ///         accumulation drains over several calls and a thin/launch pool is
    ///         never dumped on. Hardcoded (no admin knob) so a post-launch
    ///         config mistake can't make the burner sandwichable.
    ///
    ///         100 bps ≈ ~1% price via the sqrt-linear approximation
    ///         `(20000 ± bps) / 20000`. The LAYER pool's steady-state LP fee is
    ///         ~1% (the sniper-fee schedule decays to a 1% base), so a buy+sell
    ///         round trip costs a sandwicher ~2%; a ≤1% burner move sits safely
    ///         below that. Validated against the live pool by
    ///         `BurnRouterSandwichEconomics`; keep this below the moat that test
    ///         measures if the pool's fee tier ever changes.
    uint256 public constant MAX_SWAP_IMPACT_BPS = 100;
    /// @notice Output floor as a fraction of the spot-implied LAYER out for the
    ///         amount ACTUALLY consumed: a burn must yield at least
    ///         `FLOOR_BPS / 10_000` of what the pre-swap spot implies. 80%
    ///         absorbs the pool fee + the (clamped) price impact while rejecting
    ///         a near-empty swap. Hardcoded (no admin knob); mirrors
    ///         FeeAutoSwapper's `SPOT_FLOOR_BPS`. This floor is a post-swap
    ///         backstop against a degenerate fill, NOT the sandwich guard — the
    ///         price-impact clamp is what makes sandwiching uneconomic.
    uint256 public constant FLOOR_BPS = 8000;

    // ─── immutable-after-init state ──────────────────────────────────────

    address public layerToken;
    address public weth;
    PoolKey public canonicalPoolKey;
    bool public wethIsCurrency0;
    bool public initialized;
    /// @notice V4 PoolManager — reads `sqrtPriceX96` for the gate and executes
    ///         the swaps. Set at `initialize` time and never mutated.
    IPoolManager public poolManager;

    // ─── mutable admin state ─────────────────────────────────────────────

    uint256 public minProcessThreshold = 0.01 ether;
    uint256 public constant MIN_THRESHOLD_FLOOR = 1e15; // 0.001 ETH

    constructor(address owner_) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
    }

    // ─── initialization ──────────────────────────────────────────────────

    function initialize(
        address layerToken_,
        address weth_,
        PoolKey calldata canonicalPoolKey_,
        address poolManager_
    ) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        if (layerToken_ == address(0) || weth_ == address(0) || poolManager_ == address(0)) {
            revert ZeroAddress();
        }

        address c0 = Currency.unwrap(canonicalPoolKey_.currency0);
        address c1 = Currency.unwrap(canonicalPoolKey_.currency1);
        bool layerC0 = (c0 == layerToken_ && c1 == weth_);
        bool wethC0 = (c0 == weth_ && c1 == layerToken_);
        if (!layerC0 && !wethC0) revert InvalidPoolKey();

        layerToken = layerToken_;
        weth = weth_;
        canonicalPoolKey = canonicalPoolKey_;
        wethIsCurrency0 = wethC0;
        poolManager = IPoolManager(poolManager_);
        initialized = true;

        emit BurnRouterInitialized(layerToken_, weth_, canonicalPoolKey_);
    }

    // ─── admin setters ───────────────────────────────────────────────────

    function setMinThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold < MIN_THRESHOLD_FLOOR) revert MinThresholdTooLow();
        uint256 old = minProcessThreshold;
        minProcessThreshold = newThreshold;
        emit MinThresholdUpdated(old, newThreshold);
    }

    // ─── permissionless burn paths ───────────────────────────────────────

    /// @notice Burns all LAYER currently held by this contract. Permissionless.
    /// @dev    No keeper reward on this path — LAYER accumulates rarely and
    ///         rewarding in LAYER would undermine the deflationary intent.
    function processBurnLayer() external nonReentrant returns (uint256 burned) {
        if (!initialized) revert NotInitialized();
        burned = IERC20(layerToken).balanceOf(address(this));
        if (burned == 0) revert NothingToBurn();
        ERC20Burnable(layerToken).burn(burned);
        emit LayerBurnedDirectly(burned);
    }

    /// @notice Swaps the contract's WETH balance (minus keeper reward) for
    ///         LAYER via the contract's OWN `poolManager.unlock`, then burns the
    ///         LAYER. For standalone (top-level) keeper calls. Caller earns a
    ///         small ETH reward off the top.
    /// @dev    Wraps any native ETH on entry. The swap is impact-clamped, so a
    ///         large balance fills partially and the rest stays for the next
    ///         call. Reverts `InsufficientLayerOut` if output is below the
    ///         effective floor. Use `processBurnWethOpenTab` when the manager is
    ///         already unlocked (this path would revert with `ManagerLocked`).
    /// @param  minLayerOut Optional additional lower bound on LAYER out (only
    ///         tightens the spot-derived floor). Pass 0 to rely on the floor.
    /// @return wethIn WETH consumed by the swap (excludes keeper reward; below
    ///         the requested input on a partial fill).
    /// @return layerBurned LAYER bought and burned.
    function processBurnWeth(uint256 minLayerOut)
        external
        nonReentrant
        returns (uint256 wethIn, uint256 layerBurned)
    {
        if (!initialized) revert NotInitialized();

        uint160 preSqrtPriceX96 = _readSpot();
        uint256 reward;
        uint256 swapBudget;
        (swapBudget, reward) = _wrapAndSizeSwap();

        // Clamped swap via our own unlock (standalone keeper context).
        uint256 layerOut;
        bytes memory res = poolManager.unlock(abi.encode(swapBudget, preSqrtPriceX96));
        (wethIn, layerOut) = abi.decode(res, (uint256, uint256));

        layerBurned =
            _floorBurnAndReward(wethIn, layerOut, minLayerOut, preSqrtPriceX96, reward, false);
    }

    /// @notice Open-tab variant of `processBurnWeth`: swaps the WETH (minus
    ///         keeper reward) for LAYER via a DIRECT `poolManager.swap` on the
    ///         already-open V4 tab, then burns it. This is the path a per-swap
    ///         pool extension uses to drive the buy-and-burn with no keeper —
    ///         it works while the manager is unlocked (where the keeper path's
    ///         own `unlock` would revert under V4's no-nested-unlock rule).
    /// @dev    Reverts with `ManagerLocked` (from the PoolManager) if called
    ///         OUTSIDE an unlock, so it is safe to expose permissionlessly. The
    ///         contract settles its own swap deltas (`sync`/`settle`/`take`), so
    ///         the surrounding (outer) swap's settlement is unaffected. Same
    ///         clamp + floor as the keeper path. Uses the direct
    ///         `poolManager.swap` + `sync`/`settle`/`take` pattern for
    ///         swapping while the manager is already unlocked.
    /// @param  minLayerOut Optional additional lower bound on LAYER out (only
    ///         tightens the spot-derived floor). Pass 0 to rely on the floor.
    /// @return wethIn WETH consumed by the swap (excludes keeper reward; below
    ///         the requested input on a partial fill).
    /// @return layerBurned LAYER bought and burned.
    function processBurnWethOpenTab(uint256 minLayerOut)
        external
        nonReentrant
        returns (uint256 wethIn, uint256 layerBurned)
    {
        if (!initialized) revert NotInitialized();

        uint160 preSqrtPriceX96 = _readSpot();
        uint256 reward;
        uint256 swapBudget;
        (swapBudget, reward) = _wrapAndSizeSwap();

        // Clamped swap directly on the already-open tab.
        uint256 layerOut;
        (wethIn, layerOut) = _swapAndSettle(swapBudget, preSqrtPriceX96);

        layerBurned =
            _floorBurnAndReward(wethIn, layerOut, minLayerOut, preSqrtPriceX96, reward, true);
    }

    /// @notice V4 unlock callback for the standalone keeper path. Restricted to
    ///         the PoolManager. Performs the clamped swap + settle and returns
    ///         the consumed WETH + received LAYER.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (uint256 swapBudget, uint160 spotSqrtPriceX96) = abi.decode(data, (uint256, uint160));
        (uint256 wethConsumed, uint256 layerOut) = _swapAndSettle(swapBudget, spotSqrtPriceX96);
        return abi.encode(wethConsumed, layerOut);
    }

    // ─── shared internals ────────────────────────────────────────────────

    /// @dev Impact-clamped exact-in WETH→LAYER swap on the canonical pool, then
    ///      settle the consumed WETH and take the LAYER. MUST run inside an
    ///      unlock. The `sqrtPriceLimitX96` clamp bounds per-call price impact
    ///      to `MAX_SWAP_IMPACT_BPS`, so a large budget fills partially.
    function _swapAndSettle(uint256 swapBudget, uint160 spotSqrtPriceX96)
        internal
        returns (uint256 wethConsumed, uint256 layerOut)
    {
        bool zeroForOne = wethIsCurrency0;
        uint160 limit;
        if (zeroForOne) {
            // WETH = currency0 in, LAYER = currency1 out → price decreases.
            uint256 c = (uint256(spotSqrtPriceX96) * (20_000 - MAX_SWAP_IMPACT_BPS)) / 20_000;
            limit = c <= uint256(TickMath.MIN_SQRT_PRICE) ? TickMath.MIN_SQRT_PRICE + 1 : uint160(c);
        } else {
            // WETH = currency1 in, LAYER = currency0 out → price increases.
            uint256 c = (uint256(spotSqrtPriceX96) * (20_000 + MAX_SWAP_IMPACT_BPS)) / 20_000;
            limit = c >= uint256(TickMath.MAX_SQRT_PRICE) ? TickMath.MAX_SQRT_PRICE - 1 : uint160(c);
        }

        BalanceDelta delta = poolManager.swap(
            canonicalPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(swapBudget),
                sqrtPriceLimitX96: limit
            }),
            ""
        );

        // Derive the actually-consumed WETH (negative side, owed to the pool)
        // and the received LAYER (positive side) from the delta.
        if (zeroForOne) {
            wethConsumed = uint256(uint128(-delta.amount0()));
            layerOut = uint256(uint128(delta.amount1()));
        } else {
            wethConsumed = uint256(uint128(-delta.amount1()));
            layerOut = uint256(uint128(delta.amount0()));
        }

        poolManager.sync(Currency.wrap(weth));
        Currency.wrap(weth).transfer(address(poolManager), wethConsumed);
        poolManager.settle();
        poolManager.take(Currency.wrap(layerToken), address(this), layerOut);
    }

    /// @dev Post-swap: enforce the floor on the consumed amount, burn the
    ///      received LAYER, and pay the keeper reward. Shared by both burn paths
    ///      (`openTab` only selects the event).
    function _floorBurnAndReward(
        uint256 wethIn,
        uint256 layerOut,
        uint256 minLayerOut,
        uint160 preSqrtPriceX96,
        uint256 reward,
        bool openTab
    ) internal returns (uint256 layerBurned) {
        // Spot-derived floor on the amount ACTUALLY consumed (partial-fill
        // aware). The clamp keeps the realized rate well above FLOOR_BPS; this
        // is the post-swap backstop. The caller's `minLayerOut` only tightens.
        uint256 floor = _referenceFloor(wethIn, preSqrtPriceX96);
        uint256 effectiveMin = minLayerOut > floor ? minLayerOut : floor;
        if (layerOut < effectiveMin) revert InsufficientLayerOut(layerOut, effectiveMin);

        // Burn whatever we received (plus any prior LAYER dust).
        uint256 layerAfter = IERC20(layerToken).balanceOf(address(this));
        layerBurned = layerOut;
        ERC20Burnable(layerToken).burn(layerAfter);

        if (openTab) {
            emit WethProcessedForLayerBurnOpenTab(wethIn, layerOut);
        } else {
            emit WethProcessedForLayerBurn(wethIn, layerOut);
        }
        emit LayerPurchasedAndBurned(layerAfter);

        _payKeeperReward(reward);
    }

    /// @dev Captures the pre-swap pool spot, used both as the `sqrtPriceLimitX96`
    ///      anchor for the impact clamp and as the basis for the post-swap output
    ///      floor. `getSlot0` does not require the manager to be unlocked, so
    ///      this is safe on both burn paths.
    function _readSpot() internal view returns (uint160 preSqrtPriceX96) {
        // slither-disable-next-line unused-return
        (preSqrtPriceX96,,,) = poolManager.getSlot0(canonicalPoolKey.toId());
    }

    /// @dev Wraps any native ETH the contract holds, enforces the
    ///      `minProcessThreshold` floor on the resulting WETH balance, and
    ///      computes the keeper reward (bps + fixed-wei cap, with a
    ///      pathological-tiny-call guard). Returns the post-reward swap budget
    ///      and the reward.
    function _wrapAndSizeSwap() internal returns (uint256 swapAmount, uint256 reward) {
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) IWETH9(payable(weth)).deposit{value: ethBal}();

        uint256 totalWeth = IERC20(weth).balanceOf(address(this));
        if (totalWeth < minProcessThreshold) {
            revert BelowMinThreshold(totalWeth, minProcessThreshold);
        }

        reward = (totalWeth * KEEPER_REWARD_BPS) / 10_000;
        if (reward > KEEPER_REWARD_CAP) reward = KEEPER_REWARD_CAP;
        if (reward >= totalWeth) reward = 0;

        swapAmount = totalWeth - reward;
    }

    /// @dev LAYER-out floor for `wethAmount` at the given pre-swap spot price.
    ///      Two-step `mulDiv` avoids overflow at extreme prices. Returns 0 only
    ///      when no price exists (pool uninitialized) — the swap reverts anyway.
    function _referenceFloor(uint256 wethAmount, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256)
    {
        if (sqrtPriceX96 == 0 || wethAmount == 0) return 0;
        uint256 expectedLayerOut;
        if (wethIsCurrency0) {
            // WETH = currency0, LAYER = currency1: price (token1/token0) is
            // LAYER per WETH, so expected LAYER out = wethAmount * price.
            uint256 step1 = Math.mulDiv(wethAmount, sqrtPriceX96, 1 << 96);
            expectedLayerOut = Math.mulDiv(step1, sqrtPriceX96, 1 << 96);
        } else {
            // WETH = currency1, LAYER = currency0: price is WETH per LAYER, so
            // expected LAYER out = wethAmount / price.
            uint256 step1 = Math.mulDiv(wethAmount, 1 << 96, sqrtPriceX96);
            expectedLayerOut = Math.mulDiv(step1, 1 << 96, sqrtPriceX96);
        }
        return (expectedLayerOut * FLOOR_BPS) / 10_000;
    }

    /// @dev Pays the keeper reward in native ETH. A failed send is non-fatal:
    ///      the unwrapped ETH stays in the contract and folds into the next
    ///      burn cycle.
    function _payKeeperReward(uint256 reward) internal {
        if (reward > 0) {
            IWETH9(payable(weth)).withdraw(reward);
            (bool ok,) = msg.sender.call{value: reward}("");
            if (ok) {
                emit KeeperReward(msg.sender, reward);
            } else {
                emit KeeperRewardFailed(msg.sender, reward);
            }
        }
    }

    // ─── admin escape: sweep held non-LAYER, non-WETH tokens ─────────────

    function adminSweepHeldToken(address token, address recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (!initialized) revert NotInitialized();
        if (recipient == address(0)) revert ZeroAddress();
        if (token == layerToken || token == weth) revert BlockedToken(token);
        IERC20(token).safeTransfer(recipient, amount);
        emit HeldTokenSwept(token, recipient, amount);
    }

    function heldBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // ─── views ───────────────────────────────────────────────────────────

    /// @notice Minimum LAYER output the floor would require for the contract's
    ///         whole WETH balance, NET of the keeper reward. Note: a large
    ///         balance fills PARTIALLY, so the realized floor is lower; for
    ///         automated calls pass `minLayerOut = 0` and rely on the on-chain
    ///         (consumed-amount) floor.
    function requiredMinLayerOutForCurrentWethBalance() public view returns (uint256) {
        if (!initialized) return 0;
        return requiredMinLayerOutForWethAmount(IERC20(weth).balanceOf(address(this)));
    }

    /// @notice Spot-derived floor for a given WETH input, applied to the
    ///         post-keeper-reward amount.
    /// @param  wethAmount Raw WETH input amount (pre-reward).
    function requiredMinLayerOutForWethAmount(uint256 wethAmount) public view returns (uint256) {
        if (!initialized) return 0;
        uint256 reward = keeperRewardForWethAmount(wethAmount);
        // slither-disable-next-line unused-return
        (uint160 spot,,,) = poolManager.getSlot0(canonicalPoolKey.toId());
        return _referenceFloor(wethAmount - reward, spot);
    }

    /// @notice Keeper reward that would be paid for processing a given WETH
    ///         input. Useful for off-chain keepers to size their gas budget.
    function keeperRewardForWethAmount(uint256 wethAmount) public pure returns (uint256) {
        uint256 reward = (wethAmount * KEEPER_REWARD_BPS) / 10_000;
        if (reward > KEEPER_REWARD_CAP) reward = KEEPER_REWARD_CAP;
        if (reward >= wethAmount) reward = 0;
        return reward;
    }

    function status()
        external
        view
        returns (uint256 layer, uint256 wethBalance, bool readyForWethBurn)
    {
        if (!initialized) return (0, 0, false);
        layer = IERC20(layerToken).balanceOf(address(this));
        wethBalance = IERC20(weth).balanceOf(address(this));
        readyForWethBurn = wethBalance >= minProcessThreshold;
    }

    // ─── ETH receive ─────────────────────────────────────────────────────

    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }
}
