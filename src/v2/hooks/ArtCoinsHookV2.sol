// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsPoolExtension} from "../../hooks/interfaces/IArtCoinsPoolExtension.sol";
import {
    IArtCoinsPoolExtensionAllowlist
} from "../../hooks/interfaces/IArtCoinsPoolExtensionAllowlist.sol";
import {IArtCoinsFactoryV2} from "../interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsFeeEscrowV2} from "../interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "../interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsMevSkimV2} from "../interfaces/IArtCoinsMevSkimV2.sol";
import {IArtCoinsTokenV2} from "../interfaces/IArtCoinsTokenV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";
import {IFactoryTokenDeployer} from "../interfaces/IFactoryTokenDeployer.sol";
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

/// @dev Locker read used by the bounty recipient reject set.
interface ILockerReads {
    /// @notice The locker's PositionManager.
    function positionManager() external view returns (address);
}

/// @title  ArtCoinsHookV2
/// @notice Uniswap v4 hook that charges a skim on the eth side of every swap in a v2 coin pool.
/// @dev    Pool: native eth (currency0) against the coin (currency1), lp fee 0.
///         The skim is the pool's only fee. Its rate is the pool baseline, or
///         the pool mev module's decaying rate while the anti sniper window is
///         open, capped at MAX_SKIM_BPS. The window ends no later than
///         `createdAt + MAX_MEV_WINDOW`.
///
///         Split, with `volume` the realized eth side amount:
///           baselineSkim  = totalSkim * baselineSkimBps / currentSkimBps
///           bountyShare   = baselineSkim * bountyBps / BPS
///           bounty        = bountyShare + (totalSkim - baselineSkim)
///           protocolShare = baselineSkim - bountyShare
///           referral      = min(volume * pool referralBps / BPS, protocolShare)
///           protocol      = protocolShare - referral
///         The referral is paid only when the pool's `referralBps` is nonzero and
///         `hookData` names a referrer other than the PoolManager caller. Each leg is an eth push with the 2,300 gas
///         stipend, and a failed push credits the recipient in the fee escrow.
///
///         Authority: allowlisted launchers create pools. The owner sets
///         launchers, fee escrow and extension allowlist. The coin admin sets the
///         pool's bounty recipient, extension and referral rate and lowers its
///         baseline skim, until the coin is locked or the admin is 0. Swaps are
///         permissionless.
contract ArtCoinsHookV2 is BaseHook, Ownable2Step, IArtCoinsHookV2 {
    using PoolIdLibrary for PoolKey;

    // ── constants ─────────────────────────────────────────────────────────

    /// @dev Gas cap for mev module view calls, far above what the module needs.
    ///      Under the 63/64 rule a caller that starves the call cannot finish the
    ///      swap, so a failed call yields the baseline skim and no add lock only
    ///      when the module itself fails.
    uint256 private constant _MODULE_GAS = 100_000;
    /// @dev Gas argument of a fee push. A value call adds the 2,300 stipend, so
    ///      the recipient runs on 2,300 gas. That is too little to send value or
    ///      write storage, so it cannot `take`, `mint`, `burn` or `settle` on the
    ///      PoolManager.
    uint256 private constant _PUSH_GAS = 0;
    /// @dev Gas cap for the pool extension's `afterSwap`. A caller that gives the
    ///      call less than the cap keeps under 1/64 of it for the rest of the swap.
    uint256 private constant _EXTENSION_GAS = 2_000_000;

    /// @dev Transient: skim charged in `beforeSwap` on a quote specified swap.
    ///      keccak256("artcoins.hookV2.skim"), written as a literal because
    ///      inline assembly accepts number constants only.
    uint256 private constant _SKIM_SLOT =
        0x7aee84292610e1817940dfa3b53a7600205e6137c5ca860d9c51840e6feafea5;
    /// @dev Transient: `(amountToSwap << 32) | skimBps` of that swap.
    ///      keccak256("artcoins.hookV2.requested").
    uint256 private constant _REQ_SLOT =
        0x1ed2782058d87e2c0cc971c5cc47936f85ed6b62abd4c00f9ad4c24ce7f27f87;

    // ── storage ───────────────────────────────────────────────────────────

    mapping(PoolId => PoolInfo) internal _info;
    mapping(PoolId => SkimConfig) internal _skim;
    /// @dev Set by `initializeMevModule`, which starts the anti sniper window
    ///      and runs the extension's post locker setup.
    mapping(PoolId => bool) internal _started;
    mapping(address => bool) internal _launchers;
    HookGlobals internal _globals;

    /// @inheritdoc IArtCoinsHookV2
    mapping(address => bool) public everFeeEscrow;

    /// @param manager_   Uniswap v4 PoolManager.
    /// @param owner_     Owner (Ownable2Step).
    /// @param escrow_    Fee escrow. This hook must be a core depositor of it.
    /// @param allowlist_ Pool extension allowlist (0 disables extensions).
    constructor(IPoolManager manager_, address owner_, address escrow_, address allowlist_)
        BaseHook(manager_)
        Ownable(owner_)
    {
        _checkConstants(escrow_);
        _globals = HookGlobals({feeEscrow: escrow_, extensionAllowlist: allowlist_});
        everFeeEscrow[escrow_] = true;
        emit FeeEscrowSet(address(0), escrow_);
        emit ExtensionAllowlistSet(address(0), allowlist_);
    }

    /// @notice Accepts eth from the PoolManager (`take` during a swap).
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
        if (!IArtCoinsFeeEscrowV2(_globals.feeEscrow).isCoreDepositor(address(this))) {
            revert EscrowNotCoreDepositor(_globals.feeEscrow);
        }

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: p.tickSpacing,
            hooks: IHooks(address(this))
        });
        PoolId pid = key.toId();

        // The coin must name this hook, this pool id and this launcher. Its
        // restriction flag is copied into the pool record.
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
        emit PoolInitializedV2(
            pid,
            token,
            msg.sender,
            Constants.STACK_VERSION,
            restricted,
            p.locker,
            p.mevModule,
            ext,
            p.tickSpacing
        );
        emit SkimConfigInitialized(pid, p.skim);

        // The coin is currency1, so the starting tick is negated. The dynamic
        // lp fee stays at its initial 0.
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(-p.tickIfToken0IsCoin));

        if (ext != address(0)) {
            IArtCoinsPoolExtension(ext).initializePreLockerSetup(key, false, p.extensionData);
        }
    }

    /// @inheritdoc IArtCoinsHookV2
    /// @dev `mevConfig` is `abi.encode(startingSkimBps, windowSeconds)`, or empty
    ///      for the Constants defaults. The hook passes the module the pool
    ///      baseline, capped at the starting value, as the end value.
    function initializeMevModule(PoolKey calldata poolKey, bytes calldata mevConfig) external {
        PoolId pid = poolKey.toId();
        PoolInfo storage info = _info[pid];
        if (msg.sender != info.launcher) revert NotLauncher();
        if (_started[pid]) revert MevModuleAlreadyInitialized();
        _started[pid] = true;
        emit PoolStarted(pid);

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

    /// @dev Reverts for every caller. Pools are initialized by `initializePool`,
    ///      and the PoolManager skips this callback when the hook is the
    ///      initializer.
    function _beforeInitialize(address, PoolKey calldata, uint160)
        internal
        pure
        override
        returns (bytes4)
    {
        revert ForeignInitialize();
    }

    /// @dev Reverts while the anti sniper window is open, from
    ///      `initializeMevModule` until the module's `windowEnd` and never past
    ///      `createdAt + MAX_MEV_WINDOW`. On a restricted coin the coin's
    ///      transfer rule applies to the coin leg of an add.
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

    /// @dev Quote specified swaps are charged here on the requested amount and
    ///      trued up in `afterSwap` on the realized fill. The over charge is
    ///      credited in the fee escrow to the refund address in `hookData`. A
    ///      partial fill without one reverts in `afterSwap`.
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
            uint256 s = exactIn ? (a * bps) / Constants.BPS : (a * bps) / (Constants.BPS - bps);
            if (s != 0) {
                uint256 packed = ((exactIn ? a - s : a + s) << 32) | bps;
                assembly ("memory-safe") {
                    tstore(_SKIM_SLOT, s)
                    tstore(_REQ_SLOT, packed)
                }
                // The +s specified delta is booked to the hook after
                // `afterSwap` returns. `take(s)` in `afterSwap` nets it.
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(_i128(s), 0), 0);
            }
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev A quote specified swap that fills partially reverts
    ///      `RefundAddressRequired` unless `hookData` carries a refund address,
    ///      which is credited the over charge in the fee escrow.
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
        uint256 skim; // skim kept after the refund
        uint256 bps;
        if (params.zeroForOne == exactIn) {
            // Quote specified: true up the skim charged in `beforeSwap`.
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
            // Quote unspecified: skim the realized quote amount, returned as
            // the unspecified delta (exact in sell: from the output, exact
            // out buy: on top of the input).
            bps = _skimBps(pid, _skim[pid].baselineSkimBps);
            skim = exactIn ? (r * bps) / Constants.BPS : (r * bps) / (Constants.BPS - bps);
            charged = skim;
            ret = _i128(skim);
        }

        if (charged != 0) poolManager.take(key.currency0, address(this), charged);

        // Restricted coin: grant the coin leg of the swap as a PoolManager
        // transfer allowance so the trader's settle or take passes the coin's
        // transfer rule.
        if (_info[pid].restricted) {
            int256 a = delta.amount1();
            uint256 amt = a < 0 ? uint256(-a) : uint256(a);
            if (amt != 0) {
                IArtCoinsTokenV2(Currency.unwrap(key.currency1))
                    .increaseTransferAllowance(PoolId.unwrap(pid), amt);
            }
        }

        (bytes calldata ext, address referrer) = HookCalldata.decode(hookData);
        if (charged != 0) {
            address escrow = _globals.feeEscrow;
            uint256 over = charged - skim;
            if (over != 0) {
                address to = HookCalldata.refundTo(hookData);
                if (to == address(0)) revert RefundAddressRequired();
                IArtCoinsFeeEscrowV2(escrow).storeFeesNative{value: over}(to);
                emit SkimRefunded(pid, to, over);
            }
            if (skim != 0) {
                address synced =
                    Currency.unwrap(TransientStateLibrary.getSyncedCurrency(poolManager));
                _split(pid, sender, escrow, skim, bps, r, referrer);
                // A recipient can call `sync` during the push. Reset it to
                // native so a router that settles eth without syncing works.
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

    /// @dev Splits `skim` into bounty, protocol and referral legs and delivers
    ///      each. `bps` is the rate `skim` was charged at.
    function _split(
        PoolId pid,
        address sender,
        address escrow,
        uint256 skim,
        uint256 bps,
        uint256 volume,
        address referrer
    ) private {
        SkimConfig storage cfg = _skim[pid];
        // bps is at least the baseline, so base <= skim.
        uint256 base = (skim * cfg.baselineSkimBps) / bps;
        uint256 bountyShare = (base * cfg.bountyBps) / Constants.BPS;
        uint256 protocol = base - bountyShare;
        uint256 bounty = bountyShare + (skim - base);

        uint256 referral;
        // The PoolManager caller cannot be the referrer. A router user naming
        // its own wallet is paid up to the pool's rate, out of the protocol leg.
        if (referrer != address(0) && referrer != sender) {
            referral = (volume * cfg.referralBps) / Constants.BPS;
            if (referral > protocol) referral = protocol;
            protocol -= referral;
        }

        emit SkimSplit(pid, volume, bounty, protocol, referral);
        if (referrer != address(0)) emit SwapAttribution(pid, sender, referrer, volume, referral);

        _leg(pid, Constants.LEG_BOUNTY, escrow, cfg.bountyRecipient, bounty);
        _leg(pid, Constants.LEG_PROTOCOL, escrow, cfg.protocolRecipient, protocol);
        _leg(pid, Constants.LEG_REFERRAL, escrow, referrer, referral);
    }

    /// @dev Pushes `amount` to `to` and credits `to` in the fee escrow when the
    ///      push fails.
    function _leg(PoolId pid, uint8 leg, address escrow, address to, uint256 amount) private {
        if (amount == 0) return;
        bool pushed = FeeDelivery.sendNative(escrow, to, amount, _PUSH_GAS);
        emit FeeDelivered(pid, leg, to, amount, !pushed);
    }

    /// @dev Skim rate in bps: the module's value while it reports active,
    ///      clamped to [baseline, MAX_SKIM_BPS]. The baseline applies after
    ///      `createdAt + MAX_MEV_WINDOW`, without a module, and when the module
    ///      call fails.
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

    /// @dev Module `windowEnd`, or 0 (no lock) when the call fails.
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

    /// @dev Calls the pool extension's `afterSwap` with the trader's realized
    ///      delta, gas capped, failure and returndata ignored. Skipped before
    ///      `initializeMevModule` and when the sender is the pool locker.
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
        if (s.baselineSkimBps == 0 || s.baselineSkimBps > Constants.MAX_BASELINE_SKIM_BPS) {
            revert BaselineSkimOutOfBounds(s.baselineSkimBps);
        }
        if (s.bountyBps > Constants.MAX_BOUNTY_BPS) revert BountyBpsTooHigh();
        if (s.referralBps > Constants.MAX_REFERRAL_CAP_OF_VOLUME) {
            revert ReferralBpsTooHigh(s.referralBps, Constants.MAX_REFERRAL_CAP_OF_VOLUME);
        }
        if (s.bountyRecipient == address(0)) revert BountyRecipientZero();
        if (s.protocolRecipient == address(0)) revert ProtocolRecipientZero();
        _checkReceiver(s.bountyRecipient);
        _checkReceiver(s.protocolRecipient);
    }

    function _checkReceiver(address r) private view {
        if (r == address(this) || r == address(poolManager)) revert RecipientCannotReceive(r);
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

    /// @inheritdoc IArtCoinsHookV2
    function setLauncher(address launcher, bool enabled) external onlyOwner {
        if (launcher == address(0)) revert ZeroAddress();
        _launchers[launcher] = enabled;
        emit LauncherSet(launcher, enabled);
    }

    /// @inheritdoc IArtCoinsHookV2
    /// @dev The new escrow must list this hook as a core depositor. Failed pushes
    ///      and refunds are credited there, so any other escrow would revert
    ///      swaps.
    function setFeeEscrow(address escrow) external onlyOwner {
        _checkConstants(escrow);
        if (!IArtCoinsFeeEscrowV2(escrow).isCoreDepositor(address(this))) {
            revert EscrowNotCoreDepositor(escrow);
        }
        emit FeeEscrowSet(_globals.feeEscrow, escrow);
        _globals.feeEscrow = escrow;
        everFeeEscrow[escrow] = true;
    }

    /// @inheritdoc IArtCoinsHookV2
    /// @dev 0 rejects every nonzero extension in `initializePool` and
    ///      `setPoolExtension`.
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
    /// @dev The caller is the coin's current `admin()` and the coin is not
    ///      `locked()`. `newRecipient` is nonzero and not in the set listed at
    ///      `RecipientCannotReceive`, which includes the pool extension and every
    ///      factory-enabled launch extension.
    function setBountyRecipient(PoolId poolId, address payable newRecipient) external {
        PoolInfo storage info = _info[poolId];
        address coin = info.token;
        if (coin == address(0)) revert UnknownPool();
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin);
        if (msg.sender != t.admin()) revert NotCoinAdmin();
        if (t.locked()) revert CoinLocked();
        if (newRecipient == address(0)) revert BountyRecipientZero();
        _rejectKnownStackContract(coin, info.locker, info.mevModule, info.extension, newRecipient);
        address old = _skim[poolId].bountyRecipient;
        _skim[poolId].bountyRecipient = newRecipient;
        emit BountyRecipientSet(poolId, old, newRecipient);
    }

    /// @inheritdoc IArtCoinsHookV2
    function setReferralBps(PoolId poolId, uint24 bps) external {
        address coin = _info[poolId].token;
        if (coin == address(0)) revert UnknownPool();
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin);
        if (msg.sender != t.admin()) revert NotCoinAdmin();
        if (t.locked()) revert CoinLocked();
        if (bps > Constants.MAX_REFERRAL_CAP_OF_VOLUME) {
            revert ReferralBpsTooHigh(bps, Constants.MAX_REFERRAL_CAP_OF_VOLUME);
        }
        SkimConfig storage cfg = _skim[poolId];
        uint24 old = cfg.referralBps;
        cfg.referralBps = bps;
        emit ReferralBpsSet(poolId, old, bps);
    }

    /// @inheritdoc IArtCoinsHookV2
    function lowerBaselineSkim(PoolId poolId, uint24 bps) external {
        PoolInfo storage info = _info[poolId];
        address coin = info.token;
        if (coin == address(0)) revert UnknownPool();
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin);
        if (msg.sender != t.admin()) revert NotCoinAdmin();
        if (t.locked()) revert CoinLocked();
        SkimConfig storage cfg = _skim[poolId];
        uint24 old = cfg.baselineSkimBps;
        // The skim is the pool's only fee, so the baseline stays above zero.
        if (bps == 0 || bps >= old) revert SkimNotLower(old, bps);
        cfg.baselineSkimBps = bps;
        emit BaselineSkimLowered(poolId, old, bps);
    }

    /// @inheritdoc IArtCoinsHookV2
    function setPoolExtension(PoolKey calldata key, address newExtension, bytes calldata initData)
        external
    {
        PoolId poolId = key.toId();
        PoolInfo storage info = _info[poolId];
        address coin = info.token;
        if (coin == address(0)) revert UnknownPool();
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(coin);
        if (msg.sender != t.admin()) revert NotCoinAdmin();
        if (t.locked()) revert CoinLocked();
        // Before `initializeMevModule` the launch runs the extension setups.
        if (!_started[poolId]) revert PoolNotStarted();
        if (newExtension != address(0)) {
            address al = _globals.extensionAllowlist;
            if (
                al == address(0)
                    || !IArtCoinsPoolExtensionAllowlist(al).enabledExtensions(newExtension)
            ) {
                revert ExtensionNotAllowed(newExtension);
            }
        }
        if (newExtension != address(0) && newExtension == _skim[poolId].bountyRecipient) {
            revert RecipientCannotReceive(newExtension);
        }
        address old = info.extension;
        info.extension = newExtension;
        emit PoolExtensionSet(poolId, old, newExtension);
        if (newExtension != address(0)) {
            IArtCoinsPoolExtension(newExtension).initializePreLockerSetup(key, false, initData);
            IArtCoinsPoolExtension(newExtension).initializePostLockerSetup(key, info.locker, false);
        }
    }

    /// @dev Reverts `RecipientCannotReceive` when `r` is the coin, this hook, the
    ///      PoolManager, an escrow this hook has used, the pool's mev module,
    ///      locker or extension, a launch extension the factory has ever enabled, the coin's
    ///      launcher, its token deployer or the locker's PositionManager. A lookup that reverts reverts `RecipientCheckFailed`.
    function _rejectKnownStackContract(
        address coin,
        address locker,
        address mevModule,
        address poolExt,
        address r
    ) private view {
        if (
            r == coin || r == address(this) || r == address(poolManager) || everFeeEscrow[r]
                || r == mevModule || r == locker || r == poolExt
        ) revert RecipientCannotReceive(r);
        address factory = IArtCoinsTokenV2(coin).launcher();
        if (r == factory) revert RecipientCannotReceive(r);
        try IArtCoinsFactoryV2(factory).everEnabledExtensions(r) returns (bool enabled) {
            if (enabled) revert RecipientCannotReceive(r);
        } catch {
            revert RecipientCheckFailed();
        }
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

    /// @inheritdoc IArtCoinsHookV2
    uint16 public constant STACK_VERSION = Constants.STACK_VERSION;

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    /// @inheritdoc BaseHook
    /// @dev Address flag bits 0x28CC: beforeInitialize, beforeAddLiquidity,
    ///      beforeSwap, afterSwap and both swap return deltas. `beforeInitialize`
    ///      is enabled so that foreign initialization reverts.
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
