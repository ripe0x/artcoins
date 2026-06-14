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
}

interface IBurnRouter {
    function processBurnLayer() external returns (uint256);
}

/// @title LiquidityLayerAutoForwardExtension
/// @notice LAYER pool extension that preserves the buy/sell counter from the
///         original `LiquidityLayerCounterPoolExtension` AND advances the fee
///         pipeline one stage per swap.
///
///         **Scope: V2 hook (`ArtCoinsHookV2`) only — the live LAYER pool.**
///         This extension assumes Stage 1 (LP → FeeLocker) is driven by the
///         hook's per-swap auto-claim, which is true on V2 but NOT on V3
///         (`ArtCoinsHook`, the new variant). On V3, Stage 1 must be
///         triggered externally via `lpLocker.collectRewards(token)` —
///         binding this extension to a V3 pool would leave Stages 2-4
///         stalled until that external call lands. The factory owner
///         should not allowlist this extension for V3 pools without
///         either (a) updating it to fire Stage 0 (collectRewards) itself
///         or (b) accepting that pool-side keeper coverage is required.
///
///         The pipeline is LP → FeeLocker → PFC → BurnRouter → burn. Stage 1
///         (LP → FeeLocker) is automatic on V2 (the V2 hook's `_beforeSwap`
///         calls `lpLocker.collectRewardsWithoutUnlock`). Stages 2-4 each have
///         a single permissionless entrypoint; this extension fires exactly ONE
///         of them per swap, picking by priority so each trader pays for at
///         most one action and the pipeline doesn't dump on the unlucky
///         trader who happens to trip the threshold.
///
///         Priority order (drain back-to-front so output buffers empty first):
///           4.  BurnRouter has LAYER > 0                        → processBurnLayer
///           3.  PFC holds WETH or LAYER ≥ pfcThreshold          → processFees
///           2.  FeeLocker pots ≥ feeLockerThreshold             → claim
///         Else: no-op.
///
///         `processBurnWeth` is intentionally NOT automated here: it routes
///         through UniversalRouter, which calls `poolManager.unlock(...)`,
///         which reverts when the manager is already locked (i.e. we're
///         inside the outer swap's unlock context). That step stays a keeper
///         job — it's rare (only fires when WETH ≥ minProcessThreshold) and
///         fine to run on a daily cron.
///
///         Each call is wrapped in a try/catch so a downstream revert never
///         breaks the trade.
///
/// @dev    Migrating from the existing counter extension:
///         - Copy state with `seedCounters(poolId, oldExtensionAddress)` once,
///           THEN call `hook.setPoolExtension(poolKey, newExtension, "")`.
///           Counter reads land in the new contract and `tokenForPool` is
///           re-initialized via `initializePreLockerSetup`.
///         - The renderer needs to be repointed at the new extension address
///           (or use `LiquidityLayerOnchainRenderer.setExtension` if exposed).
contract LiquidityLayerAutoForwardExtension is IArtCoinsPoolExtension, Ownable {
    using PoolIdLibrary for PoolKey;

    // ─── Bound addresses ──────────────────────────────────────────────

    /// @notice The hook authorized to call `afterSwap` and the init callbacks.
    address public immutable hook;
    /// @notice LP locker (auto-collect target — already wired by the hook).
    address public immutable lpLocker;
    /// @notice FeeLocker holding per-recipient pots awaiting claim.
    IArtCoinsFeeLocker public immutable feeLocker;
    /// @notice Protocol-fee splitter (60% treasury / 40% burn).
    IProtocolFeeController public immutable pfc;
    /// @notice Buy-and-burn router (final stage).
    IBurnRouter public immutable burnRouter;
    /// @notice Treasury slot in FeeLocker (PFC).
    address public immutable pfcAddress;

    // ─── Counter state (copied verbatim from LiquidityLayerCounterPoolExtension) ───

    struct Counts {
        uint128 buys;
        uint128 sells;
    }

    mapping(PoolId => Counts) internal _counts;
    mapping(PoolId => mapping(uint256 chunkIdx => uint256 packedBits)) internal _chunks;
    mapping(PoolId => address) public tokenForPool;
    mapping(address => PoolId) public poolForToken;

    // ─── Auto-forward thresholds (owner-settable) ────────────────────

    /// @notice Skip Stage 2 (FeeLocker.claim) unless the pot for at least one
    ///         (recipient, currency) pair is ≥ this. Lower thresholds are fine
    ///         here because each trader pays for at most ONE stage per swap.
    uint256 public feeLockerWethThreshold = 0.01 ether;
    uint256 public feeLockerLayerThreshold = 100_000 ether;
    /// @notice Skip Stage 3 (PFC.processFees) unless PFC holds ≥ this.
    uint256 public pfcWethThreshold = 0.01 ether;
    uint256 public pfcLayerThreshold = 100_000 ether;
    /// @notice Stage 4 (processBurnLayer) fires whenever BurnRouter holds any
    ///         LAYER — burning is cheap and has no slippage risk.

    // ─── Events ───────────────────────────────────────────────────────

    event TradeRecorded(
        PoolId indexed poolId, bool isBuy, uint256 tradeIndex, uint128 newBuys, uint128 newSells
    );
    event PipelineStageFired(PoolId indexed poolId, uint8 stage);
    event PipelineStageReverted(PoolId indexed poolId, uint8 stage, bytes reason);
    event ThresholdsUpdated(
        uint256 feeLockerWeth, uint256 feeLockerLayer, uint256 pfcWeth, uint256 pfcLayer
    );

    error AlreadyInitialized();

    constructor(
        address hook_,
        address lpLocker_,
        address feeLocker_,
        address pfc_,
        address burnRouter_,
        address owner_
    ) Ownable(owner_) {
        hook = hook_;
        lpLocker = lpLocker_;
        feeLocker = IArtCoinsFeeLocker(feeLocker_);
        pfcAddress = pfc_;
        pfc = IProtocolFeeController(pfc_);
        burnRouter = IBurnRouter(burnRouter_);
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    // ─── Hook init callbacks ─────────────────────────────────────────

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
        poolForToken[token] = id;
    }

    function initializePostLockerSetup(PoolKey calldata, address, bool) external view onlyHook {
        // No-op.
    }

    // ─── afterSwap: counter + priority ladder ────────────────────────

    function afterSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta,
        /* delta */
        bool artCoinIsToken0,
        bytes calldata /* poolExtensionSwapData */
    ) external onlyHook {
        // 1. Always advance the counter — independent of pipeline state.
        bool isBuy = swapParams.zeroForOne != artCoinIsToken0;
        PoolId id = poolKey.toId();
        Counts storage c = _counts[id];
        uint256 tradeIndex = uint256(c.buys) + uint256(c.sells);
        uint256 chunkIdx = tradeIndex >> 8;
        uint256 bitOffset = tradeIndex & 0xff;

        if (isBuy) {
            c.buys += 1;
            _chunks[id][chunkIdx] |= (uint256(1) << bitOffset);
        } else {
            c.sells += 1;
        }
        emit TradeRecorded(id, isBuy, tradeIndex, c.buys, c.sells);

        // 2. Advance the pipeline one stage. None of the stages we run here
        //    re-enter the pool (no swap), so no recursion guard needed.
        address token = tokenForPool[id];
        address weth = artCoinIsToken0
            ? Currency.unwrap(poolKey.currency1)
            : Currency.unwrap(poolKey.currency0);

        _advancePipeline(id, token, weth);
    }

    /// @dev Try the highest-priority stage that has work; succeed-or-skip
    ///      semantics, never revert. Stages share a single try/catch.
    function _advancePipeline(PoolId id, address token, address weth) internal {
        // Stage 4: BurnRouter holds LAYER directly (cheap to burn, no swap).
        //          processBurnWeth is NOT automated here — see contract docs.
        if (IERC20(token).balanceOf(address(burnRouter)) > 0) {
            try burnRouter.processBurnLayer() {
                emit PipelineStageFired(id, 4);
                return;
            } catch (bytes memory reason) {
                emit PipelineStageReverted(id, 4, reason);
            }
        }

        // Stage 3: PFC holds WETH or LAYER above threshold.
        uint256 pfcWeth = IERC20(weth).balanceOf(pfcAddress);
        uint256 pfcLayer = IERC20(token).balanceOf(pfcAddress);
        if (pfcWeth >= pfcWethThreshold) {
            try pfc.processFees(weth) {
                emit PipelineStageFired(id, 3);
                return;
            } catch (bytes memory reason) {
                emit PipelineStageReverted(id, 3, reason);
            }
        }
        if (pfcLayer >= pfcLayerThreshold) {
            try pfc.processFees(token) {
                emit PipelineStageFired(id, 3);
                return;
            } catch (bytes memory reason) {
                emit PipelineStageReverted(id, 3, reason);
            }
        }

        // Stage 2: FeeLocker has a recipient pot above threshold.
        // Drain BurnRouter slot first (its share feeds Stage 4 directly).
        if (feeLocker.availableFees(address(burnRouter), weth) >= feeLockerWethThreshold) {
            try feeLocker.claim(address(burnRouter), weth) {
                emit PipelineStageFired(id, 2);
                return;
            } catch (bytes memory reason) {
                emit PipelineStageReverted(id, 2, reason);
            }
        }
        if (feeLocker.availableFees(address(burnRouter), token) >= feeLockerLayerThreshold) {
            try feeLocker.claim(address(burnRouter), token) {
                emit PipelineStageFired(id, 2);
                return;
            } catch (bytes memory reason) {
                emit PipelineStageReverted(id, 2, reason);
            }
        }
        // Then the PFC slot (its share feeds Stage 3).
        if (feeLocker.availableFees(pfcAddress, weth) >= feeLockerWethThreshold) {
            try feeLocker.claim(pfcAddress, weth) {
                emit PipelineStageFired(id, 2);
                return;
            } catch (bytes memory reason) {
                emit PipelineStageReverted(id, 2, reason);
            }
        }
        if (feeLocker.availableFees(pfcAddress, token) >= feeLockerLayerThreshold) {
            try feeLocker.claim(pfcAddress, token) {
                emit PipelineStageFired(id, 2);
                return;
            } catch (bytes memory reason) {
                emit PipelineStageReverted(id, 2, reason);
            }
        }
        // No-op: nothing crossed a threshold this swap.
    }

    // ─── Owner-only configuration ────────────────────────────────────

    function setThresholds(
        uint256 feeLockerWeth,
        uint256 feeLockerLayer,
        uint256 pfcWeth,
        uint256 pfcLayer
    ) external onlyOwner {
        feeLockerWethThreshold = feeLockerWeth;
        feeLockerLayerThreshold = feeLockerLayer;
        pfcWethThreshold = pfcWeth;
        pfcLayerThreshold = pfcLayer;
        emit ThresholdsUpdated(feeLockerWeth, feeLockerLayer, pfcWeth, pfcLayer);
    }

    // ─── Counter migration helper ────────────────────────────────────

    /// @notice One-time import of the buy/sell totals from the previous
    ///         extension. Does NOT migrate the bit-packed history — call
    ///         `seedHistory` separately for that.
    function seedCounters(PoolId id, uint128 buys, uint128 sells) external onlyOwner {
        Counts storage c = _counts[id];
        if (c.buys != 0 || c.sells != 0) revert AlreadyInitialized();
        c.buys = buys;
        c.sells = sells;
    }

    /// @notice One-time backfill of the bit-packed direction sequence. Each
    ///         entry of `chunks` is a 256-trade slot where bit `n` of
    ///         `chunks[i]` corresponds to trade index `(256*i + n)`
    ///         (1 = buy, 0 = sell). Combined length must match the totals
    ///         already seeded via `seedCounters`. Reverts if the slot for any
    ///         chunk is non-zero (one-shot semantics).
    /// @dev    Off-chain backfill flow:
    ///           1. Read every Swap log on the LAYER PoolManager for `pid`
    ///              from the deploy block to the cutover block.
    ///           2. Classify each as buy (`zeroForOne != artCoinIsToken0`).
    ///           3. Pack into uint256 chunks (LSB-first within each chunk).
    ///           4. Call `seedCounters(pid, buys, sells)` then this.
    function seedHistory(PoolId id, uint256[] calldata chunks) external onlyOwner {
        Counts memory c = _counts[id];
        uint256 totalTradesSeeded = uint256(c.buys) + uint256(c.sells);
        // Must call seedCounters first; chunk count derives from totals.
        require(totalTradesSeeded > 0, "seed counters first");
        // Round up: ceil(total / 256).
        uint256 expectedChunks = (totalTradesSeeded + 255) / 256;
        require(chunks.length == expectedChunks, "chunk count mismatch");
        for (uint256 i = 0; i < chunks.length; i++) {
            require(_chunks[id][i] == 0, "chunk already seeded");
            _chunks[id][i] = chunks[i];
        }
    }

    // ─── Read helpers (signature-compatible with the old extension) ──

    function counts(PoolId poolId) external view returns (uint128 buys, uint128 sells) {
        Counts memory c = _counts[poolId];
        return (c.buys, c.sells);
    }

    function countsForToken(address token) external view returns (uint128 buys, uint128 sells) {
        Counts memory c = _counts[poolForToken[token]];
        return (c.buys, c.sells);
    }

    function totalTrades(PoolId poolId) external view returns (uint256) {
        Counts memory c = _counts[poolId];
        return uint256(c.buys) + uint256(c.sells);
    }

    function tradeChunk(PoolId poolId, uint256 chunkIdx) external view returns (uint256) {
        return _chunks[poolId][chunkIdx];
    }

    function isBuyAt(PoolId poolId, uint256 tradeIndex) external view returns (bool) {
        Counts memory c = _counts[poolId];
        require(tradeIndex < uint256(c.buys) + uint256(c.sells), "out of range");
        return (_chunks[poolId][tradeIndex >> 8] >> (tradeIndex & 0xff)) & 1 == 1;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsPoolExtension).interfaceId;
    }
}
