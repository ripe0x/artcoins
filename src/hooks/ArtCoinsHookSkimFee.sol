// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsTaxable} from "../interfaces/IArtCoinsTaxable.sol";
import {IPreSwapStream} from "../interfaces/IPreSwapStream.sol";
import {IArtCoinsMevSkim} from "../mev-modules/interfaces/IArtCoinsMevSkim.sol";
import {ArtCoinsHook} from "./ArtCoinsHook.sol";
import {
    IArtCoinsHookSkimFee,
    IReferralPayoutForHook,
    PCAttribution,
    PCSwapData
} from "./interfaces/IArtCoinsHookSkimFee.sol";
import {SkimFeeConstants} from "./libraries/SkimFeeConstants.sol";
import {SkimFeeInitLib} from "./libraries/SkimFeeInitLib.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta, sub, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @title  ArtCoinsHookSkimFee
/// @notice Skim-based hook variant with **per-swap three-leg split**:
///         bounty / protocol / referral. Computed at swap time from gross
///         volume so the bounty leg is structurally invariant — a referral
///         payment can NEVER reduce it (only the protocol slice).
///
///         Per-swap math (inside `_beforeSwap` / `_afterSwap`):
///
///           totalSkim       = volume × currentSkimBps / 100_000
///           baselineSkim    = volume × baselineSkimBps / 100_000
///           antiSniperExtra = totalSkim − baselineSkim
///
///           bountyShare     = baselineSkim × bountyBps / 10_000
///           protocolShare   = baselineSkim − bountyShare
///
///           requestedRef    = min(att.referralBps, maxReferralBpsOfVolume)
///           referral        = min(volume × requestedRef / 100_000,
///                                 protocolShare)
///           protocolNet     = protocolShare − referral
///
///         Accruals:
///           accruedBounty[pid]                  += bountyShare + antiSniperExtra
///           accruedProtocol[pid]                += protocolNet
///           accruedReferral[pid][referrer]      += referral
///
///         All three accruals are flushed at the END of `_afterSwap` of the
///         SAME swap, fresh-only with no held/retry state: the bid leg is
///         pushed to `cfg.bountyRecipient` and REVERTS the swap if that push
///         fails, the protocol leg is deposited into `ArtCoinsFeeEscrow` under
///         `cfg.protocolRecipient` for that recipient to pull, and the referral
///         leg is credited to `cfg.referralPayout` (folding into the protocol
///         escrow on the rare failure). The hook never holds a claim balance
///         between swaps and keeps no per-recipient retry bookkeeping.
abstract contract ArtCoinsHookSkimFeeBase is ArtCoinsHook, IArtCoinsHookSkimFee {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    /// @inheritdoc IArtCoinsHookSkimFee
    /// @dev 90% anti-sniper start, sourced from the shared `SkimFeeConstants`
    ///      so the MEV module, init-lib, and hook can never silently diverge.
    uint24 public constant override MAX_SKIM_BPS = SkimFeeConstants.MAX_SKIM_BPS;

    /// @inheritdoc IArtCoinsHookSkimFee
    uint24 public constant override MAX_REFERRAL_CAP_OF_VOLUME = 1000;

    /// @inheritdoc IArtCoinsHookSkimFee
    uint256 public constant override SKIM_DENOMINATOR = 100_000;

    /// @inheritdoc IArtCoinsHookSkimFee
    uint256 public constant override BPS_DENOMINATOR = 10_000;

    /// @notice Gas budget for recipient ETH-forwarding `.call`s.
    uint256 public constant SKIM_FORWARD_GAS = 35_000;

    /// @notice Min bounty-recipient balance before the optional pre-swap
    ///         stream call fires in `_beforeSwap` (see `IPreSwapStream`). Keeps
    ///         the common case a cheap balance read rather than a CALL, and
    ///         matches the recipient's own dust floor so a fired call isn't a
    ///         guaranteed no-op.
    uint256 public constant PRE_SWAP_STREAM_MIN = 0.01 ether;

    struct _SkimConfig {
        uint24 baselineSkimBps;
        uint16 bountyBps;
        uint24 maxReferralBpsOfVolume;
        uint24 lpFee;
        bool taxEnabled;
        address payable bountyRecipient;
        address payable protocolRecipient;
        address payable referralPayout;
        address quoteToken;
    }

    /// @dev Args bundle for `_processSkimAndAttribution`. Folding 5 of the
    ///      6 params into a single memory pointer keeps the swap-hook call
    ///      sites under the 16-slot EVM stack ceiling, so vanilla codegen
    ///      compiles cleanly (no StackTooDeep). `swapData` stays separate
    ///      because Solidity disallows `bytes calldata` inside memory
    ///      structs.
    struct _ProcessSkimArgs {
        PoolId pid;
        _SkimConfig cfg;
        uint256 volume;
        bool isExactInput;
        address swapper;
    }

    mapping(PoolId => _SkimConfig) internal _skimConfig;

    /// @dev Accrued bounty-leg claim tokens (bountyShare + antiSniperExtra).
    ///      Cleared at the end of every `_afterSwap`, so any non-zero value
    ///      between swaps would be a bug. `internal` to save the auto-getter
    ///      dispatch bytecode — these are operationally transient and never
    ///      consumed externally.
    mapping(PoolId => uint256) internal accruedBounty;
    /// @dev Accrued protocol-leg claim tokens (post-referral). See `accruedBounty`.
    mapping(PoolId => uint256) internal accruedProtocol;

    /// @inheritdoc IArtCoinsHookSkimFee
    mapping(PoolId => mapping(address => uint256)) public override accruedReferral;

    constructor(
        address _poolManager,
        address _factory,
        address _poolExtensionAllowlist,
        address _weth,
        address _feeEscrow
    ) ArtCoinsHook(_poolManager, _factory, _poolExtensionAllowlist, _weth, _feeEscrow) {}

    // ─── public accessor ─────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsHookSkimFee
    function skimConfig(PoolId poolId)
        external
        view
        override
        returns (
            uint24 baselineSkimBps,
            uint16 bountyBps,
            uint24 maxReferralBpsOfVolume,
            uint24 lpFee,
            address payable bountyRecipient,
            address payable protocolRecipient,
            address payable referralPayout,
            address quoteToken
        )
    {
        _SkimConfig memory c = _skimConfig[poolId];
        return (
            c.baselineSkimBps,
            c.bountyBps,
            c.maxReferralBpsOfVolume,
            c.lpFee,
            c.bountyRecipient,
            c.protocolRecipient,
            c.referralPayout,
            c.quoteToken
        );
    }

    /// @inheritdoc IArtCoinsHookSkimFee
    function poolTaxEnabled(PoolId poolId) external view override returns (bool) {
        return _skimConfig[poolId].taxEnabled;
    }

    // ─── admin setters ───────────────────────────────────────────────────

    /// @notice Updates the per-pool referral cap (in 100k-denom bps of
    ///         volume). Token admin only; hard-capped at
    ///         `MAX_REFERRAL_CAP_OF_VOLUME` (1_000 = 1% of swap volume).
    /// @dev    The next swap reads the updated value via
    ///         `_skimConfig[pid].maxReferralBpsOfVolume`. The cap clamps
    ///         the swap's `att.referralBps` so a malicious attribution
    ///         payload can never request more than the current cap. The setter
    ///         is gated to the pool's token admin (`onlyTokenAdmin`); the
    ///         lifecycle of that admin role, including any freeze, is governed
    ///         by the contract that holds it, not here.
    /// @param  poolKey The pool key.
    /// @param  newCap  New cap in 100k-denom bps. Must be ≤ MAX_REFERRAL_CAP_OF_VOLUME.
    function setMaxReferralBpsOfVolume(PoolKey calldata poolKey, uint24 newCap)
        external
        onlyTokenAdmin(poolKey)
    {
        if (newCap > MAX_REFERRAL_CAP_OF_VOLUME) revert MaxReferralTooHigh();
        PoolId pid = poolKey.toId();
        _skimConfig[pid].maxReferralBpsOfVolume = newCap;
        emit MaxReferralBpsUpdated(pid, newCap);
    }

    // ─── init ────────────────────────────────────────────────────────────

    function _initializeFeeData(PoolKey memory poolKey, bytes memory feeData) internal override {
        // Validation chain extracted to a separately-deployed library (cold
        // path — runs once per pool init). The delegatecall lifts ~1.5 KB of
        // bytecode off this contract so the deployed runtime fits under EIP-170.
        SkimHookFeeData memory cfg = SkimFeeInitLib.validate(
            feeData, Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1)
        );

        PoolId pid = poolKey.toId();

        // Venue-scoped transfer-tax auto-detection. Enable the canonical-buy /
        // LP-removal attestation path IFF the art-coin token names THIS hook as
        // its canonical hook. `canonicalHook()` is `view` ⇒ Solidity emits a
        // STATICCALL (no state mutation / reentrancy possible), and the
        // try/catch absorbs every non-tax token (no such selector, or a
        // zero/other hook → `taxOn = false`). This derives the flag from the
        // token itself rather than trusting `poolData`, so it cannot be
        // misconfigured, and it is harmless on the permissionless
        // `initializePoolOpen` path (attest sites also require `locker[pid] != 0`,
        // and the token independently rejects any non-canonical pool id).
        // `artCoinIsToken0[pid]` was set by `_initializePool` just above.
        address artCoin = artCoinIsToken0[pid]
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);
        bool taxOn;
        try IArtCoinsTaxable(artCoin).canonicalHook() returns (address h) {
            taxOn = (h == address(this));
        } catch {}

        _skimConfig[pid] = _SkimConfig({
            baselineSkimBps: cfg.baselineSkimBps,
            bountyBps: cfg.bountyBps,
            maxReferralBpsOfVolume: cfg.maxReferralBpsOfVolume,
            lpFee: cfg.lpFee,
            taxEnabled: taxOn,
            bountyRecipient: cfg.bountyRecipient,
            protocolRecipient: cfg.protocolRecipient,
            referralPayout: cfg.referralPayout,
            quoteToken: cfg.quoteToken
        });

        emit SkimConfigInitialized(
            pid,
            cfg.baselineSkimBps,
            cfg.bountyBps,
            cfg.maxReferralBpsOfVolume,
            cfg.lpFee,
            cfg.quoteToken
        );
    }

    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata) internal override {
        IPoolManager(poolManager).updateDynamicLPFee(poolKey, _skimConfig[poolKey.toId()].lpFee);
    }

    // ─── swap hooks ──────────────────────────────────────────────────────

    function _beforeSwap(
        address sender,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata swapData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId pid = poolKey.toId();
        _SkimConfig memory cfg = _skimConfig[pid];

        // Optional pre-swap stream: if the bounty recipient implements
        // `IPreSwapStream` (opt-in by interface, no config), let it flush its
        // PRIOR buffered fees onward before this swap executes — so the
        // downstream balance (PC's live bid) advances on a per-swap cadence.
        // This swap's own skim is taken later (in this `_beforeSwap`'s skim
        // accounting / `_afterSwap`), so only already-accrued funds move here.
        // try/catch: a non-implementing recipient (or any revert) is caught,
        // so this can never brick a swap. Balance-gated so non-participating
        // pools pay only a cheap read on most swaps. Runs OUTSIDE the
        // synchronous-extension `inSwap` window (that's set around the
        // `_afterSwap` extension callback), so it composes with a bound pool
        // extension without tripping its reentrancy guard.
        address payable br = cfg.bountyRecipient;
        if (br != address(0) && br.balance >= PRE_SWAP_STREAM_MIN) {
            try IPreSwapStream(br).streamForward() {} catch {}
        }

        _setFee(poolKey, swapParams);
        // Skim modules own a SINGLE lifetime model. The hook reads the decay
        // schedule directly — `_currentSkimBpsClamped` (→ `currentSkimBps`)
        // for the per-swap amount and `_beforeAddLiquidity` (→ `operational`)
        // for the public-LP lock. The base hook's generic per-swap MEV
        // plumbing (`_runMevModule` → `mevModuleOperational`) is deliberately
        // NOT invoked here: for a skim module the `beforeSwap` callback is a
        // no-op on the LP fee, so it adds nothing, and calling
        // `mevModuleOperational` would expire the generic `mevModuleEnabled`
        // flag at `MAX_MEV_MODULE_DELAY` (15m) — out of step with, and
        // corrupting, the skim's own longer decay window (see the contract
        // notice and `_beforeAddLiquidity`).
        // Flush happens at the END of `_afterSwap` of the SAME swap, so each
        // swap's skim reaches the recipients within its own tx. Nothing to
        // flush here — accruals are always zero on entry.

        (bool quoteIsToken0, bool quoteIsSpecified, uint256 specifiedAbs) =
            _swapDirection(poolKey, swapParams, cfg.quoteToken);

        if (!quoteIsSpecified) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool isExactInput = swapParams.amountSpecified < 0;
        uint256 totalSkim = _runProcessSkim(pid, cfg, specifiedAbs, isExactInput, sender, swapData);

        if (totalSkim == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        Currency quoteCcy = quoteIsToken0 ? poolKey.currency0 : poolKey.currency1;
        poolManager.mint(address(this), quoteCcy.toId(), totalSkim);

        require(totalSkim <= uint256(uint128(type(int128).max)), "skim overflow");
        int128 dSpec = int128(uint128(totalSkim));
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(dSpec, 0), 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata swapData
    ) internal override returns (bytes4, int128) {
        PoolId pid = poolKey.toId();
        _SkimConfig memory cfg = _skimConfig[pid];

        (bool quoteIsToken0, bool quoteIsSpecified,) =
            _swapDirection(poolKey, swapParams, cfg.quoteToken);

        int128 unspecifiedDelta = 0;

        if (!quoteIsSpecified) {
            int128 quoteDelta = quoteIsToken0 ? delta.amount0() : delta.amount1();
            bool isExactInput = swapParams.amountSpecified < 0;

            uint256 quoteMagnitude;
            if (isExactInput) {
                require(quoteDelta >= 0, "unexpected quote delta sign (exactInput)");
                quoteMagnitude = uint256(uint128(quoteDelta));
            } else {
                require(quoteDelta <= 0, "unexpected quote delta sign (exactOutput)");
                quoteMagnitude = uint256(uint128(-quoteDelta));
            }

            uint256 totalSkim =
                _runProcessSkim(pid, cfg, quoteMagnitude, isExactInput, sender, swapData);

            if (totalSkim > 0) {
                Currency quoteCcy = quoteIsToken0 ? poolKey.currency0 : poolKey.currency1;
                poolManager.mint(address(this), quoteCcy.toId(), totalSkim);

                require(totalSkim <= uint256(uint128(type(int128).max)), "skim overflow");
                unspecifiedDelta = int128(uint128(totalSkim));

                if (quoteIsToken0) {
                    delta = sub(delta, toBalanceDelta(unspecifiedDelta, 0));
                } else {
                    delta = sub(delta, toBalanceDelta(0, unspecifiedDelta));
                }
            }
        }

        if (quoteIsSpecified) {
            if (quoteIsToken0) {
                delta = toBalanceDelta(int128(swapParams.amountSpecified), delta.amount1());
            } else {
                delta = toBalanceDelta(delta.amount0(), int128(swapParams.amountSpecified));
            }
        }

        // Forward `poolSwapData.poolExtensionSwapData` (= encoded PCSwapData)
        // to a bound extension if any. The extension decodes `extensionPayload`
        // itself — the hook is agnostic to its shape.
        _runPoolExtension(poolKey, swapParams, sender, delta, swapData);

        // Venue-scoped transfer tax (PC's 111PUNKS only): attest the realized
        // PCT amount this canonical buy moves OUT to the trader, so the token
        // exempts exactly that much of the later take from its tax. No-op for
        // every non-tax pool. The art-coin-side delta is positive iff PCT is
        // leaving the pool to the swapper (a buy); the hook only modifies the
        // QUOTE side, so this side is the true PCT-out the trader will `take`.
        _attestCanonicalSkimExempt(poolKey, pid, cfg, delta);

        // Flush this swap's accruals to all recipients (bounty, protocol,
        // AND the credited referrer if any) within the SAME tx, so the hook
        // never holds a claim balance between swaps and adapters always
        // reflect the up-to-the-second total. `_runPoolExtension` ran first
        // so any bound Design B dispatcher sees the canonical pre-flush delta.
        _flushAccruedSkim(pid, cfg, swapData);

        return (BaseHook.afterSwap.selector, unspecifiedDelta);
    }

    /// @dev Public-LP lock for the anti-sniper window. Gated SOLELY on the
    ///      skim module's own decay window (`IArtCoinsMevSkim.operational`) —
    ///      the single lifetime model for skim-based protection.
    ///
    ///      It deliberately does NOT consult the base hook's generic
    ///      `mevModuleOperational` / `mevModuleEnabled` / `MAX_MEV_MODULE_DELAY`
    ///      machinery. That model expires at 15m and exists for LP-fee MEV
    ///      modules that dial the dynamic fee; a skim module's window is
    ///      independent and longer (default 69m). Reading `operational()`
    ///      directly makes the lock exactly the skim window. Gating instead on
    ///      the generic `mevModuleEnabled` flag would let it — once cleared by
    ///      the first swap past 15m — fall through and ALLOW adds while the
    ///      skim is still live, silently shrinking the documented lock to ~15m.
    ///      Owning one lifetime model removes that interference.
    ///
    ///      Fail-open: if no module is bound (`mod == 0`, e.g. an
    ///      `initializePoolOpen` pool) or the bound module is not an
    ///      `IArtCoinsMevSkim` (its `operational()` reverts — a deploy-time
    ///      misconfiguration that already breaks the skim computation), no
    ///      lock is imposed. The production module's `operational()` is a pure
    ///      storage read that never reverts, so the catch is unreachable in a
    ///      correctly-wired pool; fail-open avoids permanently bricking
    ///      liquidity on a misconfigured one.
    ///
    ///      `view` is load-bearing, not incidental: it guarantees the lock can
    ///      never carry a side effect. Coupling to the base hook's
    ///      `mevModuleOperational` — which mutates `mevModuleEnabled` as a
    ///      side effect — is precisely what would shrink the window; a pure
    ///      read cannot introduce that class of bug.
    function _beforeAddLiquidity(
        address,
        PoolKey calldata poolKey,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        PoolId pid = poolKey.toId();
        address mod = mevModule[pid];
        if (mod != address(0)) {
            try IArtCoinsMevSkim(mod).operational(pid) returns (bool op) {
                if (op) revert MevModuleEnabled();
            } catch {
                // Non-skim / unconfigured module: no skim lifetime to enforce.
            }
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @notice Attest canonical LP removals for the venue-scoped transfer tax.
    /// @dev Enabled in `getHookPermissions` ONLY so a tax-enabled pool can
    ///      exempt public LP exits: a withdrawing LP receives PCT FROM the
    ///      PoolManager (a venue), which would otherwise be taxed. We attest the
    ///      realized PCT amount removed so the token exempts exactly that. For
    ///      every non-tax pool this is a pure pass-through. `delta` is the
    ///      caller's owed amount (principal + accrued fees); its art-coin-side
    ///      component is positive for a removal. We never return a non-zero
    ///      delta (the `afterRemoveLiquidityReturnDelta` permission stays off).
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata poolKey,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId pid = poolKey.toId();
        _SkimConfig memory cfg = _skimConfig[pid];
        _attestCanonicalSkimExempt(poolKey, pid, cfg, delta);
        return (BaseHook.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
    }

    /// @dev Attest the realized PCT amount leaving the PoolManager to a trader
    ///      (canonical buy) or an exiting LP (canonical removal), so the token
    ///      exempts that exact amount from its venue-scoped transfer tax.
    ///      No-op unless the tax is enabled for this FACTORY-BLESSED pool
    ///      (`locker[pid] != 0` distinguishes `initializePool` from the
    ///      permissionless `initializePoolOpen` path). The token independently
    ///      rejects any attestation whose pool id is not its single canonical
    ///      pool id, so this is gated on both ends. The art-coin-side delta is
    ///      positive iff PCT is flowing OUT (a buy / removal); PCT flowing IN
    ///      (a sell / LP add) is never taxed and needs no budget.
    function _attestCanonicalSkimExempt(
        PoolKey calldata poolKey,
        PoolId pid,
        _SkimConfig memory cfg,
        BalanceDelta delta
    ) internal {
        if (!cfg.taxEnabled || locker[pid] == address(0)) return;
        bool artIsToken0 = artCoinIsToken0[pid];
        int128 pctDelta = artIsToken0 ? delta.amount0() : delta.amount1();
        if (pctDelta <= 0) return;
        address artCoin =
            artIsToken0 ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
        IArtCoinsTaxable(artCoin)
            .attestCanonicalBudget(PoolId.unwrap(pid), uint256(uint128(pctDelta)));
    }

    // ─── skim + attribution core ─────────────────────────────────────────

    /// @dev Thin wrapper that builds `_ProcessSkimArgs` and dispatches.
    ///      Exists so the `_beforeSwap` / `_afterSwap` call sites only
    ///      need to push 6 args into a fresh function scope rather than
    ///      materialize a memory struct inline alongside their own
    ///      already-large local set — the latter hits StackTooDeep under
    ///      vanilla codegen even with the struct refactor.
    function _runProcessSkim(
        PoolId pid,
        _SkimConfig memory cfg,
        uint256 volume,
        bool isExactInput,
        address swapper,
        bytes calldata swapData
    ) internal returns (uint256) {
        _ProcessSkimArgs memory args;
        args.pid = pid;
        args.cfg = cfg;
        args.volume = volume;
        args.isExactInput = isExactInput;
        args.swapper = swapper;
        return _processSkimAndAttribution(args, swapData);
    }

    function _processSkimAndAttribution(_ProcessSkimArgs memory args, bytes calldata swapData)
        internal
        returns (uint256 totalSkim)
    {
        uint256 baselineSkim;
        uint256 antiSniperExtra;
        (totalSkim, baselineSkim, antiSniperExtra) = _skimAmounts({
            pid: args.pid,
            baselineBps: args.cfg.baselineSkimBps,
            primarySide: args.volume,
            isExactInput: args.isExactInput
        });

        if (totalSkim == 0) return 0;

        uint256 bountyShare = (baselineSkim * uint256(args.cfg.bountyBps)) / BPS_DENOMINATOR;
        // protocolShare absorbs rounding dust.
        uint256 protocolShare = baselineSkim - bountyShare;

        PCAttribution memory att = _decodeAttribution(swapData);

        uint256 requestedRef = att.referralBps < args.cfg.maxReferralBpsOfVolume
            ? uint256(att.referralBps)
            : uint256(args.cfg.maxReferralBpsOfVolume);
        // Simple volume-based referral. The ~0.0125%-of-volume drift relative
        // to a perfectly gross-up'd formula in exact-output cases is bounded
        // and operationally negligible.
        uint256 requestedReferralAmt = (args.volume * requestedRef) / SKIM_DENOMINATOR;

        // The referral slice is carved only when the swap carries a referrer;
        // with none it stays in the protocol leg. Live from the first swap.
        uint256 referral = 0;
        if (att.referrer != address(0) && requestedReferralAmt > 0) {
            referral = requestedReferralAmt < protocolShare ? requestedReferralAmt : protocolShare;
            if (referral < requestedReferralAmt) {
                emit ReferralUnderpaid(args.pid, att.referrer, requestedReferralAmt, referral);
            }
        }

        uint256 protocolNet = protocolShare - referral;
        uint256 bountyTotal = bountyShare + antiSniperExtra;

        accruedBounty[args.pid] += bountyTotal;
        accruedProtocol[args.pid] += protocolNet;
        if (referral > 0) {
            accruedReferral[args.pid][att.referrer] += referral;
        }

        emit SkimSplit(args.pid, args.volume, bountyTotal, protocolNet, referral);
        if (att.referrer != address(0) || att.sourceId != bytes32(0)) {
            emit SwapAttribution(
                args.pid,
                args.swapper,
                att.referrer,
                att.sourceId,
                att.campaignId,
                args.volume,
                referral
            );
        }
    }

    function _skimAmounts(PoolId pid, uint24 baselineBps, uint256 primarySide, bool isExactInput)
        internal
        view
        returns (uint256 totalSkim, uint256 baselineSkim, uint256 antiSniperExtra)
    {
        uint24 totalBps = _currentSkimBpsClamped(pid, baselineBps);
        if (totalBps == 0 || primarySide == 0) return (0, 0, 0);

        if (isExactInput) {
            totalSkim = (primarySide * uint256(totalBps)) / SKIM_DENOMINATOR;
            baselineSkim = (primarySide * uint256(baselineBps)) / SKIM_DENOMINATOR;
        } else {
            totalSkim = (primarySide * uint256(totalBps)) / (SKIM_DENOMINATOR - uint256(totalBps));
            baselineSkim =
                (primarySide * uint256(baselineBps)) / (SKIM_DENOMINATOR - uint256(totalBps));
        }
        antiSniperExtra = totalSkim > baselineSkim ? totalSkim - baselineSkim : 0;
        if (baselineSkim > totalSkim) baselineSkim = totalSkim;
    }

    function _currentSkimBpsClamped(PoolId pid, uint24 baselineBps) internal view returns (uint24) {
        address mod = mevModule[pid];
        if (mod == address(0)) return baselineBps;
        uint24 reported;
        try IArtCoinsMevSkim(mod).currentSkimBps(pid) returns (uint24 v) {
            reported = v;
        } catch {
            return baselineBps;
        }
        if (reported < baselineBps) reported = baselineBps;
        if (reported > MAX_SKIM_BPS) reported = MAX_SKIM_BPS;
        return reported;
    }

    function _swapDirection(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        address quoteToken
    ) internal pure returns (bool quoteIsToken0, bool quoteIsSpecified, uint256 specifiedAbs) {
        quoteIsToken0 = (quoteToken == Currency.unwrap(poolKey.currency0));
        bool quoteIsInput = (swapParams.zeroForOne == quoteIsToken0);
        bool isExactInput = swapParams.amountSpecified < 0;
        quoteIsSpecified = (quoteIsInput == isExactInput);
        specifiedAbs = isExactInput
            ? uint256(-swapParams.amountSpecified)
            : uint256(swapParams.amountSpecified);
    }

    // ─── attribution decode ──────────────────────────────────────────────

    function _decodeAttribution(bytes calldata swapData)
        internal
        view
        returns (PCAttribution memory att)
    {
        if (swapData.length == 0) return att;

        try this._decodePoolSwapData(swapData) returns (
            bytes memory mevData, bytes memory poolExtData
        ) {
            mevData;
            if (poolExtData.length == 0) return att;

            try this._decodePCSwapData(poolExtData) returns (PCSwapData memory inner) {
                return inner.attribution;
            } catch {
                return att;
            }
        } catch {
            return att;
        }
    }

    function _decodePoolSwapData(bytes calldata data)
        external
        pure
        returns (bytes memory mevModuleSwapData, bytes memory poolExtensionSwapData)
    {
        PoolSwapData memory psd = abi.decode(data, (PoolSwapData));
        return (psd.mevModuleSwapData, psd.poolExtensionSwapData);
    }

    function _decodePCSwapData(bytes calldata data) external pure returns (PCSwapData memory) {
        return abi.decode(data, (PCSwapData));
    }

    // ─── intra-tx flush (3 pool-level legs + referral) ───────────────────

    /// @dev Drains this swap's three accrued legs to their recipients within
    ///      the SAME `_afterSwap`. Fresh-only: the hook keeps NO held/retry
    ///      state. Each leg has its own delivery contract and failure policy:
    ///        - bid (bounty + antiSniperExtra): pushed to `cfg.bountyRecipient`.
    ///          A failed transfer REVERTS the swap rather than being held, so
    ///          this recipient must always accept ETH.
    ///        - protocol: deposited into the fee escrow under
    ///          `cfg.protocolRecipient` for that recipient to claim + route
    ///          later. The escrow credits this hook (an allowlisted depositor),
    ///          so there is nothing to retry.
    ///        - referral: credited to `cfg.referralPayout`, a pull ledger. On
    ///          the (hook-only, near-impossible) failure the amount folds into
    ///          the protocol escrow instead of being held: no stuck funds, no
    ///          swap revert.
    function _flushAccruedSkim(PoolId pid, _SkimConfig memory cfg, bytes calldata swapData)
        internal
    {
        uint256 b = accruedBounty[pid];
        uint256 p = accruedProtocol[pid];

        // Re-decode this swap's attribution to learn which referrer (if any)
        // was credited. `_decodeAttribution` is try/catch-tolerant of malformed
        // data, so an absent/invalid attribution yields referrer=address(0) and
        // the referral path is skipped.
        address swapReferrer = _decodeAttribution(swapData).referrer;
        uint256 r = 0;
        if (swapReferrer != address(0)) {
            r = accruedReferral[pid][swapReferrer];
            if (r > 0) accruedReferral[pid][swapReferrer] = 0;
        }

        uint256 freshTotal = b + p + r;
        if (freshTotal == 0) return;

        accruedBounty[pid] = 0;
        accruedProtocol[pid] = 0;
        // accruedReferral[pid][swapReferrer] already cleared above.

        // Convert this swap's accrued claim tokens to native ETH on the hook.
        Currency quoteCcy = Currency.wrap(cfg.quoteToken);
        poolManager.burn(address(this), quoteCcy.toId(), freshTotal);
        poolManager.take(quoteCcy, address(this), freshTotal);

        // Bid leg: must reach `cfg.bountyRecipient` immediately; revert on
        // failure (full gas, no hold). This recipient must always accept ETH.
        if (b > 0) {
            (bool ok,) = cfg.bountyRecipient.call{value: b}("");
            if (!ok) revert BidForwardFailed();
            emit LegForwarded(pid, 0, cfg.bountyRecipient, b);
        }

        // Protocol leg: pull-based via the fee escrow. Allowlist-gated; this
        // hook is an allowlisted depositor, so the deposit always succeeds.
        if (p > 0) {
            feeEscrow.storeFeesNative{value: p}(cfg.protocolRecipient);
            emit LegForwarded(pid, 2, cfg.protocolRecipient, p);
        }

        // Referral leg: pull-based via `cfg.referralPayout`. Fail-safe: fold
        // into the protocol escrow on any failure rather than holding (gas-
        // capped so a pathological payout cannot consume the swap's gas).
        if (swapReferrer != address(0) && r > 0) {
            try IReferralPayoutForHook(cfg.referralPayout).notify{value: r, gas: SKIM_FORWARD_GAS}(
                swapReferrer
            ) {
                emit ReferralForwarded(pid, swapReferrer, r);
            } catch {
                feeEscrow.storeFeesNative{value: r}(cfg.protocolRecipient);
                emit ReferralFoldedToProtocol(pid, swapReferrer, r);
            }
        }
    }

    // ─── hook permissions ────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            // Enabled for the venue-scoped transfer tax: lets a tax-enabled pool
            // attest canonical LP removals so public LP exits aren't taxed.
            // Pure pass-through for every non-tax pool. Adds 1<<8 to the mined
            // hook-address flag bits (see SkimForkFixture.SKIM_HOOK_FLAGS).
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}

    /// @title  ArtCoinsHookSkimFee
    /// @notice Deployable concrete instance of the skim-fee hook.
    contract ArtCoinsHookSkimFee is ArtCoinsHookSkimFeeBase {
        constructor(
            address _poolManager,
            address _factory,
            address _poolExtensionAllowlist,
            address _weth,
            address _feeEscrow
        )
            ArtCoinsHookSkimFeeBase(
                _poolManager, _factory, _poolExtensionAllowlist, _weth, _feeEscrow
            )
        {}
    }
