// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsPoolExtension} from "../hooks/interfaces/IArtCoinsPoolExtension.sol";
import {IArtCoinsFeeLocker} from "../interfaces/IArtCoinsFeeLocker.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IProtocolFeeController {
    function processFees(address token) external;
    function processNativeFees() external;
}

interface ILpLockerCollect {
    function collectRewardsWithoutUnlock(address token) external;
}

interface IBurnRouterOpenTab {
    function processBurnLayer() external returns (uint256);
    function processBurnWethOpenTab(uint256 minLayerOut) external returns (uint256, uint256);
    function layerToken() external view returns (address);
    function weth() external view returns (address);
}

/// @title  ArtCoinsAutoBurnPoolExtension
/// @notice Current-hook (`ArtCoinsHook`) pool extension that makes the LAYER
///         buy-and-burn self-executing on an open Uniswap v4 swap tab — no
///         keeper required. Bound to any `ArtCoinsHook` art-coin pool, it advances the
///         protocol fee pipeline once per swap and, crucially, drives the
///         WETH→LAYER buy-and-burn *from inside the trader's open swap* via
///         `BurnRouter.processBurnWethOpenTab` (a direct `poolManager.swap`
///         on the LAYER pool — no nested `unlock`).
///
///         **This is artcoins-protocol infra, shared across ALL art coins.**
///         It is opt-in per pool and intentionally generic: it does NOT bake
///         in any single launch's routing. The burn target (LAYER), the WETH
///         the BurnRouter swaps, the fee escrow and the protocol-fee
///         controller are all bound at construction; the pool's art coin and
///         its LP locker are learned per-pool from the hook's init callbacks.
///
///         **Why a separate variant for the current hook?** The legacy LAYER
///         extension (`LiquidityLayerAutoForwardExtension`) relies on the
///         legacy hook's `_beforeSwap` auto-collect to feed Stage 1
///         (LP → FeeLocker). The current hook removed that per-swap
///         auto-collect (it made pools expensive to route through), so this
///         extension MUST drive the collect itself. It does so with
///         `lpLocker.collectRewardsWithoutUnlock(token)` — the open-tab-safe
///         collect path (no nested `unlock`). Set `collectOnSwap = false` to
///         opt out and let a keeper drive collection instead.
///
///         **The open-tab burn.** The legacy LAYER extension deliberately SKIPS
///         `processBurnWeth` because it routes through the Universal Router,
///         which calls `poolManager.unlock(...)` and reverts inside an
///         already-open tab. This extension uses the new
///         `processBurnWethOpenTab` instead, which swaps directly on the open
///         tab and settles its own deltas, so the buy-and-burn no longer
///         needs a keeper.
///
///         **Per-swap discipline.** Like the legacy extension, the downstream
///         pipeline fires at most ONE stage per swap (priority order, drain
///         back-to-front) so no single trader pays for the whole pipeline.
///         Every stage is wrapped in try/catch: a downstream revert never
///         breaks the trade.
///
///         **Gas note.** Driving collect every swap re-introduces the
///         position-poke cost the current hook removed, and the open-tab burn runs
///         a full swap on the LAYER pool (firing the LAYER pool's own hook
///         callbacks). Both are gated — the burn only fires when the
///         BurnRouter holds WETH/ETH above `burnRouterWethThreshold`, and at
///         most one downstream stage runs per swap — but pools that route
///         high volume may prefer `collectOnSwap = false` plus a periodic
///         keeper.
contract ArtCoinsAutoBurnPoolExtension is IArtCoinsPoolExtension, Ownable {
    using PoolIdLibrary for PoolKey;

    // ─── stage ids (for events) ──────────────────────────────────────────

    uint8 internal constant STAGE_BURN_LAYER = 1;
    uint8 internal constant STAGE_BURN_WETH_OPEN_TAB = 2;
    uint8 internal constant STAGE_PROCESS_FEES = 3;
    uint8 internal constant STAGE_CLAIM = 4;

    // ─── bound addresses (immutable protocol infra) ──────────────────────

    /// @notice The hook authorized to call `afterSwap` and the init callbacks.
    address public immutable hook;
    /// @notice Fee escrow holding per-recipient pots (`ArtCoinsFeeEscrow`,
    ///         which exposes the `availableFees`/`claim` ABI used here).
    IArtCoinsFeeLocker public immutable feeLocker;
    /// @notice Protocol-fee controller (split → BurnRouter burn share). Zero
    ///         disables the PFC stages (a pool whose protocol share reaches the
    ///         BurnRouter by another route).
    IProtocolFeeController public immutable pfc;
    address public immutable pfcAddress;
    /// @notice Buy-and-burn router (the open-tab burn target).
    IBurnRouterOpenTab public immutable burnRouter;
    address public immutable burnRouterAddress;
    /// @notice LAYER token — the buy-and-burn target, read from the BurnRouter.
    address public immutable layerToken;
    /// @notice The WETH the BurnRouter swaps for LAYER (the LAYER pool's paired
    ///         currency), read from the BurnRouter. May differ from a given
    ///         pool's paired currency; that is fine — the BurnRouter wraps any
    ///         native ETH it receives before swapping.
    address public immutable burnWeth;

    // ─── per-pool state ──────────────────────────────────────────────────

    /// @notice The art coin bound to each pool (set in `initializePreLockerSetup`).
    mapping(PoolId => address) public tokenForPool;
    /// @notice The LP locker bound to each pool (set in `initializePostLockerSetup`).
    ///         Used as the Stage 1 collect target.
    mapping(PoolId => address) public lockerForPool;

    // ─── owner-settable config ───────────────────────────────────────────

    /// @notice When true (default), Stage 1 (`collectRewardsWithoutUnlock`) is
    ///         driven on every swap. Set false to let a keeper drive collection
    ///         (the "collect is driven elsewhere" mode).
    bool public collectOnSwap = true;

    /// @notice Fire the open-tab burn only when the BurnRouter holds WETH or
    ///         native ETH ≥ this. The BurnRouter's own `minProcessThreshold`
    ///         is the authoritative gate; this is a cheap pre-check that avoids
    ///         a wasted external call when there is clearly nothing to burn.
    uint256 public burnRouterWethThreshold = 0.01 ether;
    /// @notice Skip the PFC WETH/ETH stage unless the PFC holds ≥ this.
    uint256 public pfcWethThreshold = 0.01 ether;
    /// @notice Skip the PFC LAYER stage unless the PFC holds ≥ this.
    uint256 public pfcLayerThreshold = 100_000 ether;
    /// @notice Skip an escrow WETH/ETH claim unless the pot is ≥ this.
    uint256 public feeLockerWethThreshold = 0.01 ether;
    /// @notice Skip an escrow LAYER claim unless the pot is ≥ this.
    uint256 public feeLockerLayerThreshold = 100_000 ether;

    // ─── events ──────────────────────────────────────────────────────────

    event PipelineStageFired(PoolId indexed poolId, uint8 stage);
    event PipelineStageReverted(PoolId indexed poolId, uint8 stage, bytes reason);
    event CollectFired(PoolId indexed poolId, address indexed token);
    event CollectReverted(PoolId indexed poolId, bytes reason);
    event CollectOnSwapUpdated(bool enabled);
    event ThresholdsUpdated(
        uint256 burnRouterWeth,
        uint256 pfcWeth,
        uint256 pfcLayer,
        uint256 feeLockerWeth,
        uint256 feeLockerLayer
    );

    // ─── errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error AlreadyInitialized();

    constructor(
        address hook_,
        address feeLocker_,
        address pfc_,
        address burnRouter_,
        address owner_
    ) Ownable(owner_) {
        if (hook_ == address(0) || feeLocker_ == address(0) || burnRouter_ == address(0)) {
            revert ZeroAddress();
        }
        hook = hook_;
        feeLocker = IArtCoinsFeeLocker(feeLocker_);
        pfcAddress = pfc_;
        pfc = IProtocolFeeController(pfc_);
        burnRouter = IBurnRouterOpenTab(burnRouter_);
        burnRouterAddress = burnRouter_;

        // The BurnRouter must be initialized before this extension is deployed
        // (it is in every live wiring) so its LAYER/WETH bindings resolve.
        address layer_ = IBurnRouterOpenTab(burnRouter_).layerToken();
        address weth_ = IBurnRouterOpenTab(burnRouter_).weth();
        if (layer_ == address(0) || weth_ == address(0)) revert ZeroAddress();
        layerToken = layer_;
        burnWeth = weth_;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    // ─── hook init callbacks ─────────────────────────────────────────────

    /// @inheritdoc IArtCoinsPoolExtension
    function initializePreLockerSetup(
        PoolKey calldata poolKey,
        bool artCoinIsToken0,
        bytes calldata /* poolExtensionInitData */
    ) external onlyHook {
        PoolId id = poolKey.toId();
        address token = artCoinIsToken0
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);

        address existing = tokenForPool[id];
        if (existing != address(0) && existing != token) revert AlreadyInitialized();
        tokenForPool[id] = token;
    }

    /// @inheritdoc IArtCoinsPoolExtension
    /// @dev Captures the pool's LP locker so Stage 1 (collect) can target it.
    function initializePostLockerSetup(PoolKey calldata poolKey, address locker, bool)
        external
        onlyHook
    {
        lockerForPool[poolKey.toId()] = locker;
    }

    // ─── afterSwap: collect + one downstream stage ───────────────────────

    /// @inheritdoc IArtCoinsPoolExtension
    function afterSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata, /* swapParams */
        BalanceDelta, /* delta */
        bool, /* artCoinIsToken0 */
        bytes calldata /* poolExtensionSwapData */
    ) external onlyHook {
        PoolId id = poolKey.toId();

        // Stage 1: drive the LP collect (the hook does NOT auto-collect).
        // Open-tab-safe variant — no nested unlock. Wrapped so a collect
        // revert (e.g. MEV module still operating) never breaks the trade.
        if (collectOnSwap) {
            address token = tokenForPool[id];
            address locker = lockerForPool[id];
            if (token != address(0) && locker != address(0)) {
                try ILpLockerCollect(locker).collectRewardsWithoutUnlock(token) {
                    emit CollectFired(id, token);
                } catch (bytes memory reason) {
                    emit CollectReverted(id, reason);
                }
            }
        }

        _advancePipeline(id);
    }

    /// @dev Fires the highest-priority stage that has work; at most one per
    ///      swap. Drains back-to-front so output buffers empty first:
    ///        1. BurnRouter holds LAYER            → processBurnLayer (cheap)
    ///        2. BurnRouter holds WETH/ETH ≥ thr   → processBurnWethOpenTab
    ///        3. PFC holds WETH / ETH / LAYER ≥ thr → processFees / processNativeFees
    ///        4. escrow pot ≥ thr (BurnRouter then PFC slot) → claim
    ///      Each attempt is try/catch'd; a revert advances to the next check
    ///      only within the same currency family — once a stage fires we stop.
    function _advancePipeline(PoolId id) internal {
        // Stage 1 (priority): burn LAYER the router already holds — cheapest,
        // no swap, no slippage.
        if (IERC20(layerToken).balanceOf(burnRouterAddress) > 0) {
            try burnRouter.processBurnLayer() {
                emit PipelineStageFired(id, STAGE_BURN_LAYER);
                return;
            } catch (bytes memory reason) {
                emit PipelineStageReverted(id, STAGE_BURN_LAYER, reason);
            }
        }

        // Stage 2: the open-tab buy-and-burn. Pre-checked on WETH + native ETH
        // (the router wraps ETH before swapping). The router enforces its own
        // threshold, EMA guard and slippage floor; minLayerOut = 0 defers to
        // the floor (no off-chain quote available on the open tab).
        if (
            IERC20(burnWeth).balanceOf(burnRouterAddress) >= burnRouterWethThreshold
                || burnRouterAddress.balance >= burnRouterWethThreshold
        ) {
            try burnRouter.processBurnWethOpenTab(0) {
                emit PipelineStageFired(id, STAGE_BURN_WETH_OPEN_TAB);
                return;
            } catch (bytes memory reason) {
                emit PipelineStageReverted(id, STAGE_BURN_WETH_OPEN_TAB, reason);
            }
        }

        // Stage 3: split protocol fees the PFC holds toward the BurnRouter.
        if (pfcAddress != address(0)) {
            if (IERC20(burnWeth).balanceOf(pfcAddress) >= pfcWethThreshold) {
                try pfc.processFees(burnWeth) {
                    emit PipelineStageFired(id, STAGE_PROCESS_FEES);
                    return;
                } catch (bytes memory reason) {
                    emit PipelineStageReverted(id, STAGE_PROCESS_FEES, reason);
                }
            }
            if (pfcAddress.balance >= pfcWethThreshold) {
                try pfc.processNativeFees() {
                    emit PipelineStageFired(id, STAGE_PROCESS_FEES);
                    return;
                } catch (bytes memory reason) {
                    emit PipelineStageReverted(id, STAGE_PROCESS_FEES, reason);
                }
            }
            if (IERC20(layerToken).balanceOf(pfcAddress) >= pfcLayerThreshold) {
                try pfc.processFees(layerToken) {
                    emit PipelineStageFired(id, STAGE_PROCESS_FEES);
                    return;
                } catch (bytes memory reason) {
                    emit PipelineStageReverted(id, STAGE_PROCESS_FEES, reason);
                }
            }
        }

        // Stage 4: pull escrow pots into the sinks. Drain the BurnRouter slot
        // first (feeds Stages 1-2 directly), then the PFC slot (feeds Stage 3).
        if (_tryClaim(id, burnRouterAddress, burnWeth, feeLockerWethThreshold)) return;
        if (_tryClaim(id, burnRouterAddress, address(0), feeLockerWethThreshold)) return;
        if (_tryClaim(id, burnRouterAddress, layerToken, feeLockerLayerThreshold)) return;
        if (pfcAddress != address(0)) {
            if (_tryClaim(id, pfcAddress, burnWeth, feeLockerWethThreshold)) return;
            if (_tryClaim(id, pfcAddress, address(0), feeLockerWethThreshold)) return;
            if (_tryClaim(id, pfcAddress, layerToken, feeLockerLayerThreshold)) return;
        }
        // No-op: nothing crossed a threshold this swap.
    }

    /// @dev Claims `feeOwner`'s `token` pot from the escrow if it is ≥
    ///      `threshold`. Returns true iff a claim fired (so the caller stops).
    function _tryClaim(PoolId id, address feeOwner, address token, uint256 threshold)
        internal
        returns (bool)
    {
        if (feeLocker.availableFees(feeOwner, token) < threshold) return false;
        try feeLocker.claim(feeOwner, token) {
            emit PipelineStageFired(id, STAGE_CLAIM);
            return true;
        } catch (bytes memory reason) {
            emit PipelineStageReverted(id, STAGE_CLAIM, reason);
            return false;
        }
    }

    // ─── owner-only configuration ────────────────────────────────────────

    function setCollectOnSwap(bool enabled) external onlyOwner {
        collectOnSwap = enabled;
        emit CollectOnSwapUpdated(enabled);
    }

    function setThresholds(
        uint256 burnRouterWeth,
        uint256 pfcWeth,
        uint256 pfcLayer,
        uint256 feeLockerWeth,
        uint256 feeLockerLayer
    ) external onlyOwner {
        burnRouterWethThreshold = burnRouterWeth;
        pfcWethThreshold = pfcWeth;
        pfcLayerThreshold = pfcLayer;
        feeLockerWethThreshold = feeLockerWeth;
        feeLockerLayerThreshold = feeLockerLayer;
        emit ThresholdsUpdated(burnRouterWeth, pfcWeth, pfcLayer, feeLockerWeth, feeLockerLayer);
    }

    // ─── introspection ───────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsPoolExtension).interfaceId;
    }
}
