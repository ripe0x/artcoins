// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {IArtCoinsPoolExtension} from "../src/hooks/interfaces/IArtCoinsPoolExtension.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Unit tests for LiquidityLayerCounterPoolExtension. Drives the
///         contract directly, posing as the hook (set in constructor) — no
///         Uniswap v4 stack required.
contract LiquidityLayerCounterPoolExtensionTest is Test {
    using PoolIdLibrary for PoolKey;

    LiquidityLayerCounterPoolExtension internal ext;
    address internal hook = makeAddr("hook");
    address internal nmToken = makeAddr("nmToken");
    address internal pairedToken = makeAddr("pairedToken");

    PoolKey internal pk;
    PoolId internal pid;

    function setUp() public {
        ext = new LiquidityLayerCounterPoolExtension(hook);
        // Construct a deterministic PoolKey. nmToken < pairedToken so nm is token0.
        if (uint160(nmToken) > uint160(pairedToken)) {
            (nmToken, pairedToken) = (pairedToken, nmToken);
        }
        pk = PoolKey({
            currency0: Currency.wrap(nmToken),
            currency1: Currency.wrap(pairedToken),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        pid = pk.toId();
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _swap(bool isBuy, bool nmIsToken0) internal {
        // Convention from extension: isBuy = zeroForOne != nmIsToken0.
        // Therefore zeroForOne = isBuy XOR nmIsToken0.
        bool zeroForOne = isBuy != nmIsToken0;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(0, 0);
        vm.prank(hook);
        ext.afterSwap(pk, params, delta, nmIsToken0, "");
    }

    function _initPool(bool nmIsToken0) internal {
        vm.prank(hook);
        ext.initializePreLockerSetup(pk, nmIsToken0, "");
    }

    // ─── Authorization ─────────────────────────────────────────────────

    function test_afterSwap_revertsForNonHook() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(0, 0);
        vm.expectRevert(IArtCoinsPoolExtension.OnlyHook.selector);
        vm.prank(makeAddr("attacker"));
        ext.afterSwap(pk, params, delta, true, "");
    }

    function test_initializePreLockerSetup_revertsForNonHook() public {
        vm.expectRevert(IArtCoinsPoolExtension.OnlyHook.selector);
        vm.prank(makeAddr("attacker"));
        ext.initializePreLockerSetup(pk, true, "");
    }

    // ─── Init: token ↔ pool mapping ───────────────────────────────────

    function test_init_recordsTokenForPool() public {
        _initPool(true);
        assertEq(ext.tokenForPool(pid), nmToken);
        assertEq(PoolId.unwrap(ext.poolForToken(nmToken)), PoolId.unwrap(pid));
    }

    function test_init_idempotentForSameToken() public {
        _initPool(true);
        _initPool(true);
        assertEq(ext.tokenForPool(pid), nmToken);
    }

    function test_init_revertsIfDifferentTokenForSamePool() public {
        _initPool(true);
        // Re-call with `nmIsToken0 = false` — would point to pairedToken, conflicting.
        vm.prank(hook);
        vm.expectRevert(LiquidityLayerCounterPoolExtension.AlreadyInitialized.selector);
        ext.initializePreLockerSetup(pk, false, "");
    }

    function test_init_picksToken1WhenNmIsToken1() public {
        _initPool(false);
        assertEq(ext.tokenForPool(pid), pairedToken);
    }

    // ─── Direction detection ──────────────────────────────────────────

    function test_buyDetection_nmIsToken0() public {
        _initPool(true);
        _swap({isBuy: true, nmIsToken0: true});
        (uint128 b, uint128 s) = ext.counts(pid);
        assertEq(b, 1);
        assertEq(s, 0);
    }

    function test_sellDetection_nmIsToken0() public {
        _initPool(true);
        _swap({isBuy: false, nmIsToken0: true});
        (uint128 b, uint128 s) = ext.counts(pid);
        assertEq(b, 0);
        assertEq(s, 1);
    }

    function test_buyDetection_nmIsToken1() public {
        _initPool(false);
        _swap({isBuy: true, nmIsToken0: false});
        (uint128 b, uint128 s) = ext.counts(pid);
        assertEq(b, 1);
        assertEq(s, 0);
    }

    function test_sellDetection_nmIsToken1() public {
        _initPool(false);
        _swap({isBuy: false, nmIsToken0: false});
        (uint128 b, uint128 s) = ext.counts(pid);
        assertEq(b, 0);
        assertEq(s, 1);
    }

    // ─── Counts accumulate ────────────────────────────────────────────

    function test_counts_accumulate() public {
        _initPool(true);
        for (uint256 i = 0; i < 10; i++) {
            _swap({isBuy: true, nmIsToken0: true});
        }
        for (uint256 i = 0; i < 7; i++) {
            _swap({isBuy: false, nmIsToken0: true});
        }
        (uint128 b, uint128 s) = ext.counts(pid);
        assertEq(b, 10);
        assertEq(s, 7);
        assertEq(ext.totalTrades(pid), 17);
    }

    function test_countsForToken_lookup() public {
        _initPool(true);
        _swap({isBuy: true, nmIsToken0: true});
        _swap({isBuy: false, nmIsToken0: true});
        (uint128 b, uint128 s) = ext.countsForToken(nmToken);
        assertEq(b, 1);
        assertEq(s, 1);
    }

    // ─── Bit-packed sequence ──────────────────────────────────────────

    function test_sequence_singleBuyBit() public {
        _initPool(true);
        _swap({isBuy: true, nmIsToken0: true});
        // Trade 0: buy=1 → bit 0 of chunk 0 set.
        assertEq(ext.tradeChunk(pid, 0), 1);
        assertTrue(ext.isBuyAt(pid, 0));
    }

    function test_sequence_singleSellBit() public {
        _initPool(true);
        _swap({isBuy: false, nmIsToken0: true});
        // Trade 0: sell=0 → bit 0 of chunk 0 stays 0.
        assertEq(ext.tradeChunk(pid, 0), 0);
        assertFalse(ext.isBuyAt(pid, 0));
    }

    function test_sequence_alternating() public {
        _initPool(true);
        // BSBSBSBS… for 8 trades: 0xAA = 0b10101010
        for (uint256 i = 0; i < 8; i++) {
            _swap({isBuy: i % 2 == 1, nmIsToken0: true});
        }
        assertEq(ext.tradeChunk(pid, 0), 0xAA);
        for (uint256 i = 0; i < 8; i++) {
            assertEq(ext.isBuyAt(pid, i), i % 2 == 1);
        }
    }

    function test_sequence_crossesChunkBoundary() public {
        _initPool(true);
        // Fill 256 alternating to fully populate chunk 0, then 4 more in chunk 1.
        for (uint256 i = 0; i < 260; i++) {
            _swap({isBuy: i % 2 == 0, nmIsToken0: true});
        }
        // Chunk 0: 256 trades, even-indexed buys → bit pattern with 1 at even positions
        //   = 0x5555…555555 (128 buys, 128 sells).
        uint256 expected0;
        for (uint256 i = 0; i < 256; i++) {
            if (i % 2 == 0) expected0 |= (uint256(1) << i);
        }
        assertEq(ext.tradeChunk(pid, 0), expected0);

        // Chunk 1: trades 256, 257, 258, 259 → indexed by i. i=256 even → buy,
        // i=257 odd → sell, i=258 even → buy, i=259 odd → sell.
        // Bits 0,2 set in chunk 1.
        assertEq(ext.tradeChunk(pid, 1), uint256(1) | (uint256(1) << 2));

        (uint128 b, uint128 s) = ext.counts(pid);
        assertEq(b, 130); // 128 buys in chunk 0 + 2 in chunk 1
        assertEq(s, 130);
    }

    function test_isBuyAt_revertsOutOfRange() public {
        _initPool(true);
        _swap({isBuy: true, nmIsToken0: true});
        vm.expectRevert(bytes("out of range"));
        ext.isBuyAt(pid, 1);
    }

    // ─── Event emission ───────────────────────────────────────────────

    function test_event_tradeRecorded() public {
        _initPool(true);
        vm.expectEmit(true, false, false, true, address(ext));
        emit LiquidityLayerCounterPoolExtension.TradeRecorded(pid, true, 0, 1, 0);
        _swap({isBuy: true, nmIsToken0: true});
    }

    // ─── ERC-165 ──────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(ext.supportsInterface(type(IArtCoinsPoolExtension).interfaceId));
        assertFalse(ext.supportsInterface(0xdeadbeef));
    }
}
