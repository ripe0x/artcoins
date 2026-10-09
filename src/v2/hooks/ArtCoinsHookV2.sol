// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsPoolExtension} from "../../hooks/interfaces/IArtCoinsPoolExtension.sol";
import {
    IArtCoinsPoolExtensionAllowlist
} from "../../hooks/interfaces/IArtCoinsPoolExtensionAllowlist.sol";
import {IArtCoinsFeeEscrowV2} from "../interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "../interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsMevSkimV2} from "../interfaces/IArtCoinsMevSkimV2.sol";
import {IArtCoinsTokenV2} from "../interfaces/IArtCoinsTokenV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";
import {FeeDelivery} from "../libraries/FeeDelivery.sol";
import {HookCalldata} from "./libraries/HookCalldata.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @dev Minimal reads of sibling stack contracts for the bounty recipient
///      reject set. The factory holds the token deployer; the locker holds the
///      PositionManager.
interface IFactoryTokenDeployer {
    function tokenDeployer() external view returns (address);
}

interface ILockerReads {
    function positionManager() external view returns (address);
    function feeEscrow() external view returns (address);
}

/// @title  ArtCoinsHookV2
/// @notice Skim fee hook for v2 art coin pools. Every pool is native eth
///         (currency0) against the art coin (currency1), created only by an
///         allowlisted launcher. The fee rates and caps are set once at init;
///         the coin admin may change the pool's bounty recipient afterwards.
///
///         Per swap, on the quote (eth) side, with `volume` the realized
///         pool side quote amount `r` for all four swap shapes (V2H-05):
///           totalSkim    = skim on the trader side (see the four shapes below)
///           baselineSkim = totalSkim x baselineSkimBps / currentSkimBps
///           bounty       = baselineSkim x bountyBps / 10_000 + (totalSkim - baselineSkim)
///           protocol     = baselineSkim - baselineSkim x bountyBps / 10_000 - referral
///           referral     = min(volume x min(att.referralBps, maxReferral) / 100_000,
///                              protocol share - baselineSkim x minProtocolShareBps / 10_000)  (D52, floored at 0)
///
///         No recipient code runs with useful gas while the PoolManager is
///         unlocked (D41): every leg (bounty, protocol, referral to the
///         referrer) is a plain eth push carrying only the EVM's 2,300 gas
///         stipend; a failed push credits the recipient in the fee escrow.
///         There is no `streamForward` probe. Contracts that need to react to
///         fees pull from the escrow or are poked by a keeper after the swap.
///         The hook holds no erc6909 claims and no eth between swaps.
///
///         Quote specified swaps (exact in buy, exact out sell) are charged in
///         `beforeSwap` on the requested amount, then trued up in `afterSwap`
///         on the realized fill. The unfilled share is credited in the fee
///         escrow to the refund address the swapper names in hookData
///         (`mevModuleSwapData = abi.encode(address)`), else to the
///         PoolManager caller. Why not inside the swap (D42, D51): v4 lets
///         `afterSwap` return a delta only on the UNSPECIFIED currency, and
///         for exactly these two shapes that is the art coin, so an eth
///         refund cannot ride the return delta. `settleFor(sender)` credits
///         the caller's transient delta but not the BalanceDelta `swap()`
///         returns, so routers that settle the returned delta (dev buy,
///         PoolSwapTest, many integrations) fail `CurrencyNotSettled`. The
///         escrow keeps returned and transient deltas equal for every router.
///         Known limit: on a partial exact out sell the caller's eth delta
///         can be negative until the refund is claimed (V2H-06); a router
///         that cannot claim (the universal router) must pass a refund
///         address or the refund stays under it (V2H-03).
///
///         Self referral through a router (referrer = the user's own wallet)
///         is accepted and bounded by the frozen per pool cap (<= 1% of
///         volume, <= the protocol share) (D44). The PoolManager caller itself
///         cannot be the referrer (H13).
///
/// @dev    Size: one contract, no delegate module (D14). Calldata parsing
///         lives in `HookCalldata` (internal, inlined).
///         Init: the PoolManager never calls `beforeInitialize` when the hook
///         itself initializes (Hooks.noSelfCall), so `_beforeInitialize`
///         reverts unconditionally. That is strictly stronger than a transient
///         "initializing" flag: the only init path is `initializePool`.
contract ArtCoinsHookV2 is BaseHook, Ownable2Step, IArtCoinsHookV2 {
    using PoolIdLibrary for PoolKey;

    // ── constants ─────────────────────────────────────────────────────────

    /// @dev Gas for the mev module view reads. The module is factory enabled
    ///      and does two storage reads; a failed read falls back to the
    ///      baseline skim and an open add lock (fail open, as v1). The cap is
    ///      far above the module's need, so a caller cannot starve the read
    ///      and still complete the swap (63/64 rule).
    uint256 private constant _MODULE_GAS = 100_000;
    /// @dev Gas forwarded on a fee push: 0, so the recipient runs on the EVM's
    ///      2,300 stipend only (D41). Passing 2,300 here would give it 4,600.
    ///      Under 2,300 a recipient cannot send value or write storage, so it
    ///      cannot `take`, `mint`, `burn` or `settle` on the PoolManager.
    uint256 private constant _PUSH_GAS = 0;
    /// @dev Gas for the pool extension's `afterSwap`. Below ~3m, so a caller
    ///      that starves the extension leaves too little gas to finish.
    uint256 private constant _EXTENSION_GAS = 2_000_000;

    /// @dev Transient: skim charged in `beforeSwap` on a quote specified swap.
    ///      keccak256("artcoins.hookV2.skim") (a literal: inline assembly
    ///      accepts number constants only).
    uint256 private constant _SKIM_SLOT =
        0x7aee84292610e1817940dfa3b53a7600205e6137c5ca860d9c51840e6feafea5;
    /// @dev Transient: `(amountToSwap << 32) | skimBps` for that swap.
    ///      keccak256("artcoins.hookV2.requested").
    uint256 private constant _REQ_SLOT =
        0x1ed2782058d87e2c0cc971c5cc47936f85ed6b62abd4c00f9ad4c24ce7f27f87;

    /// @dev The escrow passed to `setFeeEscrow` does not list this hook as a
    ///      core depositor, so a failed push could not fall back to it.
    error EscrowNotCoreDepositor(address escrow);
    /// @dev A bounty recipient the factory launch checks reject for this role:
    ///      the coin, this hook, the PoolManager, this hook's fee escrow, the
    ///      pool locker's fee escrow, the pool's mev module, the pool's locker,
    ///      the factory, its token deployer or the PositionManager.
    error RecipientCannotReceive(address recipient);
    /// @dev A reject-set lookup (token deployer, locker PositionManager or locker
    ///      fee escrow) reverted, so the recipient could not be verified. The
    ///      setter refuses the change rather than skip a check.
    error RecipientCheckFailed();
    /// @dev The caller is not the coin's current admin.
    error NotCoinAdmin();
    /// @dev The coin's recipients are frozen (the coin called `lockRecipients`
    ///      or renounced its admin).
    error RecipientsLocked();
    /// @dev `poolId` was not created by this hook.
    error UnknownPool();

    /// @dev The pool's protocol leg floor, BPS of the baseline skim, set at init.
    event ProtocolFloorInitialized(PoolId indexed poolId, uint16 minProtocolShareBps);
    /// @dev The coin admin changed the pool's bounty recipient.
    event BountyRecipientSet(
        PoolId indexed poolId, address indexed oldRecipient, address indexed newRecipient
    );

    // ── storage ───────────────────────────────────────────────────────────

    mapping(PoolId => PoolInfo) internal _info;
    mapping(PoolId => SkimConfig) internal _skim;
    /// @dev D52: per pool protocol leg floor, BPS of the baseline skim.
    mapping(PoolId => uint16) internal _minProtocolShareBps;
    /// @dev Set once by `initializeMevModule`: the window started and the
    ///      extension finished its post locker setup.
    mapping(PoolId => bool) internal _started;
    mapping(address => bool) internal _launchers;
    HookGlobals internal _globals;

    /// @param manager_   Uniswap v4 PoolManager.
    /// @param owner_     Owner (Ownable2Step).
    /// @param escrow_    Fee escrow; this hook must be one of its core depositors.
    /// @param allowlist_ Pool extension allowlist (0 disables extensions).
    constructor(IPoolManager manager_, address owner_, address escrow_, address allowlist_)
        BaseHook(manager_)
        Ownable(owner_)
    {
        _checkConstants(escrow_);
        _globals = HookGlobals({feeEscrow: escrow_, extensionAllowlist: allowlist_});
        emit FeeEscrowSet(address(0), escrow_);
        emit ExtensionAllowlistSet(address(0), allowlist_);
    }

    /// @notice Eth arrives only from the PoolManager (`take`) mid swap.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // ── launcher ──────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsHookV2
    function initializePool(PoolInitParams calldata p) external returns (PoolKey memory key) {
        if (!_launchers[msg.sender]) revert NotLauncher();
        address token = p.token;
        address ext = p.extension;
        if (token == address(0) || p.locker == address(0)) revert ZeroAddress();
        _checkConstants(p.locker);
        if (p.mevModule != address(0)) _checkConstants(p.mevModule);
        _validateSkim(p.skim);
        // D52: bounty plus the protocol floor fit inside the baseline skim.
        if (uint256(p.skim.bountyBps) + p.minProtocolShareBps > Constants.BPS) revert BadLegBps();

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: p.tickSpacing,
            hooks: IHooks(address(this))
        });
        PoolId pid = key.toId();

        // the token must name this hook, this pool and this launcher; its
        // restriction flag is mirrored into the frozen pool record.
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(token);
        if (
            t.canonicalHook() != address(this) || t.canonicalPoolId() != PoolId.unwrap(pid)
                || t.launcher() != msg.sender
        ) revert CanonicalHookMismatch();
        bool restricted = t.restricted();

        if (ext != address(0)) {
            address al = _globals.extensionAllowlist;
            if (al == address(0) || !IArtCoinsPoolExtensionAllowlist(al).enabledExtensions(ext)) {
                revert ExtensionNotAllowed(ext);
            }
        }

        _info[pid] = PoolInfo({
            version: Constants.STACK_VERSION,
            restricted: restricted,
            createdAt: uint40(block.timestamp),
            launcher: msg.sender,
            token: token,
            locker: p.locker,
            mevModule: p.mevModule,
            extension: ext
        });
        _skim[pid] = p.skim;
        _minProtocolShareBps[pid] = p.minProtocolShareBps;
        emit PoolInitializedV2(pid, token, msg.sender, Constants.STACK_VERSION, restricted);
        emit SkimConfigInitialized(pid, p.skim);
        emit ProtocolFloorInitialized(pid, p.minProtocolShareBps);

        // art coin is always currency1, so the starting tick is negated.
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(-p.tickIfToken0IsCoin));
        // the lp fee is frozen: set once here, never touched per swap.
        poolManager.updateDynamicLPFee(key, p.skim.lpFee);

        if (ext != address(0)) {
            IArtCoinsPoolExtension(ext).initializePreLockerSetup(key, false, p.extensionData);
        }
    }

    /// @inheritdoc IArtCoinsHookV2
    /// @dev `mevConfig` is `abi.encode(startingSkimBps, windowSeconds)` (empty
    ///      = Constants defaults). The hook appends the pool baseline as the
    ///      module's end value so the decay lands on the baseline.
    function initializeMevModule(PoolKey calldata poolKey, bytes calldata mevConfig) external {
        PoolId pid = poolKey.toId();
        PoolInfo storage info = _info[pid];
        if (msg.sender != info.launcher) revert NotLauncher();
        if (_started[pid]) revert MevModuleAlreadyInitialized();
        _started[pid] = true;

        address module = info.mevModule;
        if (module != address(0)) {
            uint256 start = Constants.DEFAULT_START_SKIM_BPS;
            uint256 window = Constants.DEFAULT_MEV_WINDOW;
            if (mevConfig.length != 0) (start, window) = abi.decode(mevConfig, (uint256, uint256));
            uint256 end = _skim[pid].baselineSkimBps;
            if (end > start) end = start;
            IArtCoinsMevSkimV2(module).initialize(pid, abi.encode(start, window, end));
            emit MevModuleInitialized(pid, module);
        }
        address ext = info.extension;
        if (ext != address(0)) {
            IArtCoinsPoolExtension(ext).initializePostLockerSetup(poolKey, info.locker, false);
        }
    }

    // ── v4 callbacks ──────────────────────────────────────────────────────

    /// @dev d3: no pool on this hook is created except through `initializePool`.
    function _beforeInitialize(address, PoolKey calldata, uint160)
        internal
        pure
        override
        returns (bytes4)
    {
        revert ForeignInitialize();
    }

    /// @dev Anti sniper add lock: ends at createdAt + MAX_MEV_WINDOW whatever
    ///      the module reports. On a restricted coin the token transfer rule
    ///      governs the coin leg of an add: a leg that settles coin to the
    ///      PoolManager needs an allowlisted side (the locker's placement) or it
    ///      reverts; an add that settles only eth needs no coin and passes.
    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        PoolId pid = key.toId();
        PoolInfo storage info = _info[pid];
        if (block.timestamp < uint256(info.createdAt) + Constants.MAX_MEV_WINDOW) {
            address module = info.mevModule;
            if (module != address(0) && _started[pid] && block.timestamp < _windowEnd(module, pid))
            {
                revert MevWindowActive();
            }
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId pid = key.toId();
        SkimConfig storage cfg = _skim[pid];

        bool exactIn = params.amountSpecified < 0;
        // quote (currency0) is specified iff zeroForOne == exactIn.
        if (params.zeroForOne == exactIn) {
            uint256 a = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 bps = _skimBps(pid, cfg.baselineSkimBps);
            uint256 s = exactIn
                ? (a * bps) / Constants.SKIM_DENOMINATOR
                : (a * bps) / (Constants.SKIM_DENOMINATOR - bps);
            if (s != 0) {
                uint256 packed = ((exactIn ? a - s : a + s) << 32) | bps;
                assembly ("memory-safe") {
                    tstore(_SKIM_SLOT, s)
                    tstore(_REQ_SLOT, packed)
                }
                // no erc6909 mint: the +s specified delta is booked to the
                // hook after `afterSwap` returns, where `take(s)` nets it.
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(_i128(s), 0), 0);
            }
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128 ret) {
        PoolId pid = key.toId();
        int256 q = delta.amount0();
        uint256 r = q < 0 ? uint256(-q) : uint256(q); // realized pool quote amount
        bool exactIn = params.amountSpecified < 0;

        uint256 charged; // eth the hook holds for this swap
        uint256 skim; // fair skim (charged minus refund)
        uint256 bps;
        if (params.zeroForOne == exactIn) {
            // quote specified: true up the skim charged in beforeSwap (b3).
            uint256 packed;
            assembly ("memory-safe") {
                charged := tload(_SKIM_SLOT)
                packed := tload(_REQ_SLOT)
                tstore(_SKIM_SLOT, 0)
                tstore(_REQ_SLOT, 0)
            }
            if (charged != 0) {
                uint256 requested = packed >> 32;
                bps = packed & 0xffffffff;
                skim = r >= requested ? charged : (charged * r) / requested;
            }
        } else {
            // quote unspecified: skim the realized quote side, returned as the
            // unspecified delta (exact in sell: from the output; exact out
            // buy: on top of the input).
            bps = _skimBps(pid, _skim[pid].baselineSkimBps);
            skim = exactIn
                ? (r * bps) / Constants.SKIM_DENOMINATOR
                : (r * bps) / (Constants.SKIM_DENOMINATOR - bps);
            charged = skim;
            ret = _i128(skim);
        }

        if (charged != 0) poolManager.take(key.currency0, address(this), charged);

        // restriction: grant the coin side of this swap as a PoolManager
        // transfer allowance so the trader's settle or take passes the token
        // transfer rule. The hook moves no coin itself; the only coin move is
        // the swap's own currency1 delta between the PoolManager and the trader.
        if (_info[pid].restricted) {
            int256 a = delta.amount1();
            uint256 amt = a < 0 ? uint256(-a) : uint256(a);
            if (amt != 0) {
                IArtCoinsTokenV2(Currency.unwrap(key.currency1))
                    .increaseTransferAllowance(PoolId.unwrap(pid), amt);
            }
        }

        (bytes calldata ext, HookCalldata.Attribution memory att) = HookCalldata.decode(hookData);
        if (charged != 0) {
            address escrow = _globals.feeEscrow;
            uint256 over = charged - skim;
            if (over != 0) {
                // b3: the unfilled share goes to the escrow, credited to the
                // hookData refund address or else the PoolManager caller.
                // D42/D51 (refund inside the swap) cannot be done without
                // breaking routers: see the contract natspec.
                address to = HookCalldata.refundTo(hookData);
                if (to == address(0)) to = sender;
                IArtCoinsFeeEscrowV2(escrow).storeFeesNative{value: over}(to);
                emit SkimRefunded(pid, to, over);
            }
            if (skim != 0) {
                address synced =
                    Currency.unwrap(TransientStateLibrary.getSyncedCurrency(poolManager));
                _split(pid, sender, escrow, skim, bps, r, att);
                // a 2,300 gas recipient can still reach `sync`; undo it so a
                // router that settles native without syncing is not broken.
                if (
                    synced == address(0)
                        && Currency.unwrap(TransientStateLibrary.getSyncedCurrency(poolManager))
                            != address(0)
                ) poolManager.sync(Currency.wrap(address(0)));
            }
        }

        _runExtension(
            key, pid, sender, params, toBalanceDelta(int128(q - int256(skim)), delta.amount1()), ext
        );
        return (BaseHook.afterSwap.selector, ret);
    }

    // ── internals: swap ───────────────────────────────────────────────────

    /// @dev Splits `skim` into the three legs and delivers each one.
    function _split(
        PoolId pid,
        address sender,
        address escrow,
        uint256 skim,
        uint256 bps,
        uint256 volume,
        HookCalldata.Attribution memory att
    ) private {
        SkimConfig storage cfg = _skim[pid];
        // bps >= baseline (clamped), so base <= skim.
        uint256 base = (skim * cfg.baselineSkimBps) / bps;
        uint256 bountyShare = (base * cfg.bountyBps) / Constants.BPS;
        uint256 protocol = base - bountyShare;
        uint256 bounty = bountyShare + (skim - base);

        uint256 referral;
        address referrer = att.referrer;
        // H13: the PoolManager caller cannot name itself. D44: a router user
        // naming its own wallet is accepted, bounded by the frozen per pool
        // cap (<= 1% of volume, <= the protocol share above its floor).
        if (referrer != address(0) && referrer != sender) {
            uint256 cap = cfg.maxReferralBpsOfVolume;
            if (att.referralBps < cap) cap = att.referralBps;
            referral = (volume * cap) / Constants.SKIM_DENOMINATOR;
            // D52: never below the pool's protocol floor (BPS of the baseline
            // skim, the factory's unit for `minProtocolSkimShareBps`).
            uint256 floor = (base * _minProtocolShareBps[pid]) / Constants.BPS;
            uint256 room = protocol > floor ? protocol - floor : 0;
            if (referral > room) referral = room;
            protocol -= referral;
        }

        emit SkimSplit(pid, volume, bounty, protocol, referral);
        if (referrer != address(0) || att.sourceId != bytes32(0)) {
            emit SwapAttribution(
                pid, sender, referrer, att.sourceId, att.campaignId, volume, referral
            );
        }

        _leg(pid, Constants.LEG_BOUNTY, escrow, cfg.bountyRecipient, bounty);
        _leg(pid, Constants.LEG_PROTOCOL, escrow, cfg.protocolRecipient, protocol);
        // the referral is pushed to the referrer like the other legs: a zero gas
        // call, credited in the escrow on failure.
        _leg(pid, Constants.LEG_REFERRAL, escrow, referrer, referral);
    }

    function _leg(PoolId pid, uint8 leg, address escrow, address to, uint256 amount) private {
        if (amount == 0) return;
        bool pushed = FeeDelivery.sendNative(escrow, to, amount, _PUSH_GAS);
        emit FeeDelivered(pid, leg, to, amount, !pushed);
    }

    /// @dev Current skim in SKIM_DENOMINATOR units: the module's value while
    ///      it reports active, clamped to [baseline, MAX_SKIM_BPS]; the
    ///      baseline once `createdAt + MAX_MEV_WINDOW` passed (b7) or on any
    ///      module failure.
    function _skimBps(PoolId pid, uint256 baseline) private view returns (uint256 bps) {
        bps = baseline;
        PoolInfo storage info = _info[pid];
        if (block.timestamp >= uint256(info.createdAt) + Constants.MAX_MEV_WINDOW) return bps;
        address module = info.mevModule;
        if (module == address(0)) return bps;
        bytes4 sel = IArtCoinsMevSkimV2.currentSkimBps.selector;
        uint256 v;
        uint256 active;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, sel)
            mstore(add(m, 0x04), pid)
            // yul evaluates arguments right to left: bind the call result
            // first so returndatasize() reads this call, not the previous one.
            let ok := staticcall(_MODULE_GAS, module, m, 0x24, m, 0x40)
            if and(ok, gt(returndatasize(), 0x3f)) {
                v := mload(m)
                active := mload(add(m, 0x20))
            }
        }
        if (active != 0 && v > bps) bps = v > Constants.MAX_SKIM_BPS ? Constants.MAX_SKIM_BPS : v;
    }

    /// @dev Module `windowEnd`; 0 (no lock) on failure.
    function _windowEnd(address module, PoolId pid) private view returns (uint256 end) {
        bytes4 sel = IArtCoinsMevSkimV2.windowEnd.selector;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, sel)
            mstore(add(m, 0x04), pid)
            let ok := staticcall(_MODULE_GAS, module, m, 0x24, m, 0x20)
            if and(ok, gt(returndatasize(), 0x1f)) {
                end := mload(m)
            }
        }
    }

    /// @dev Pool extension `afterSwap` with the trader facing realized delta
    ///      (fixes N2), gas capped, failure and returndata ignored. Runs last.
    function _runExtension(
        PoolKey calldata key,
        PoolId pid,
        address sender,
        IPoolManager.SwapParams calldata params,
        BalanceDelta traderDelta,
        bytes calldata extData
    ) private {
        PoolInfo storage info = _info[pid];
        address ext = info.extension;
        if (ext == address(0) || !_started[pid] || sender == info.locker) return;
        bytes memory cd = abi.encodeCall(
            IArtCoinsPoolExtension.afterSwap, (key, params, traderDelta, false, extData)
        );
        assembly ("memory-safe") {
            pop(call(_EXTENSION_GAS, ext, 0, add(cd, 0x20), mload(cd), codesize(), 0x00))
        }
    }

    function _i128(uint256 x) private pure returns (int128) {
        if (x > uint128(type(int128).max)) revert SkimExceedsInt128(x);
        return int128(int256(x));
    }

    // ── internals: config ─────────────────────────────────────────────────

    function _validateSkim(SkimConfig calldata s) private view {
        if (s.lpFee > Constants.MAX_LP_FEE) revert LpFeeTooHigh();
        if (s.baselineSkimBps > Constants.MAX_BASELINE_SKIM_BPS) revert BaselineSkimBpsTooHigh();
        if (s.bountyBps > Constants.MAX_BOUNTY_BPS) revert BadLegBps();
        if (s.maxReferralBpsOfVolume > Constants.MAX_REFERRAL_CAP_OF_VOLUME) {
            revert MaxReferralTooHigh();
        }
        if (s.bountyRecipient == address(0)) revert BountyRecipientZero();
        if (s.protocolRecipient == address(0)) revert ProtocolRecipientZero();
        _checkReceiver(s.bountyRecipient);
        _checkReceiver(s.protocolRecipient);
    }

    function _checkReceiver(address r) private view {
        if (r == address(this) || r == address(poolManager)) revert RecipientCannotReceive(r);
    }

    /// @dev d5: `target.constantsHash()` must equal this build's hash.
    function _checkConstants(address target) private view {
        if (target == address(0)) revert ZeroAddress();
        (bool ok, bytes memory ret) =
            target.staticcall(abi.encodeCall(IConstantsBound.constantsHash, ()));
        if (!ok || ret.length != 32 || abi.decode(ret, (bytes32)) != Constants.hash()) {
            revert ConstantsMismatch(target);
        }
    }

    // ── owner ─────────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsHookV2
    function setLauncher(address launcher, bool enabled) external onlyOwner {
        if (launcher == address(0)) revert ZeroAddress();
        _launchers[launcher] = enabled;
        emit LauncherSet(launcher, enabled);
    }

    /// @inheritdoc IArtCoinsHookV2
    /// @dev The new escrow must already list this hook as a core depositor:
    ///      every failed push lands there, so a wrong pointer would revert
    ///      swaps.
    function setFeeEscrow(address escrow) external onlyOwner {
        _checkConstants(escrow);
        if (!IArtCoinsFeeEscrowV2(escrow).isCoreDepositor(address(this))) {
            revert EscrowNotCoreDepositor(escrow);
        }
        emit FeeEscrowSet(_globals.feeEscrow, escrow);
        _globals.feeEscrow = escrow;
    }

    /// @inheritdoc IArtCoinsHookV2
    /// @dev 0 disables extensions for pools created from now on.
    function setExtensionAllowlist(address allowlist) external onlyOwner {
        emit ExtensionAllowlistSet(_globals.extensionAllowlist, allowlist);
        _globals.extensionAllowlist = allowlist;
    }

    /// @inheritdoc IArtCoinsHookV2
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
        emit Rescued(token, to, amount);
    }

    /// @inheritdoc IArtCoinsHookV2
    function rescueClaims(Currency currency, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        poolManager.transfer(to, currency.toId(), amount);
        emit ClaimsRescued(currency, to, amount);
    }

    // ── coin admin ──────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsHookV2
    /// @dev The coin is the pool's currency1. The caller must be its current
    ///      admin (`IArtCoinsTokenV2(coin).admin()`). The call reverts for every
    ///      caller once the admin is 0, which is how `lockRecipients` and
    ///      renouncing the admin freeze it. `newRecipient` must be nonzero and
    ///      must not be one of the stack contracts that cannot hold a fee: the
    ///      coin, this hook, the PoolManager, the fee escrow, the pool's mev
    ///      module, the pool's locker, the factory, its token deployer or the
    ///      PositionManager. The launch extensions are not stored, so the admin
    ///      must not set an extension here: an extension cannot claim its credit.
    function setBountyRecipient(PoolId poolId, address payable newRecipient) external {
        PoolInfo storage info = _info[poolId];
        address coin = info.token;
        if (coin == address(0)) revert UnknownPool();
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin);
        if (msg.sender != t.admin()) revert NotCoinAdmin();
        if (t.recipientsLocked()) revert RecipientsLocked();
        if (newRecipient == address(0)) revert BountyRecipientZero();
        _rejectKnownStackContract(coin, info.locker, info.mevModule, newRecipient);
        address old = _skim[poolId].bountyRecipient;
        _skim[poolId].bountyRecipient = newRecipient;
        emit BountyRecipientSet(poolId, old, newRecipient);
    }

    /// @dev Reverts `RecipientCannotReceive` when `r` is a stack contract that
    ///      cannot hold a fee. Resolves the factory from the coin, the token
    ///      deployer from the factory and the PositionManager from the locker;
    ///      an unreachable read is skipped.
    function _rejectKnownStackContract(address coin, address locker, address mevModule, address r)
        private
        view
    {
        if (
            r == coin || r == address(this) || r == address(poolManager) || r == _globals.feeEscrow
                || r == mevModule || r == locker
        ) revert RecipientCannotReceive(r);
        address factory = IArtCoinsTokenV2(coin).launcher();
        if (r == factory) revert RecipientCannotReceive(r);
        // fail closed: a lookup that cannot be read refuses the change.
        try IFactoryTokenDeployer(factory).tokenDeployer() returns (address dep) {
            if (r == dep) revert RecipientCannotReceive(r);
        } catch {
            revert RecipientCheckFailed();
        }
        try ILockerReads(locker).positionManager() returns (address posm) {
            if (r == posm) revert RecipientCannotReceive(r);
        } catch {
            revert RecipientCheckFailed();
        }
        // the locker's escrow may differ from this hook's; reject it too.
        try ILockerReads(locker).feeEscrow() returns (address esc) {
            if (r == esc) revert RecipientCannotReceive(r);
        } catch {
            revert RecipientCheckFailed();
        }
    }

    // ── reads ─────────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsHookV2
    function poolInfo(PoolId poolId) external view returns (PoolInfo memory) {
        return _info[poolId];
    }

    /// @notice D52 protocol leg floor of a pool (BPS of the baseline skim).
    function minProtocolShareBps(PoolId poolId) external view returns (uint16) {
        return _minProtocolShareBps[poolId];
    }

    /// @inheritdoc IArtCoinsHookV2
    function isOfficialPool(PoolId poolId) external view returns (bool) {
        return _info[poolId].launcher != address(0);
    }

    /// @inheritdoc IArtCoinsHookV2
    function skimConfig(PoolId poolId) external view returns (SkimConfig memory) {
        return _skim[poolId];
    }

    /// @inheritdoc IArtCoinsHookV2
    function globals() external view returns (HookGlobals memory) {
        return _globals;
    }

    /// @inheritdoc IArtCoinsHookV2
    function isLauncher(address launcher) external view returns (bool) {
        return _launchers[launcher];
    }

    /// @inheritdoc IArtCoinsHookV2
    uint16 public constant STACK_VERSION = Constants.STACK_VERSION;

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    /// @inheritdoc BaseHook
    /// @dev DESIGN section 5, low 14 address bits 0x28CC. Liquidity needs only
    ///      `beforeAddLiquidity` for the anti sniper window; the restriction
    ///      allowance is granted in `afterSwap`, so the add and remove liquidity
    ///      callbacks are not used.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
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
