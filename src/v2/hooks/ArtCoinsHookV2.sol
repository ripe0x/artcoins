// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsPoolExtension} from "../../hooks/interfaces/IArtCoinsPoolExtension.sol";
import {
    IArtCoinsPoolExtensionAllowlist
} from "../../hooks/interfaces/IArtCoinsPoolExtensionAllowlist.sol";
import {IPreSwapStream} from "../../interfaces/IPreSwapStream.sol";
import {IArtCoinsFeeEscrowV2} from "../interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "../interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsMevSkimV2} from "../interfaces/IArtCoinsMevSkimV2.sol";
import {IArtCoinsTokenV2} from "../interfaces/IArtCoinsTokenV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";
import {IReferralPayoutForHook} from "../interfaces/IReferralPayoutForHook.sol";
import {FeeDelivery} from "../libraries/FeeDelivery.sol";
import {HookCalldata} from "./libraries/HookCalldata.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
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

/// @title  ArtCoinsHookV2
/// @notice Skim fee hook for v2 art coin pools. Every pool is native eth
///         (currency0) against the art coin (currency1), created only by an
///         allowlisted launcher, with a fee config frozen at init.
///
///         Per swap, on the quote (eth) side:
///           totalSkim    = volume x currentSkimBps / 100_000
///           baselineSkim = totalSkim x baselineSkimBps / currentSkimBps
///           bounty       = baselineSkim x bountyBps / 10_000 + (totalSkim - baselineSkim)
///           protocol     = baselineSkim - baselineSkim x bountyBps / 10_000 - referral
///           referral     = min(volume x min(att.referralBps, maxReferral) / 100_000, protocol share)
///         Legs are pushed with a gas cap; a failed push credits the
///         recipient in the fee escrow (the only external dependency allowed
///         to revert a swap). The hook holds no erc6909 claims and no eth
///         between swaps.
///
///         Quote specified swaps (exact in buy, exact out sell) are charged in
///         `beforeSwap` on the requested amount, then trued up in `afterSwap`
///         on the realized fill: the unfilled share is refunded to the
///         PoolManager caller through the escrow (D11).
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
    /// @dev Gas for the pool extension's `afterSwap`. Below ~3m, so a caller
    ///      that starves the extension leaves too little gas to finish.
    uint256 private constant _EXTENSION_GAS = 2_000_000;

    /// @dev Transient: skim minted in `beforeSwap` on a quote specified swap.
    ///      keccak256("artcoins.hookV2.skim") (a literal: inline assembly
    ///      accepts number constants only).
    uint256 private constant _SKIM_SLOT =
        0x7aee84292610e1817940dfa3b53a7600205e6137c5ca860d9c51840e6feafea5;
    /// @dev Transient: `(amountToSwap << 32) | skimBps` for that swap.
    ///      keccak256("artcoins.hookV2.requested").
    uint256 private constant _REQ_SLOT =
        0x1ed2782058d87e2c0cc971c5cc47936f85ed6b62abd4c00f9ad4c24ce7f27f87;
    /// @dev Transient position marker tag (b1).
    bytes32 private constant _POS_TAG = keccak256("artcoins.hookV2.positionAdded");

    // ── storage ───────────────────────────────────────────────────────────

    mapping(PoolId => PoolInfo) internal _info;
    mapping(PoolId => SkimConfig) internal _skim;
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
        _globals = HookGlobals({
            pushGas: Constants.PUSH_GAS_DEFAULT,
            preSwapStreamGas: Constants.STREAM_GAS_DEFAULT,
            preSwapStreamMin: Constants.STREAM_MIN_BALANCE_DEFAULT,
            feeEscrow: escrow_,
            extensionAllowlist: allowlist_
        });
        emit FeeEscrowSet(address(0), escrow_);
        emit ExtensionAllowlistSet(address(0), allowlist_);
        emit DeliveryParamsSet(
            Constants.PUSH_GAS_DEFAULT,
            Constants.STREAM_GAS_DEFAULT,
            Constants.STREAM_MIN_BALANCE_DEFAULT
        );
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

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: p.tickSpacing,
            hooks: IHooks(address(this))
        });
        PoolId pid = key.toId();

        // the token must name this hook, this pool and this launcher; its
        // tax mode is mirrored into the frozen pool record.
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(token);
        if (
            t.canonicalHook() != address(this) || t.canonicalPoolId() != PoolId.unwrap(pid)
                || t.launcher() != msg.sender
        ) revert CanonicalHookMismatch();
        uint8 mode = t.taxMode();
        if (mode > Constants.TAX_MODE_HARD) revert CanonicalHookMismatch();

        if (ext != address(0)) {
            address al = _globals.extensionAllowlist;
            if (al == address(0) || !IArtCoinsPoolExtensionAllowlist(al).enabledExtensions(ext)) {
                revert ExtensionNotAllowed(ext);
            }
        }

        _info[pid] = PoolInfo({
            version: Constants.STACK_VERSION,
            taxMode: mode,
            createdAt: uint40(block.timestamp),
            launcher: msg.sender,
            token: token,
            locker: p.locker,
            mevModule: p.mevModule,
            extension: ext
        });
        _skim[pid] = p.skim;
        emit PoolInitializedV2(pid, token, msg.sender, Constants.STACK_VERSION, mode);
        emit SkimConfigInitialized(pid, p.skim);

        // art coin is always currency1, so the starting tick is negated.
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(-p.tickIfToken0IsArtCoin));
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

    /// @dev Anti sniper add lock (b7: ends at createdAt + MAX_MEV_WINDOW
    ///      whatever the module reports) and the same tx position marker (b1).
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata p,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId pid = key.toId();
        PoolInfo storage info = _info[pid];
        if (block.timestamp < uint256(info.createdAt) + Constants.MAX_MEV_WINDOW) {
            address module = info.mevModule;
            if (module != address(0) && _started[pid] && block.timestamp < _windowEnd(module, pid))
            {
                revert MevWindowActive();
            }
        }
        if (info.taxMode != Constants.TAX_MODE_NONE) {
            bytes32 slot = _positionSlot(pid, sender, p);
            assembly ("memory-safe") {
                tstore(slot, 1)
            }
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @dev HARD mode inflow allowance for the art coin the position takes in.
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId pid = key.toId();
        if (_info[pid].taxMode == Constants.TAX_MODE_HARD) {
            int256 a = delta.amount1();
            if (a < 0) {
                IArtCoinsTokenV2(Currency.unwrap(key.currency1))
                    .grantCanonicalFlow(PoolId.unwrap(pid), 0, uint256(-a));
            }
        }
        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @dev Exemption (VENUE) or outflow allowance (HARD) for the art coin a
    ///      removal or fee collect releases, only for positions that existed
    ///      before this tx (b1).
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata p,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId pid = key.toId();
        uint8 mode = _info[pid].taxMode;
        int256 a = delta.amount1();
        if (mode != Constants.TAX_MODE_NONE && a > 0) {
            bytes32 slot = _positionSlot(pid, sender, p);
            uint256 added;
            assembly ("memory-safe") {
                added := tload(slot)
            }
            if (added == 0) _tokenFlow(key, pid, mode, a);
        }
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId pid = key.toId();
        SkimConfig storage cfg = _skim[pid];
        _probeStream(cfg.bountyRecipient);

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
                poolManager.mint(address(this), key.currency0.toId(), s);
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
        uint256 volume;
        if (params.zeroForOne == exactIn) {
            // quote specified: true up the skim minted in beforeSwap (b3).
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
                // exact in buy: trader input; exact out sell: trader output.
                volume = exactIn ? r + skim : r - skim;
                poolManager.burn(address(this), key.currency0.toId(), charged);
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
            volume = r;
            ret = _i128(skim);
        }

        if (charged != 0) poolManager.take(key.currency0, address(this), charged);

        // tax mode hooks on the art coin side (the hook never changes it).
        {
            uint8 mode = _info[pid].taxMode;
            int256 a = delta.amount1();
            if (mode != Constants.TAX_MODE_NONE && a != 0) {
                if (a > 0) _tokenFlow(key, pid, mode, a);
                else if (mode == Constants.TAX_MODE_HARD) _tokenFlow(key, pid, mode, a);
            }
        }

        (bytes calldata ext, HookCalldata.Attribution memory att) = HookCalldata.decode(hookData);
        if (charged != 0) {
            address escrow = _globals.feeEscrow;
            if (skim != 0) _split(pid, sender, escrow, skim, bps, volume, att);
            uint256 over = charged - skim;
            if (over != 0) {
                IArtCoinsFeeEscrowV2(escrow).storeFeesNative{value: over}(sender);
                emit SkimRefunded(pid, sender, over);
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
        // H13: a contract that swaps directly cannot name itself. A self
        // referral through a second address remains possible; the per pool
        // cap (<= 1% of volume, <= the protocol share) bounds it.
        if (referrer != address(0) && referrer != sender) {
            uint256 cap = cfg.maxReferralBpsOfVolume;
            if (att.referralBps < cap) cap = att.referralBps;
            referral = (volume * cap) / Constants.SKIM_DENOMINATOR;
            if (referral > protocol) referral = protocol;
            protocol -= referral;
        }

        emit SkimSplit(pid, volume, bounty, protocol, referral);
        if (referrer != address(0) || att.sourceId != bytes32(0)) {
            emit SwapAttribution(
                pid, sender, referrer, att.sourceId, att.campaignId, volume, referral
            );
        }

        uint256 gasCap = _globals.pushGas;
        _leg(pid, Constants.LEG_BOUNTY, escrow, cfg.bountyRecipient, bounty, gasCap);
        _leg(pid, Constants.LEG_PROTOCOL, escrow, cfg.protocolRecipient, protocol, gasCap);
        if (referral != 0) {
            bool pushed = _notify(cfg.referralPayout, referrer, referral, gasCap);
            // D16: a failed notify credits the referrer, not the protocol.
            if (!pushed) IArtCoinsFeeEscrowV2(escrow).storeFeesNative{value: referral}(referrer);
            emit FeeDelivered(pid, Constants.LEG_REFERRAL, referrer, referral, !pushed);
        }
    }

    function _leg(PoolId pid, uint8 leg, address escrow, address to, uint256 amount, uint256 gasCap)
        private
    {
        if (amount == 0) return;
        bool pushed = FeeDelivery.sendNative(escrow, to, amount, gasCap);
        emit FeeDelivered(pid, leg, to, amount, !pushed);
    }

    /// @dev `referralPayout.notify{value, gas: gasCap}(referrer)`, returndata
    ///      never copied. The payout has code (checked at init).
    function _notify(address payout, address referrer, uint256 amount, uint256 gasCap)
        private
        returns (bool ok)
    {
        bytes4 sel = IReferralPayoutForHook.notify.selector;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, sel)
            mstore(add(m, 0x04), and(referrer, 0xffffffffffffffffffffffffffffffffffffffff))
            ok := call(gasCap, payout, amount, m, 0x24, codesize(), 0x00)
        }
    }

    /// @dev b2: optional `streamForward` on the bounty recipient. Low level,
    ///      gas capped, success and returndata ignored (no decode, no copy).
    function _probeStream(address r) private {
        HookGlobals storage g = _globals;
        if (r.balance < g.preSwapStreamMin || r.code.length == 0) return;
        uint256 gasCap = g.preSwapStreamGas;
        bytes4 sel = IPreSwapStream.streamForward.selector;
        assembly ("memory-safe") {
            mstore(0x00, sel)
            pop(call(gasCap, r, 0, 0x00, 0x04, codesize(), 0x00))
        }
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
            if and(staticcall(_MODULE_GAS, module, m, 0x24, m, 0x40), gt(returndatasize(), 0x3f)) {
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
            if and(staticcall(_MODULE_GAS, module, m, 0x24, m, 0x20), gt(returndatasize(), 0x1f)) {
                end := mload(m)
            }
        }
    }

    /// @dev d2 hook half. `a > 0`: art coin leaving the PoolManager (VENUE
    ///      attest, HARD out grant). `a < 0`: art coin entering (HARD in grant).
    function _tokenFlow(PoolKey calldata key, PoolId pid, uint8 mode, int256 a) private {
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(Currency.unwrap(key.currency1));
        if (mode == Constants.TAX_MODE_VENUE) {
            t.attestCanonicalBudget(PoolId.unwrap(pid), uint256(a));
        } else if (a > 0) {
            t.grantCanonicalFlow(PoolId.unwrap(pid), uint256(a), 0);
        } else {
            t.grantCanonicalFlow(PoolId.unwrap(pid), 0, uint256(-a));
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

    function _positionSlot(
        PoolId pid,
        address sender,
        IPoolManager.ModifyLiquidityParams calldata p
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(_POS_TAG, pid, sender, p.tickLower, p.tickUpper, p.salt));
    }

    function _i128(uint256 x) private pure returns (int128) {
        if (x > uint128(type(int128).max)) {
            revert ParamOutOfBounds(x, 0, uint128(type(int128).max));
        }
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
        // H3: the payout is called with a value; it must have code.
        if (s.referralPayout.code.length == 0) revert ReferralPayoutZero();
        if (s.quoteToken != address(0)) revert QuoteTokenMustBeNative();
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
    function setFeeEscrow(address escrow) external onlyOwner {
        _checkConstants(escrow);
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
    function setDeliveryParams(uint32 pushGas, uint32 streamGas, uint96 streamMin)
        external
        onlyOwner
    {
        if (pushGas < Constants.PUSH_GAS_MIN || pushGas > Constants.PUSH_GAS_MAX) {
            revert ParamOutOfBounds(pushGas, Constants.PUSH_GAS_MIN, Constants.PUSH_GAS_MAX);
        }
        if (streamGas < Constants.STREAM_GAS_MIN || streamGas > Constants.STREAM_GAS_MAX) {
            revert ParamOutOfBounds(streamGas, Constants.STREAM_GAS_MIN, Constants.STREAM_GAS_MAX);
        }
        if (streamMin > Constants.STREAM_MIN_BALANCE_MAX) {
            revert ParamOutOfBounds(streamMin, 0, Constants.STREAM_MIN_BALANCE_MAX);
        }
        HookGlobals storage g = _globals;
        g.pushGas = pushGas;
        g.preSwapStreamGas = streamGas;
        g.preSwapStreamMin = streamMin;
        emit DeliveryParamsSet(pushGas, streamGas, streamMin);
    }

    /// @inheritdoc IArtCoinsHookV2
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
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

    // ── reads ─────────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsHookV2
    function poolInfo(PoolId poolId) external view returns (PoolInfo memory) {
        return _info[poolId];
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

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    /// @inheritdoc BaseHook
    /// @dev DESIGN section 5, low 14 address bits 0x2DCC.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
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
