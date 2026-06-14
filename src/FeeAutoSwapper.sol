// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFeeEscrow} from "./interfaces/IArtCoinsFeeEscrow.sol";
import {IArtCoinsFeeLocker} from "./interfaces/IArtCoinsFeeLocker.sol";
import {IFeeAutoSwapper} from "./interfaces/IFeeAutoSwapper.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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

/// @title  FeeAutoSwapper
/// @notice Mirror-image of PERMANENT COLLECTION's `BuybackBurner`: converts
///         accrued *artcoin-side* fees back to the pool's paired currency
///         (WETH or native ETH) on the same V4 pool that produced them.
///         Solves the long-tail problem where the artcoins locker's reward
///         split delivers per-direction LP fees (paired-in → paired, artcoin-in
///         → artcoin) to recipients that wanted the paired currency — and
///         end up holding stuck artcoin instead.
///
///         Supports both pool pairings:
///           - **WETH-paired** (e.g. live LAYER): `pairedToken = WETH`.
///             Swap output is WETH. Re-deposit via `feeLocker.storeFees`.
///           - **Native-ETH-paired** (e.g. PERMANENT COLLECTION's $111):
///             `pairedToken = address(0)`. Swap output is native ETH (V4's
///             currency-0 sentinel). Re-deposit via
///             `feeEscrow.storeFeesNative{value:}`.
///
///         Works against both `ArtCoinsFeeLocker` and `ArtCoinsFeeEscrow`
///         since the escrow extends the locker's
///         `storeFees` / `claim` / `availableFees` triple. Pool topology is
///         immutable. There is no owner surface — every parameter is set
///         once at construction; the only runtime "tuning" is the
///         spot-derived `minOut` floor, which adapts automatically.
///
///         Designed for both retrofit (deploy against an existing pool whose
///         hook is already shipped — e.g. the live LAYER pool — and have an
///         existing reward slot point at this contract) and forward use
///         (new pools register this as a reward recipient at launch).
///
///         **Token assumptions.** The bound `artCoin` must be a standard
///         ERC20: no fee-on-transfer, no rebasing, no blocklist that could
///         reject the swapper or the V4 PoolManager. The conservation
///         invariant (every claimed artcoin is either converted, residual,
///         or still owed at the locker) assumes 1:1 transfer accounting.
///         Tokens deployed by the artcoins factory satisfy this; verify
///         before binding via `setup` for any other token.
contract FeeAutoSwapper is IFeeAutoSwapper, IUnlockCallback, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // ─── bounds on tunables ─────────────────────────────────────────────

    /// @notice Lower bound on `minBlocksBetweenConverts`.
    uint256 public constant MIN_BLOCKS_LO = 1;
    /// @notice Upper bound (~1 week at 12s blocks).
    uint256 public constant MIN_BLOCKS_HI = 50_400;
    /// @notice Lower bound on `maxSlippageBps` (0.5%).
    uint256 public constant MAX_SLIPPAGE_BPS_LO = 50;
    /// @notice Upper bound on `maxSlippageBps` (10%). `maxSlippageBps` is the
    ///         sole sandwich guard. It caps per-call price movement via
    ///         `sqrtPriceLimitX96` so a permissionless `convert` step cannot
    ///         move the pool far enough to repay a sandwicher's round-trip LP
    ///         fee. The deployer MUST set it below the pool's measured
    ///         round-trip fee moat; this ceiling only stops a deploy from
    ///         shipping an obviously sandwichable value. A binding cap
    ///         partial-fills (V4 leaves the unspent artcoin queued for the
    ///         next call) rather than reverting.
    uint256 public constant MAX_SLIPPAGE_BPS_HI = 1000;

    /// @notice Keeper reward as bps of swap output. Caps at `KEEPER_REWARD_CAP_WEI`.
    uint256 public constant KEEPER_REWARD_BPS = 50; // 0.5%
    /// @notice Absolute cap on keeper reward per `convert` call.
    uint256 public constant KEEPER_REWARD_CAP_WEI = 0.01 ether;

    /// @notice Floor on the post-swap rate, expressed as bps of the
    ///         spot-derived expected output read **at the time of the call**.
    ///         Hardcoded so the contract has no admin dependency: the floor
    ///         adapts to the pool's current price every call. 80% (8000 bps)
    ///         is loose enough that legitimate keepers always clear it
    ///         (typical actual swap output ≈ 94% of spot after the pool fee
    ///         and price impact), tight enough that a `minOut = 0` grief on
    ///         an unmanipulated pool is rejected outright.
    ///
    ///         Important: this floor does NOT protect against same-tx spot
    ///         manipulation. A caller who first moves the pool before
    ///         calling `convert` will have the floor computed against the
    ///         manipulated spot, not a fair pre-manipulation rate. See the
    ///         `convert` NatSpec for the full discussion.
    uint256 public constant SPOT_FLOOR_BPS = 8000;

    // ─── immutable topology ─────────────────────────────────────────────

    /// @notice V4 singleton.
    IPoolManager public immutable poolManager;
    /// @notice The fee locker / escrow that holds accrued artcoin per recipient.
    ///         Both `ArtCoinsFeeLocker` and `ArtCoinsFeeEscrow` expose the ABI
    ///         used here.
    IArtCoinsFeeLocker public immutable feeLocker;
    /// @notice The artcoin to convert. Set once via `setup(token)` after
    ///         the artcoins factory deploys the token; stays at zero until
    ///         then, which is why `convert` / `flushPaired` revert with
    ///         `NotFinalized` pre-setup. Effectively immutable once bound
    ///         — the only writer is `setup`, which can run exactly once.
    IERC20 public artCoin;

    /// @dev Captured at construction. Only `_deployer` can call `setup`.
    address internal immutable _deployer;
    /// @dev True after `setup` has run. Latches forever.
    bool internal _finalized;
    /// @notice The pool's paired-side token. `address(0)` for a native-ETH
    ///         pool; otherwise the WETH contract.
    address public immutable pairedToken;
    /// @notice `true` if the pool is native-ETH-paired (`pairedToken == address(0)`).
    ///         Cached at construction so hot-path branches don't re-check.
    bool public immutable pairedIsNative;
    /// @notice V4 pool fee (typically the dynamic-fee sentinel for artcoins pools).
    uint24 public immutable poolFee;
    /// @notice V4 pool tick spacing.
    int24 public immutable poolTickSpacing;
    /// @notice The pool's hook. Stored as `IHooks` so `PoolKey` reconstruction
    ///         doesn't re-cast each call.
    IHooks public immutable hook;

    /// @notice Where the converted WETH goes. Immutable — the recipient's
    ///         escape valve is to redirect their reward slot at the LP locker
    ///         away from this swapper.
    address public immutable endRecipient;
    /// @notice Mode flag. `true` re-deposits net WETH into the fee locker
    ///         keyed to `endRecipient` (requires the swapper to be an
    ///         allowlisted depositor at the fee locker). `false` transfers
    ///         WETH directly to `endRecipient`'s ERC20 balance.
    bool public immutable depositToLocker;

    // ─── deploy-time parameters (immutable, no setters) ─────────────────
    //
    // All three are picked once at construction. No admin path can change
    // them afterwards. `maxSlippageBps` is the sole sandwich guard: set it
    // BELOW the pool's measured round-trip fee moat (typically a few hundred
    // bps) so a permissionless `convert` cannot move the pool enough to repay
    // a sandwich round trip.
    // A binding cap partial-fills rather than reverting, so a conservative
    // value just means more steps, never stuck funds. Size `maxStepIn` and
    // `minBlocksBetweenConverts` to taste. The `minOut` floor is not a
    // parameter — it's derived from on-chain spot at call time via
    // `SPOT_FLOOR_BPS`.

    /// @notice Maximum bps of pool-price movement allowed per `convert`.
    ///         Enforced via `sqrtPriceLimitX96` on the V4 swap.
    uint256 public immutable maxSlippageBps;
    /// @notice Minimum block delta between successive `convert` calls.
    uint256 public immutable minBlocksBetweenConverts;
    /// @notice Per-call cap on artcoin spent. The deployer picks a value
    ///         appropriate to the token's decimals; the only hard cap is
    ///         `type(int128).max` because the value is passed as the
    ///         `amountSpecified` of a V4 swap (`int256`, but downstream V4
    ///         arithmetic uses `int128`-sized deltas — a value above the
    ///         int128 ceiling bricks every swap with arithmetic overflow).
    uint256 public immutable maxStepIn;

    // ─── state ──────────────────────────────────────────────────────────

    /// @notice `block.number` of the most recent `convert`.
    uint256 public lastConvertBlock;
    /// @notice Monotonic — total artcoin ever spent on swaps.
    uint256 public totalArtcoinConverted;
    /// @notice Monotonic — total WETH ever delivered to `endRecipient`.
    uint256 public totalWethDelivered;
    /// @notice Monotonic — total WETH ever paid to keepers.
    uint256 public totalKeeperRewards;

    // ─── construction ───────────────────────────────────────────────────

    /// @notice Constructor parameter bundle. Grouped to dodge stack-too-deep.
    /// @dev `pairedToken == address(0)` selects native-ETH-paired mode;
    ///      otherwise the address is treated as the paired ERC20
    ///      (canonical WETH on mainnet for WETH-paired pools). `artCoin`
    ///      is bound post-construction via `setup` so the swapper can be
    ///      handed to the artcoins factory as a reward recipient *before*
    ///      the factory deploys the token in the same transaction.
    struct Config {
        address poolManager;
        address feeLocker;
        address pairedToken;
        uint24 poolFee;
        int24 poolTickSpacing;
        address hook;
        address endRecipient;
        bool depositToLocker;
        uint256 maxSlippageBps;
        uint256 minBlocksBetweenConverts;
        uint256 maxStepIn;
    }

    constructor(Config memory c) {
        if (c.poolManager == address(0)) revert ZeroAddress("poolManager");
        if (c.feeLocker == address(0)) revert ZeroAddress("feeLocker");
        if (c.endRecipient == address(0)) revert ZeroAddress("endRecipient");
        if (c.maxStepIn == 0 || c.maxStepIn > uint256(uint128(type(int128).max))) {
            revert OutOfBounds(c.maxStepIn, 1, uint256(uint128(type(int128).max)));
        }
        if (c.maxSlippageBps < MAX_SLIPPAGE_BPS_LO || c.maxSlippageBps > MAX_SLIPPAGE_BPS_HI) {
            revert OutOfBounds(c.maxSlippageBps, MAX_SLIPPAGE_BPS_LO, MAX_SLIPPAGE_BPS_HI);
        }
        if (
            c.minBlocksBetweenConverts < MIN_BLOCKS_LO || c.minBlocksBetweenConverts > MIN_BLOCKS_HI
        ) {
            revert OutOfBounds(c.minBlocksBetweenConverts, MIN_BLOCKS_LO, MIN_BLOCKS_HI);
        }
        _deployer = msg.sender;

        poolManager = IPoolManager(c.poolManager);
        feeLocker = IArtCoinsFeeLocker(c.feeLocker);
        pairedToken = c.pairedToken;
        pairedIsNative = (c.pairedToken == address(0));
        poolFee = c.poolFee;
        poolTickSpacing = c.poolTickSpacing;
        hook = IHooks(c.hook);
        endRecipient = c.endRecipient;
        depositToLocker = c.depositToLocker;
        maxSlippageBps = c.maxSlippageBps;
        minBlocksBetweenConverts = c.minBlocksBetweenConverts;
        maxStepIn = c.maxStepIn;

        // `endRecipient == address(this)` would mean the swap output loops
        // back into its own input ledger — pointless but the constructor
        // address check would still admit it because `address(this)` is
        // resolvable at construct time but doesn't equal the deployer.
        if (c.endRecipient == address(this)) revert InvalidEndRecipient();
    }

    /// @inheritdoc IFeeAutoSwapper
    /// @dev See `Config` doc for why this is post-construction. Validates
    ///      the bound token (non-zero, distinct from `pairedToken`) and
    ///      latches `_finalized` so the call can't run again.
    function setup(address artCoin_) external {
        if (msg.sender != _deployer) revert NotDeployer();
        if (_finalized) revert AlreadyFinalized();
        if (artCoin_ == address(0)) revert ZeroAddress("artCoin");
        if (artCoin_ == pairedToken) revert InvalidWeth();

        artCoin = IERC20(artCoin_);
        _finalized = true;
    }

    /// @inheritdoc IFeeAutoSwapper
    function setupFinalized() external view returns (bool) {
        return _finalized;
    }

    /// @notice Accept native ETH from `poolManager.take` (native-ETH-paired
    ///         pools).
    ///
    ///         Native ETH sent here by any other path (direct `call{value:}`,
    ///         `selfdestruct`, miner-rewards if this were a builder) will
    ///         **strand**. Payouts in `convert` and `flushPaired` are sized
    ///         from the swap's `received` and the locker's `pairedOut`
    ///         respectively, not from `address(this).balance`. There is no
    ///         sweep path. This is a deliberate trade-off: keeping the
    ///         contract admin-free means no rescue function. Donors should
    ///         expect their ETH to remain stuck.
    ///
    ///         On WETH-paired deployments, direct native ETH donations
    ///         can still be received here (this `receive()` is
    ///         unconditional), and will strand for the same reason — only
    ///         paired-currency accounting on a WETH-paired pool uses
    ///         WETH ERC20 transfers, not native ETH.
    receive() external payable {}

    // ─── core ───────────────────────────────────────────────────────────

    /// @inheritdoc IFeeAutoSwapper
    /// @dev Slippage protection is dual-layered, with an important caveat:
    ///      both layers reference the **pool spot at the moment of the call**.
    ///      Neither layer protects against an attacker who manipulates the
    ///      spot before calling (e.g., a sandwich pattern: front-run the
    ///      pool to depress the artcoin/paired rate, call `convert`, back-run
    ///      to restore the rate). The contract caps the *additional* price
    ///      movement from that manipulated spot — not the deviation from a
    ///      fair pre-manipulation rate.
    ///
    ///      Layer 1 — `sqrtPriceLimitX96` on the V4 swap caps per-call price
    ///      impact at `maxSlippageBps` *relative to the spot read in
    ///      `unlockCallback`*. A binding limit produces a partial fill (the
    ///      unspent artcoin stays in this contract for the next call).
    ///
    ///      Layer 2 — Post-swap, the output is floor-checked against an
    ///      expected output projected from the spot read in `convert`
    ///      (`SPOT_FLOOR_BPS / 10_000` of `actualIn × spot`). Scaling against
    ///      `actualIn` lets partial fills pass; scaling against the spot the
    ///      contract read means a same-tx attacker who already moved the
    ///      pool sees a correspondingly lower floor.
    ///
    ///      Implication: thin-pool launches where manipulation is cheap
    ///      remain MEV-exposed beyond `maxSlippageBps` by the manipulation
    ///      cost. Mitigate operationally by setting `maxStepIn` and
    ///      `minBlocksBetweenConverts` conservatively, or by extending the
    ///      contract with an off-chain reference price source (TWAP /
    ///      oracle / signed quote) — out of scope for this version.
    ///
    ///      Reentrancy is blocked at the function level (`nonReentrant`); a
    ///      malicious artcoin's `transfer` callback (during `feeLocker.claim`)
    ///      therefore can't re-enter `convert` to double-spend.
    // slither-disable-start reentrancy-no-eth
    // slither-disable-start reentrancy-benign
    // slither-disable-start reentrancy-balance
    //
    // Reentrancy detectors fire on the `feeLocker.claim` /
    // `poolManager.unlock` external calls followed by state writes
    // (`lastConvertBlock`, monotonic counters). The function is wrapped in
    // `nonReentrant`, so a callback cannot re-enter `convert`. The state
    // writes happen before the WETH transfers — the only external calls
    // after the writes are `weth.safeTransfer` to known recipients
    // (canonical WETH9 has no transfer callback) and `feeLocker.storeFees`
    // (depositToLocker mode), which is internally `nonReentrant`.
    function convert(uint256 minOut) external nonReentrant returns (uint256 wethOut) {
        if (!_finalized) revert NotFinalized();
        uint256 next = lastConvertBlock + minBlocksBetweenConverts;
        if (block.number < next) revert ConvertTooEarly(next);

        // Drain any artcoin owed to this contract in the fee locker. `claim`
        // reverts on a zero balance, so guard with `availableFees`. The pull
        // itself may revert from a non-canonical artcoin's transfer; that
        // surface is bounded by `nonReentrant` and the artcoin being a known
        // launched token (not arbitrary user input).
        uint256 escrowed = feeLocker.availableFees(address(this), address(artCoin));
        if (escrowed > 0) {
            feeLocker.claim(address(this), address(artCoin));
        }

        uint256 available = artCoin.balanceOf(address(this));
        // Zero-check is the natural way to test "no artcoin to swap" — not a
        // dangerous strict equality.
        // slither-disable-next-line incorrect-equality
        if (available == 0) revert NothingToConvert();

        uint256 amountIn = available > maxStepIn ? maxStepIn : available;

        // Capture pre-swap spot for the post-swap floor check below. Reading
        // here (via `getSlot0` → `extsload`) does not require the manager
        // to be unlocked. We capture pre-swap rather than post-swap because
        // the swap itself shifts the pool price; the pre-swap value is the
        // reference rate we'd expect the swap to honor.
        // slither-disable-next-line unused-return
        (uint160 preSqrtPriceX96,,,) = poolManager.getSlot0(_poolKey().toId());

        // Pace before the external call — re-entry via a malicious artcoin
        // callback would still be blocked by `nonReentrant`, but pacing
        // before unlock keeps the invariant in case the guard is ever
        // refactored out.
        lastConvertBlock = block.number;

        bytes memory data = abi.encode(amountIn, minOut);
        bytes memory result = poolManager.unlock(data);
        (uint256 received, uint256 actualIn) = abi.decode(result, (uint256, uint256));

        if (received < minOut) revert InsufficientOutput(received, minOut);
        // Defense-in-depth: `unlockCallback` already caps `actualIn <= amountIn`,
        // but we re-assert so accounting can't be tricked even if the inner
        // check is ever weakened.
        if (actualIn > amountIn) revert ExcessInputSpent(actualIn, amountIn);

        // Spot-derived floor on swap output, computed against the ACTUAL
        // consumed input. The floor adapts to the pool's current price every
        // call, so no operator needs to "set the right value" as the pool
        // moves.
        //
        // The check is post-swap (not pre-swap) so a partial fill — where
        // the `sqrtPriceLimitX96` clamp consumed less than `amountIn` —
        // doesn't trip a floor that was sized for the full requested input.
        // Both `received` and the floor's notional scale with `actualIn`,
        // so the rate is what's being asserted.
        //
        // Same-tx spot manipulation can lower this floor, but it cannot
        // bypass the `sqrtPriceLimitX96` clamp inside the actual swap — the
        // clamp is the load-bearing MEV defense. The floor here only blocks
        // the `minOut = 0` grief vector.
        uint256 floor = _spotDerivedFloor(actualIn, preSqrtPriceX96);
        if (received < floor) revert MinOutBelowFloor(received, floor);

        // Keeper reward — bounded by both bps of swap output and a fixed
        // absolute cap. Pro-rated against the actual output, not the
        // requested input, so a partial-fill caller doesn't earn the full
        // reward for a tiny conversion.
        uint256 reward = (received * KEEPER_REWARD_BPS) / 10_000;
        if (reward > KEEPER_REWARD_CAP_WEI) reward = KEEPER_REWARD_CAP_WEI;
        if (reward >= received) reward = 0; // pathological tiny-swap guard
        uint256 net = received - reward;

        totalArtcoinConverted += actualIn;
        totalWethDelivered += net;
        totalKeeperRewards += reward;

        // Forward paid-out currency. `depositToLocker` mode requires
        // `feeLocker.addDepositor(this)` to have been called by the locker
        // owner; in-call surface the failure as `Unauthorized` from the
        // locker, which the caller can surface to the operator.
        if (depositToLocker) {
            _depositToLocker(endRecipient, net);
        } else {
            _payOut(payable(endRecipient), net);
        }

        if (reward > 0) {
            _payOut(payable(msg.sender), reward);
        }

        wethOut = received;
        emit Converted(msg.sender, actualIn, received, net, reward);
    }

    // slither-disable-end reentrancy-balance
    // slither-disable-end reentrancy-benign
    // slither-disable-end reentrancy-no-eth

    /// @notice Drains paired-side fees that have accrued at the escrow under
    ///         this swapper's slot (deposited there by the LP locker from
    ///         buy-side swaps when the swapper is the registered reward
    ///         recipient). Forwards the amount to `endRecipient` minus a
    ///         keeper reward computed exactly like `convert`'s.
    /// @dev    Independent of `convert`'s pacing — the two functions can
    ///         interleave freely, and there's no slippage risk here because
    ///         no swap happens. Reverts with `NothingToFlush` if the slot is
    ///         empty.
    ///
    ///         Reentrancy: same shape as `convert` — `feeLocker.claim` is
    ///         the only external call before the state writes (the
    ///         escrow is the trusted artcoins deployment, not arbitrary
    ///         user input), and the function is `nonReentrant`. Slither
    ///         flags the post-call writes; the suppressions below mark
    ///         them as known-safe under the same rationale as `convert`'s.
    // slither-disable-start reentrancy-no-eth
    // slither-disable-start reentrancy-benign
    function flushPaired() external nonReentrant returns (uint256 pairedOut) {
        if (!_finalized) revert NotFinalized();
        address pairedTokenForEscrow = pairedIsNative ? address(0) : pairedToken;
        uint256 escrowed = feeLocker.availableFees(address(this), pairedTokenForEscrow);
        if (escrowed == 0) revert NothingToFlush();

        feeLocker.claim(address(this), pairedTokenForEscrow);
        pairedOut = escrowed;

        uint256 reward = (pairedOut * KEEPER_REWARD_BPS) / 10_000;
        if (reward > KEEPER_REWARD_CAP_WEI) reward = KEEPER_REWARD_CAP_WEI;
        if (reward >= pairedOut) reward = 0;
        uint256 net = pairedOut - reward;

        totalWethDelivered += net;
        totalKeeperRewards += reward;

        if (depositToLocker) {
            _depositToLocker(endRecipient, net);
        } else {
            _payOut(payable(endRecipient), net);
        }

        if (reward > 0) {
            _payOut(payable(msg.sender), reward);
        }

        emit Flushed(msg.sender, pairedOut, net, reward);
    }

    // slither-disable-end reentrancy-benign
    // slither-disable-end reentrancy-no-eth

    /// @dev Pays `amount` of the paired currency to `to`. Branches on
    ///      native-vs-ERC20 mode. `to` is always one of: the immutable
    ///      `endRecipient` (chosen at deploy time) or `msg.sender` (the
    ///      keeper earning the bounded reward) — never an arbitrary or
    ///      attacker-controlled destination, so Slither's
    ///      `arbitrary-send-eth` flag here is a false positive.
    // slither-disable-next-line arbitrary-send-eth
    function _payOut(address payable to, uint256 amount) internal {
        if (pairedIsNative) {
            // slither-disable-next-line low-level-calls
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeSendFailed();
        } else {
            IERC20(pairedToken).safeTransfer(to, amount);
        }
    }

    /// @dev Credits `amount` of the paired currency to `feeOwner`'s slot at
    ///      the fee locker. Branches on native-vs-ERC20 mode; native uses
    ///      the `IArtCoinsFeeEscrow.storeFeesNative{value:}` path, which
    ///      reverts if the locker doesn't support it (WETH-paired pools
    ///      never reach this branch). `feeLocker` is immutable
    ///      so Slither's `arbitrary-send-eth` is a false positive.
    // slither-disable-next-line arbitrary-send-eth
    function _depositToLocker(address feeOwner, uint256 amount) internal {
        if (pairedIsNative) {
            IArtCoinsFeeEscrow(address(feeLocker)).storeFeesNative{value: amount}(feeOwner);
        } else {
            IERC20(pairedToken).forceApprove(address(feeLocker), amount);
            feeLocker.storeFees(feeOwner, pairedToken, amount);
        }
    }

    /// @notice V4 unlock callback. Restricted to PoolManager. Performs the
    ///         exact-input swap with a narrowed `sqrtPriceLimitX96`, settles
    ///         the artcoin side with the actual amount the pool consumed
    ///         (handles partial fills), and takes the WETH side.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 amountIn,) = abi.decode(data, (uint256, uint256));

        PoolKey memory key = _poolKey();
        // For native-ETH pools (`pairedToken == address(0)`), the artcoin
        // always sorts above zero so `artcoinIsToken0 = false`. For WETH
        // pools we compare addresses directly.
        bool artcoinIsToken0 = address(artCoin) < pairedToken;

        // Narrow sqrtPriceLimitX96 to a per-call price-impact bound. Linear
        // approximation: sqrt(1 ± x) ≈ 1 ± x/2 for small x, so a `bps` price
        // tolerance becomes a `bps/2`-equivalent sqrtPrice tolerance,
        // implemented as `(20000 ± slippageBps) / 20000`. Conservative for
        // the upper bps range — fine since binding clamps to a partial fill
        // rather than reverting.
        // slither-disable-next-line unused-return
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint256 slippageBps = maxSlippageBps;
        uint160 sqrtPriceLimitX96;
        if (artcoinIsToken0) {
            // selling artcoin (token0) for WETH (token1) — zeroForOne — price decreases
            uint256 candidate = (uint256(currentSqrtPriceX96) * (20_000 - slippageBps)) / 20_000;
            if (candidate <= uint256(TickMath.MIN_SQRT_PRICE)) {
                sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1;
            } else {
                sqrtPriceLimitX96 = uint160(candidate);
            }
        } else {
            // selling artcoin (token1) for WETH (token0) — oneForZero — price increases
            uint256 candidate = (uint256(currentSqrtPriceX96) * (20_000 + slippageBps)) / 20_000;
            if (candidate >= uint256(TickMath.MAX_SQRT_PRICE)) {
                sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
            } else {
                sqrtPriceLimitX96 = uint160(candidate);
            }
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: artcoinIsToken0,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        BalanceDelta delta = poolManager.swap(key, params, "");
        int256 d0 = int256(delta.amount0());
        int256 d1 = int256(delta.amount1());

        uint256 actualArtcoinIn;
        uint256 wethReceived;
        if (artcoinIsToken0) {
            // d0 ≤ 0 (we owe artcoin to pool), d1 ≥ 0 (pool owes WETH to us)
            if (d0 > 0 || d1 < 0) revert BadDelta();
            actualArtcoinIn = uint256(-d0);
            wethReceived = uint256(d1);
        } else {
            // d1 ≤ 0 (we owe artcoin), d0 ≥ 0 (pool owes WETH)
            if (d1 > 0 || d0 < 0) revert BadDelta();
            actualArtcoinIn = uint256(-d1);
            wethReceived = uint256(d0);
        }

        // Enforce the exact-input cap locally. An honest pool honors
        // `amountSpecified = -int256(amountIn)`; a hook with delta-return
        // permissions could in principle indicate more input was consumed
        // than asked for, which would let it bypass the per-call cap. Reject
        // defensively.
        if (actualArtcoinIn > amountIn) revert ExcessInputSpent(actualArtcoinIn, amountIn);

        // Settle the artcoin side (we pay the pool the actual consumption,
        // not the originally requested cap — handles partial fills).
        poolManager.sync(Currency.wrap(address(artCoin)));
        artCoin.safeTransfer(address(poolManager), actualArtcoinIn);
        // settle() returns the amount paid which equals our transfer above —
        // the swap delta's actualArtcoinIn is the authoritative figure.
        // slither-disable-next-line unused-return
        poolManager.settle();

        // Take the paired side. For WETH-paired pools this lands as an
        // ERC20 transfer to this contract; for native-ETH pools, V4 sends
        // native ETH via low-level call (accepted by `receive()`).
        poolManager.take(Currency.wrap(pairedToken), address(this), wethReceived);

        return abi.encode(wethReceived, actualArtcoinIn);
    }

    // ─── views ──────────────────────────────────────────────────────────

    /// @inheritdoc IFeeAutoSwapper
    function accruedArtCoin() external view returns (uint256) {
        uint256 escrowed = feeLocker.availableFees(address(this), address(artCoin));
        uint256 held = artCoin.balanceOf(address(this));
        return escrowed + held;
    }

    /// @inheritdoc IFeeAutoSwapper
    function accruedPaired() external view returns (uint256) {
        address tok = pairedIsNative ? address(0) : pairedToken;
        return feeLocker.availableFees(address(this), tok);
    }

    /// @inheritdoc IFeeAutoSwapper
    function nextConvertibleBlock() external view returns (uint256) {
        return lastConvertBlock + minBlocksBetweenConverts;
    }

    /// @inheritdoc IFeeAutoSwapper
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey();
    }

    function _poolKey() internal view returns (PoolKey memory) {
        // For native-ETH pools, `pairedToken = address(0)` sorts below any
        // real artcoin address, so the artcoin is always token1 and ETH is
        // token0. For WETH-paired pools, comparison falls out normally.
        bool artcoinIsToken0 = address(artCoin) < pairedToken;
        return PoolKey({
            currency0: Currency.wrap(artcoinIsToken0 ? address(artCoin) : pairedToken),
            currency1: Currency.wrap(artcoinIsToken0 ? pairedToken : address(artCoin)),
            fee: poolFee,
            tickSpacing: poolTickSpacing,
            hooks: hook
        });
    }

    /// @notice Derives the `minOut` floor from a captured pre-swap
    ///         `sqrtPriceX96`, projected over the supplied input amount.
    ///         Splits the per-Q96 multiplication into two `FullMath.mulDiv`
    ///         calls so we never overflow at extreme prices (where
    ///         `sqrtPriceX96^2` exceeds `uint256`).
    function _spotDerivedFloor(uint256 amountIn, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256)
    {
        bool artcoinIsToken0 = address(artCoin) < pairedToken;

        // price = (sqrtPriceX96 / 2^96)^2 = token1/token0 spot.
        // For artcoinIsToken0:  expectedOut(paired) = amountIn × price.
        // For artcoinIsToken1:  expectedOut(paired) = amountIn / price.
        uint256 expectedOut;
        if (artcoinIsToken0) {
            uint256 step1 = FullMath.mulDiv(amountIn, sqrtPriceX96, 1 << 96);
            expectedOut = FullMath.mulDiv(step1, sqrtPriceX96, 1 << 96);
        } else {
            uint256 step1 = FullMath.mulDiv(amountIn, 1 << 96, sqrtPriceX96);
            expectedOut = FullMath.mulDiv(step1, 1 << 96, sqrtPriceX96);
        }

        return (expectedOut * SPOT_FLOOR_BPS) / 10_000;
    }
}
