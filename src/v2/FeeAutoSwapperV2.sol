// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../Constants.sol";
import {IArtCoinsFeeEscrowV2} from "./interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "./interfaces/IArtCoinsHookV2.sol";
import {IConstantsBound} from "./interfaces/IConstantsBound.sol";
import {IFeeAutoSwapperV2} from "./interfaces/IFeeAutoSwapperV2.sol";
import {FeeDelivery} from "./libraries/FeeDelivery.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  FeeAutoSwapperV2
/// @notice Sits in a frozen locker reward slot for one native eth paired art
///         coin. `convert` swaps the coin side fees to eth on the coin's own
///         pool; `flushPaired` forwards the eth side. Both forward the WHOLE
///         eth balance to the frozen `endRecipient` (push, escrow fallback).
/// @dev    Properties:
///         - payouts are balance based, never ledger based, so eth that a
///           third party pushed in (escrow claim, direct send, selfdestruct)
///           always leaves on the next call. invariant: eth balance is 0 after
///           every `convert` and `flushPaired`.
///         - the constructor opts into escrow `selfClaimOnly`.
///         - recipient payout goes through `FeeDelivery` (push, escrow on
///           failure); a failed keeper reward goes to the recipient instead of
///           reverting. neither can brick flush or convert as long as this
///           contract is an escrow depositor.
///         - owner (Ownable2Step) tunes slippage, pacing and step size within
///           `Constants` bounds and can rescue unrelated tokens only.
///         Pool topology (escrow, hook, fee, tick spacing, end recipient) is
///         immutable; the coin is bound once by the deployer (`setup`) or at
///         construction.
contract FeeAutoSwapperV2 is
    IFeeAutoSwapperV2,
    IConstantsBound,
    IUnlockCallback,
    Ownable2Step,
    ReentrancyGuardTransient
{
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice Gas forwarded on the push to `endRecipient`. Generous because a
    ///         recipient may do work on receipt; failure falls back to the escrow.
    uint256 public constant END_RECIPIENT_GAS = 500_000;
    /// @notice Gas forwarded on the keeper reward push. Failure sends the
    ///         reward to `endRecipient` instead.
    uint256 public constant KEEPER_GAS = 50_000;
    /// @notice Max per call input (v4 swap amounts are int128 sized).
    uint256 public constant MAX_STEP_IN_CEILING = uint256(uint128(type(int128).max));

    /// @notice `unlockCallback` caller is not the PoolManager.
    error NotPoolManager();

    /// @notice a second `convert` in the same block.
    error AlreadyConvertedThisBlock();

    /// @notice owner moved the output floor (bps of the spot implied output).
    event SpotFloorBpsSet(uint256 oldBps, uint256 newBps);
    /// @notice the pool's known fees were (re)read from the hook.
    event PoolFeesSynced(
        PoolId indexed poolId, address indexed coin, uint256 baselineSkimBps, uint256 lpFeePips
    );
    /// @notice owner moved the per convert price impact cap.
    event MaxImpactBpsSet(uint256 oldBps, uint256 newBps);

    /// @notice Initial convert output floor, 95% of the fee net spot output.
    uint256 public constant CONVERT_SPOT_FLOOR_DEFAULT_BPS = 9500;

    /// @notice Constructor parameter bundle.
    /// @dev `coin` may be zero; the deployer then binds it via `setup`.
    struct Config {
        address owner;
        address poolManager;
        address feeEscrow;
        address hook;
        uint24 poolFee;
        int24 tickSpacing;
        address endRecipient;
        address coin;
        uint256 maxSlippageBps;
        uint256 minBlocksBetweenConverts;
        uint256 maxStepIn;
    }

    // ── immutable topology ────────────────────────────────────────────────

    IPoolManager public immutable poolManager;
    /// @inheritdoc IFeeAutoSwapperV2
    address public immutable feeEscrow;
    /// @inheritdoc IFeeAutoSwapperV2
    address public immutable endRecipient;
    address public immutable hook;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    address internal immutable _deployer;

    // ── state ─────────────────────────────────────────────────────────────

    /// @inheritdoc IFeeAutoSwapperV2
    address public coin;
    bool internal _finalized;

    /// @inheritdoc IFeeAutoSwapperV2
    uint256 public maxSlippageBps;
    /// @inheritdoc IFeeAutoSwapperV2
    uint256 public minBlocksBetweenConverts;
    /// @inheritdoc IFeeAutoSwapperV2
    uint256 public maxStepIn;
    /// @notice Block of the last successful `convert`.
    uint256 public lastConvertBlock;
    /// @notice Output floor in bps of the spot implied output, owner
    ///         tunable within [SPOT_FLOOR_MIN_BPS, SPOT_FLOOR_MAX_BPS].
    uint256 public spotFloorBps;
    /// @notice price impact cap per convert in bps, owner tunable within
    ///         [PRICE_IMPACT_MIN, PRICE_IMPACT_MAX]. The swap's price limit is
    ///         the tighter of this and `maxSlippageBps`.
    uint256 public maxImpactBps;
    /// @notice pool baseline skim (BPS of volume) the floor nets out.
    uint24 public poolBaselineSkimBps;
    /// @notice pool lp fee (FEE_DENOMINATOR units) the floor nets out.
    uint24 public poolLpFee;

    constructor(Config memory c) Ownable(c.owner) {
        if (c.poolManager == address(0)) revert ZeroAddress();
        if (c.feeEscrow == address(0)) revert ZeroAddress();
        if (c.endRecipient == address(0)) revert ZeroAddress();
        if (c.endRecipient == address(this) || c.endRecipient == c.feeEscrow) {
            revert InvalidEndRecipient();
        }
        _checkSlippage(c.maxSlippageBps);
        _checkMinBlocks(c.minBlocksBetweenConverts);
        _checkStep(c.maxStepIn);

        poolManager = IPoolManager(c.poolManager);
        feeEscrow = c.feeEscrow;
        endRecipient = c.endRecipient;
        hook = c.hook;
        poolFee = c.poolFee;
        tickSpacing = c.tickSpacing;
        _deployer = msg.sender;

        maxSlippageBps = c.maxSlippageBps;
        minBlocksBetweenConverts = c.minBlocksBetweenConverts;
        maxStepIn = c.maxStepIn;
        spotFloorBps = CONVERT_SPOT_FLOOR_DEFAULT_BPS;
        maxImpactBps = Constants.PRICE_IMPACT_DEFAULT;
        emit MaxSlippageBpsSet(0, c.maxSlippageBps);
        emit MinBlocksBetweenConvertsSet(0, c.minBlocksBetweenConverts);
        emit MaxStepInSet(0, c.maxStepIn);
        emit SpotFloorBpsSet(0, CONVERT_SPOT_FLOOR_DEFAULT_BPS);
        emit MaxImpactBpsSet(0, Constants.PRICE_IMPACT_DEFAULT);

        // b5: a third party can no longer push escrowed fees into this contract.
        IArtCoinsFeeEscrowV2(c.feeEscrow).setSelfClaimOnly(true);

        if (c.coin != address(0)) _bind(c.coin);
    }

    /// @notice Accepts eth from `poolManager.take`, escrow claims, the locker
    ///         push and anyone else. Everything held leaves on the next call.
    receive() external payable {}

    // ── setup ─────────────────────────────────────────────────────────────

    /// @inheritdoc IFeeAutoSwapperV2
    function setup(address coin_) external {
        if (msg.sender != _deployer) revert NotDeployer();
        if (_finalized) revert AlreadyFinalized();
        _bind(coin_);
    }

    /// @inheritdoc IFeeAutoSwapperV2
    function setupFinalized() external view returns (bool) {
        return _finalized;
    }

    function _bind(address coin_) internal {
        if (coin_ == address(0)) revert ZeroAddress();
        coin = coin_;
        _finalized = true;
        emit CoinBound(coin_);
        _syncFees(_key(coin_));
    }

    /// @notice anyone re reads the pool's known fees from the hook.
    ///         It can only set what the hook reports, so it is not gated.
    function syncPoolFees() external {
        if (!_finalized) revert NotFinalized();
        _syncFees(_key(coin));
    }

    // ── permissionless ────────────────────────────────────────────────────

    /// @inheritdoc IFeeAutoSwapperV2
    /// @dev Guards, all against the pre swap spot: the swap's price limit caps
    ///      the move at min(`maxImpactBps`, `maxSlippageBps`) (a binding limit
    ///      partial fills, the rest waits); the output must clear both the
    ///      caller's `minOut` and `spotFloorBps` of the spot implied output
    ///      for the input actually consumed; at most `maxStepIn` per call; one
    ///      convert per block, then `minBlocksBetweenConverts` pacing.
    ///      A caller can still move the spot before calling in the same tx
    ///     ; the impact cap bounds how much coin the swapper sells
    ///      into that moved price, so the sandwich gain per call is about the
    ///      cap times the consumed value, against the attacker's round trip
    ///      fees. Not prevented: keepers should pass an off chain `minOut`.
    function convert(uint256 minOut) external nonReentrant returns (uint256 pairedOut) {
        if (!_finalized) revert NotFinalized();
        if (lastConvertBlock == block.number) revert AlreadyConvertedThisBlock();
        uint256 next = lastConvertBlock + minBlocksBetweenConverts;
        if (lastConvertBlock != 0 && block.number < next) revert ConvertTooEarly(next);

        _claimEscrowed(coin);
        uint256 available = SafeTransferLib.balanceOf(coin, address(this));
        if (available == 0) revert NothingToConvert();
        uint256 amountIn = available > maxStepIn ? maxStepIn : available;

        (uint160 preSqrtPriceX96,,,) = poolManager.getSlot0(_key(coin).toId());
        lastConvertBlock = block.number;

        (uint256 received, uint256 actualIn) = abi.decode(
            poolManager.unlock(abi.encode(amountIn, preSqrtPriceX96)), (uint256, uint256)
        );
        if (actualIn > amountIn) revert ExcessInputSpent(actualIn, amountIn);
        if (received < minOut) revert InsufficientOutput(received, minOut);
        uint256 floor = _spotFloor(actualIn, preSqrtPriceX96);
        if (received < floor) revert MinOutBelowFloor(received, floor);

        // the hook refunds over charged skim on a price limited fill to the
        // swap sender (this contract) via the escrow; forward it now too.
        _claimEscrowed(address(0));
        (uint256 toRecipient, uint256 toKeeper) = _forwardAll(_reward(received));
        emit Converted(msg.sender, actualIn, received, toRecipient, toKeeper);
        return received;
    }

    /// @inheritdoc IFeeAutoSwapperV2
    /// @dev Works before `setup` too: the eth side needs no coin.
    function flushPaired() external nonReentrant returns (uint256 pairedOut) {
        _claimEscrowed(address(0));
        pairedOut = address(this).balance;
        if (pairedOut == 0) revert NothingToFlush();
        (uint256 toRecipient, uint256 toKeeper) = _forwardAll(_reward(pairedOut));
        emit Flushed(msg.sender, pairedOut, toRecipient, toKeeper);
    }

    /// @notice v4 unlock callback: exact input coin to eth swap with a price
    ///         limit, settle the coin actually consumed, take the eth.
    /// @dev    The coin is settled to the PoolManager AFTER the swap, so on a
    ///         restricted coin the hook's per swap transfer allowance is granted
    ///         first and the settle consumes it.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 amountIn, uint160 spot) = abi.decode(data, (uint256, uint160));

        // coin is currency1 (native eth sorts first), selling it raises the
        // price. limit = spot * sqrt(1 + bps / BPS), rounded down, so the
        // realized price move never exceeds bps = min(impact, slippage).
        uint256 bps = maxImpactBps < maxSlippageBps ? maxImpactBps : maxSlippageBps;
        uint256 factor = FixedPointMathLib.sqrt((Constants.BPS + bps) * 1e36 / Constants.BPS);
        uint256 c = FullMath.mulDiv(uint256(spot), factor, 1e18);
        uint160 limit =
            c >= uint256(TickMath.MAX_SQRT_PRICE) ? TickMath.MAX_SQRT_PRICE - 1 : uint160(c);

        BalanceDelta delta = poolManager.swap(
            _key(coin),
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit
            }),
            ""
        );
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        if (d1 > 0 || d0 < 0) revert BadDelta();
        uint256 actualIn = uint256(uint128(-d1));
        uint256 received = uint256(uint128(d0));
        if (actualIn > amountIn) revert ExcessInputSpent(actualIn, amountIn);

        if (actualIn > 0) {
            poolManager.sync(Currency.wrap(coin));
            SafeTransferLib.safeTransfer(coin, address(poolManager), actualIn);
            poolManager.settle();
        }
        if (received > 0) poolManager.take(Currency.wrap(address(0)), address(this), received);
        return abi.encode(received, actualIn);
    }

    // ── reads ─────────────────────────────────────────────────────────────

    /// @inheritdoc IFeeAutoSwapperV2
    function poolKey() external view returns (PoolKey memory) {
        return _key(coin);
    }

    /// @inheritdoc IFeeAutoSwapperV2
    function nextConvertibleBlock() external view returns (uint256) {
        return lastConvertBlock == 0 ? block.number : lastConvertBlock + minBlocksBetweenConverts;
    }

    /// @inheritdoc IFeeAutoSwapperV2
    function accruedCoin() external view returns (uint256) {
        if (coin == address(0)) return 0;
        return SafeTransferLib.balanceOf(coin, address(this))
            + IArtCoinsFeeEscrowV2(feeEscrow).balances(address(this), coin);
    }

    /// @inheritdoc IFeeAutoSwapperV2
    function accruedPaired() external view returns (uint256) {
        return
            address(this).balance
                + IArtCoinsFeeEscrowV2(feeEscrow).balances(address(this), address(0));
    }

    /// @notice The output floor `convert` enforces for `artIn` consumed at the
    ///         current spot. Same code path as the enforced check.
    function floorFor(uint256 artIn) external view returns (uint256) {
        if (coin == address(0)) return 0;
        (uint160 spot,,,) = poolManager.getSlot0(_key(coin).toId());
        return _spotFloor(artIn, spot);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IFeeAutoSwapperV2).interfaceId
            || interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IConstantsBound).interfaceId;
    }

    /// @inheritdoc IFeeAutoSwapperV2
    uint16 public constant STACK_VERSION = Constants.STACK_VERSION;

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    // ── owner ─────────────────────────────────────────────────────────────

    /// @inheritdoc IFeeAutoSwapperV2
    function setMaxSlippageBps(uint256 bps) external onlyOwner {
        _checkSlippage(bps);
        emit MaxSlippageBpsSet(maxSlippageBps, bps);
        maxSlippageBps = bps;
    }

    /// @inheritdoc IFeeAutoSwapperV2
    function setMinBlocksBetweenConverts(uint256 blocks) external onlyOwner {
        _checkMinBlocks(blocks);
        emit MinBlocksBetweenConvertsSet(minBlocksBetweenConverts, blocks);
        minBlocksBetweenConverts = blocks;
    }

    /// @inheritdoc IFeeAutoSwapperV2
    function setMaxStepIn(uint256 maxIn) external onlyOwner {
        _checkStep(maxIn);
        emit MaxStepInSet(maxStepIn, maxIn);
        maxStepIn = maxIn;
    }

    /// @notice sets the per convert price impact cap within the burn
    ///         impact bounds.
    function setMaxImpactBps(uint256 bps) external onlyOwner {
        if (bps < Constants.PRICE_IMPACT_MIN || bps > Constants.PRICE_IMPACT_MAX) {
            revert OutOfBounds(bps, Constants.PRICE_IMPACT_MIN, Constants.PRICE_IMPACT_MAX);
        }
        emit MaxImpactBpsSet(maxImpactBps, bps);
        maxImpactBps = bps;
    }

    /// @notice sets the output floor within Constants bounds.
    function setSpotFloorBps(uint256 bps) external onlyOwner {
        if (bps < Constants.SPOT_FLOOR_MIN_BPS || bps > Constants.SPOT_FLOOR_MAX_BPS) {
            revert OutOfBounds(bps, Constants.SPOT_FLOOR_MIN_BPS, Constants.SPOT_FLOOR_MAX_BPS);
        }
        emit SpotFloorBpsSet(spotFloorBps, bps);
        spotFloorBps = bps;
    }

    /// @inheritdoc IFeeAutoSwapperV2
    /// @dev Native eth (the paired currency) and the art coin are owed to
    ///      `endRecipient` and can never be rescued. Before `setup` nothing can
    ///      be rescued (the coin is not yet known).
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (!_finalized) revert NotFinalized();
        if (token == address(0) || token == coin) revert CannotRescue(token);
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Rescued(token, to, amount);
    }

    // ── internals ─────────────────────────────────────────────────────────

    /// @dev Pulls this contract's escrow credit for `token`, if any. A failing
    ///      escrow never blocks forwarding what is already held.
    function _claimEscrowed(address token) internal {
        IArtCoinsFeeEscrowV2 escrow = IArtCoinsFeeEscrowV2(feeEscrow);
        if (escrow.balances(address(this), token) > 0) {
            try escrow.claim(address(this), token) {} catch {}
        }
    }

    /// @dev Pays `reward` to the caller (gas capped, no returndata), then pushes
    ///      the whole remaining eth balance to `endRecipient` with escrow
    ///      fallback. A failed keeper push leaves the reward in the balance, so
    ///      it goes to the recipient.
    function _forwardAll(uint256 reward) internal returns (uint256 toRecipient, uint256 toKeeper) {
        if (reward > 0) {
            address keeper = msg.sender;
            uint256 gasCap = KEEPER_GAS;
            bool ok;
            assembly ("memory-safe") {
                ok := call(gasCap, keeper, reward, codesize(), 0x00, codesize(), 0x00)
            }
            if (ok) toKeeper = reward;
        }
        toRecipient = address(this).balance;
        FeeDelivery.sendNative(feeEscrow, endRecipient, toRecipient, END_RECIPIENT_GAS);
    }

    function _reward(uint256 amount) internal pure returns (uint256 reward) {
        reward = (amount * Constants.KEEPER_REWARD_BPS) / Constants.BPS;
        if (reward > Constants.KEEPER_REWARD_CAP) reward = Constants.KEEPER_REWARD_CAP;
    }

    function _key(address coin) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
    }

    /// @dev Expected eth for `artIn` coin (currency1) at spot, times
    ///      (1 - baseline skim - lp fee) times `spotFloorBps`.
    ///      price = token1 per token0, so eth = artIn / price.
    ///      Two mulDivs avoid overflow at extreme prices.
    function _spotFloor(uint256 artIn, uint160 sqrtPriceX96) internal view returns (uint256) {
        if (artIn == 0 || sqrtPriceX96 == 0) return 0;
        uint256 step = FullMath.mulDiv(artIn, 1 << 96, sqrtPriceX96);
        uint256 expected = FullMath.mulDiv(step, 1 << 96, sqrtPriceX96);
        return FullMath.mulDiv(
            expected, _netPpm() * spotFloorBps, Constants.FEE_DENOMINATOR * Constants.BPS
        );
    }

    /// @dev the pool's known fees, read from `hook.skimConfig(poolId)`
    ///      (zero for a hookless pool or a hook that does not answer), clamped
    ///      to the Constants caps. `baselineSkimBps` in BPS of volume,
    ///      `lpFeePips` in FEE_DENOMINATOR units.
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

    /// @dev 1 - baseline skim - lp fee, in FEE_DENOMINATOR units (>= 80% by the caps).
    function _netPpm() internal view returns (uint256) {
        uint256 skimPpm = uint256(poolBaselineSkimBps) * (Constants.FEE_DENOMINATOR / Constants.BPS);
        return Constants.FEE_DENOMINATOR - skimPpm - poolLpFee;
    }

    function _checkSlippage(uint256 bps) internal pure {
        if (bps < Constants.SWAPPER_SLIPPAGE_MIN || bps > Constants.SWAPPER_SLIPPAGE_MAX) {
            revert OutOfBounds(bps, Constants.SWAPPER_SLIPPAGE_MIN, Constants.SWAPPER_SLIPPAGE_MAX);
        }
    }

    function _checkMinBlocks(uint256 blocks) internal pure {
        if (blocks < Constants.SWAPPER_MIN_BLOCKS_MIN || blocks > Constants.SWAPPER_MIN_BLOCKS_MAX)
        {
            revert OutOfBounds(
                blocks, Constants.SWAPPER_MIN_BLOCKS_MIN, Constants.SWAPPER_MIN_BLOCKS_MAX
            );
        }
    }

    function _checkStep(uint256 maxIn) internal pure {
        if (maxIn == 0 || maxIn > MAX_STEP_IN_CEILING) {
            revert OutOfBounds(maxIn, 1, MAX_STEP_IN_CEILING);
        }
    }
}
