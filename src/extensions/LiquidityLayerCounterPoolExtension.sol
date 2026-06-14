// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsPoolExtension} from "../hooks/interfaces/IArtCoinsPoolExtension.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title LiquidityLayerCounterPoolExtension
/// @notice Pool extension that counts buys and sells per pool and records the
///         chronological direction of every swap as a bit-packed sequence.
///         Designed to be plugged into a ArtCoins pool via the hook's
///         `poolExtension` slot — the hook calls `afterSwap` on every trade.
///
/// @dev    Storage layout per pool:
///           - `Counts { uint128 buys, uint128 sells }` packed into one slot.
///           - Bit-packed sequence: a `mapping(uint256 chunkIdx => uint256)`
///             where each uint256 holds 256 trades (1 bit each: buy=1, sell=0).
///         A `tokenForPool` and `poolForToken` cross-reference is captured at
///         init time so the on-chain renderer can resolve a token → poolId
///         in a single read.
contract LiquidityLayerCounterPoolExtension is IArtCoinsPoolExtension {
    using PoolIdLibrary for PoolKey;

    /// @notice The hook authorized to call `afterSwap` and the init callbacks.
    address public immutable hook;

    /// @notice Buy and sell totals per pool, packed into one storage slot.
    /// @param buys Number of trades where the user purchased the art-coin token.
    /// @param sells Number of trades where the user sold the art-coin token.
    struct Counts {
        uint128 buys;
        uint128 sells;
    }

    mapping(PoolId => Counts) internal _counts;

    /// @notice Bit-packed direction sequence per pool.
    ///         `_chunks[poolId][i]` holds trades [256*i, 256*i+255], with bit
    ///         `n` of `_chunks[poolId][i]` indicating trade (256*i + n):
    ///         1 = buy, 0 = sell. Zero-bits are also "no trade yet" — the
    ///         total trade count (`buys + sells`) is the authoritative length.
    mapping(PoolId => mapping(uint256 chunkIdx => uint256 packedBits)) internal _chunks;

    /// @notice The art-coin token for each pool, captured at init time.
    mapping(PoolId => address) public tokenForPool;
    /// @notice The pool ID for each art-coin token, captured at init time.
    mapping(address => PoolId) public poolForToken;

    /// @notice Emitted on every recorded swap.
    /// @param poolId The pool whose counter advanced.
    /// @param isBuy True if the swap purchased the art-coin token.
    /// @param tradeIndex The 0-indexed sequence position (= old buys + sells).
    /// @param newBuys Updated buy total.
    /// @param newSells Updated sell total.
    event TradeRecorded(
        PoolId indexed poolId, bool isBuy, uint256 tradeIndex, uint128 newBuys, uint128 newSells
    );

    /// @notice Reverts when the bound token differs from one already recorded.
    error AlreadyInitialized();

    /// @param hook_ The ArtCoins hook authorized to call this extension.
    constructor(address hook_) {
        hook = hook_;
    }

    /// @dev Restricts a function to the bound hook.
    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

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

        // Reject re-init for a different token. (Same-pair re-init is a noop.)
        address existing = tokenForPool[id];
        if (existing != address(0) && existing != token) revert AlreadyInitialized();

        tokenForPool[id] = token;
        poolForToken[token] = id;
    }

    /// @inheritdoc IArtCoinsPoolExtension
    function initializePostLockerSetup(PoolKey calldata, address, bool) external view onlyHook {
        // No-op: this extension doesn't need locker context.
    }

    /// @inheritdoc IArtCoinsPoolExtension
    function afterSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta,
        /* delta */
        bool artCoinIsToken0,
        bytes calldata /* poolExtensionSwapData */
    ) external onlyHook {
        // Convention: a "buy" of the art-coin token means the user is
        // exchanging the paired currency *for* it. With v4's `zeroForOne`
        // semantics, that's `zeroForOne != artCoinIsToken0`:
        //   - nm is token0 + zeroForOne=false → sender is buying nm  → BUY
        //   - nm is token0 + zeroForOne=true  → sender is selling nm → SELL
        //   - nm is token1 + zeroForOne=true  → sender is buying nm  → BUY
        //   - nm is token1 + zeroForOne=false → sender is selling nm → SELL
        bool isBuy = swapParams.zeroForOne != artCoinIsToken0;

        PoolId id = poolKey.toId();
        Counts storage c = _counts[id];

        uint256 tradeIndex = uint256(c.buys) + uint256(c.sells);
        uint256 chunkIdx = tradeIndex >> 8; // / 256
        uint256 bitOffset = tradeIndex & 0xff; // % 256

        if (isBuy) {
            c.buys += 1;
            // Set the bit for this trade (buy=1).
            _chunks[id][chunkIdx] |= (uint256(1) << bitOffset);
        } else {
            c.sells += 1;
            // Sell is encoded as a zero-bit; storage is already zero by
            // default for a freshly-touched chunk, so no SSTORE needed.
        }

        emit TradeRecorded(id, isBuy, tradeIndex, c.buys, c.sells);
    }

    // ─── Read helpers for renderers / off-chain consumers ────────────

    /// @notice Returns the buy and sell totals for a pool.
    /// @param poolId The pool.
    /// @return buys Buy count.
    /// @return sells Sell count.
    function counts(PoolId poolId) external view returns (uint128 buys, uint128 sells) {
        Counts memory c = _counts[poolId];
        return (c.buys, c.sells);
    }

    /// @notice Convenience: counts looked up by token address.
    function countsForToken(address token) external view returns (uint128 buys, uint128 sells) {
        Counts memory c = _counts[poolForToken[token]];
        return (c.buys, c.sells);
    }

    /// @notice Returns the total number of recorded trades for a pool.
    function totalTrades(PoolId poolId) external view returns (uint256) {
        Counts memory c = _counts[poolId];
        return uint256(c.buys) + uint256(c.sells);
    }

    /// @notice Reads one 256-trade chunk of the bit-packed sequence.
    ///         Off-chain animation clients can multicall this across all
    ///         chunks to assemble the full history.
    /// @param poolId The pool.
    /// @param chunkIdx Chunk index (0 = trades 0..255, 1 = 256..511, …).
    /// @return packedBits 256 bits where bit `n` is trade (256*chunkIdx + n);
    ///                   1 = buy, 0 = sell. Beyond `totalTrades`, bits are
    ///                   meaningless (treat them as not-yet-recorded).
    function tradeChunk(PoolId poolId, uint256 chunkIdx)
        external
        view
        returns (uint256 packedBits)
    {
        return _chunks[poolId][chunkIdx];
    }

    /// @notice Returns whether the trade at `tradeIndex` was a buy.
    /// @dev Reverts if `tradeIndex >= totalTrades(poolId)`.
    function isBuyAt(PoolId poolId, uint256 tradeIndex) external view returns (bool) {
        Counts memory c = _counts[poolId];
        require(tradeIndex < uint256(c.buys) + uint256(c.sells), "out of range");
        return (_chunks[poolId][tradeIndex >> 8] >> (tradeIndex & 0xff)) & 1 == 1;
    }

    /// @inheritdoc IArtCoinsPoolExtension
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsPoolExtension).interfaceId;
    }
}
