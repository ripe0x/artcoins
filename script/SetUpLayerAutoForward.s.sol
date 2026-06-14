// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {
    LiquidityLayerAutoForwardExtension
} from "../src/extensions/LiquidityLayerAutoForwardExtension.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface ILayerHook {
    function poolExtensionAllowlist() external view returns (address);
    function poolExtension(PoolId) external view returns (address);
    function setPoolExtension(PoolKey calldata pk, address newExtension, bytes calldata initData)
        external;
}

interface IAllowlist {
    function setPoolExtension(address ext, bool ok) external;
    function enabledExtensions(address ext) external view returns (bool);
}

/// @title  SetUpLayerAutoForward
/// @notice Deploys the new auto-forward extension and wires it into the LAYER
///         pool with the historical counter backfilled.
///
///         Five-step flow, all from the same broadcaster (LAYER token admin
///         + allowlist owner = 0xCB43…217F9):
///
///           1. Deploy LiquidityLayerAutoForwardExtension
///           2. allowlist.setPoolExtension(newExt, true)
///           3. hook.setPoolExtension(LAYER_POOL_KEY, newExt, "")
///           4. newExt.seedCounters(layerPoolId, BUYS, SELLS)
///           5. newExt.seedHistory(layerPoolId, [chunks…])
///
///         BUYS, SELLS, and the chunks come from
///         `scripts/backfill-layer-counter.ts` in the artcoins repo. Re-run
///         that script immediately before broadcast to capture the freshest
///         counts; the chunk count must match (BUYS + SELLS) ceil-div 256.
///
/// Usage:
///   # Dry run on a fork:
///   forge script script/SetUpLayerAutoForward.s.sol \
///     --fork-url $MAINNET_RPC_URL -vvv
///
///   # Mainnet broadcast (requires explicit confirmation):
///   forge script script/SetUpLayerAutoForward.s.sol \
///     --rpc-url $MAINNET_RPC_URL --broadcast \
///     --account <ledger-or-keystore-name> -vvv
contract SetUpLayerAutoForward is Script {
    using PoolIdLibrary for PoolKey;

    // ── Mainnet immutable infrastructure ───────────────────────────────

    address constant LAYER = 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant HOOK = 0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc;
    address constant LP_LOCKER = 0x75BE7E95745915fD0C1761B74F3f9650ad2d1118;
    address constant FEE_LOCKER = 0x1143db0913Ca5eCe8A42FC01b625fD81F9386b05;
    address constant PFC = 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60;
    address constant BURN_ROUTER = 0x2eDBdF011768d8cd4Ef537658b41440900C52000;

    // ── LAYER pool key (must match what the hook stored at init time) ──

    int24 constant TICK_SPACING = 200;
    uint24 constant DYNAMIC_FEE_FLAG = 0x800000;

    function _layerPoolKey() internal pure returns (PoolKey memory pk) {
        pk = PoolKey({
            currency0: Currency.wrap(LAYER),
            currency1: Currency.wrap(WETH),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    // ── Backfill values — REGENERATE BEFORE EACH RUN ──────────────────
    //
    // Source: artcoins/scripts/backfill-layer-counter.ts
    // Last regenerated: 2026-05-08 (head block at run time)
    //
    // If you re-run the backfill, paste the new values here. The chunk
    // array length must equal ceil((BUYS + SELLS) / 256).

    uint128 constant BUYS = 321;
    uint128 constant SELLS = 410;

    function _historyChunks() internal pure returns (uint256[] memory) {
        uint256[] memory c = new uint256[](3);
        c[0] = 0xa3f8fc323303478c64ab69dfb1180e3ac00e11ea00008056004a008c80000000;
        c[1] = 0x064088cc9e67001655a6ab9620057fed53fee88377d7a08200330d1174fdefff;
        c[2] = 0x0000000005ada7df67fba372020203c3aa0f9fff90175cfbe0c067acd6231400;
        return c;
    }

    // ── Run ───────────────────────────────────────────────────────────

    function run() external {
        PoolKey memory pk = _layerPoolKey();
        PoolId pid = pk.toId();

        address allowlist = ILayerHook(HOOK).poolExtensionAllowlist();
        address currentExt = ILayerHook(HOOK).poolExtension(pid);

        console2.log("Pre-flight:");
        console2.log("  hook                  ", HOOK);
        console2.log("  allowlist             ", allowlist);
        console2.log("  current pool extension", currentExt);
        console2.log("  burn router           ", BURN_ROUTER);
        console2.log("  backfill buys         ", uint256(BUYS));
        console2.log("  backfill sells        ", uint256(SELLS));

        uint256[] memory chunks = _historyChunks();
        require(
            chunks.length == (uint256(BUYS) + uint256(SELLS) + 255) / 256, "chunk count mismatch"
        );

        vm.startBroadcast();

        // Step 1: deploy.
        LiquidityLayerAutoForwardExtension ext = new LiquidityLayerAutoForwardExtension(
            HOOK, LP_LOCKER, FEE_LOCKER, PFC, BURN_ROUTER, msg.sender
        );
        console2.log("Deployed extension at ", address(ext));

        // Step 2: allowlist.
        IAllowlist(allowlist).setPoolExtension(address(ext), true);
        require(IAllowlist(allowlist).enabledExtensions(address(ext)), "allowlist failed");
        console2.log("Allowlisted");

        // Step 3: wire into LAYER's pool.
        ILayerHook(HOOK).setPoolExtension(pk, address(ext), "");
        require(ILayerHook(HOOK).poolExtension(pid) == address(ext), "swap-in failed");
        require(ext.tokenForPool(pid) == LAYER, "init not run");
        console2.log("setPoolExtension OK");

        // Step 4: seed counters.
        ext.seedCounters(pid, BUYS, SELLS);
        (uint128 b, uint128 s) = ext.counts(pid);
        require(b == BUYS && s == SELLS, "seed counters mismatch");
        console2.log("Counters seeded:", b, s);

        // Step 5: seed history.
        ext.seedHistory(pid, chunks);
        require(ext.tradeChunk(pid, 0) == chunks[0], "chunk 0 mismatch");
        console2.log("History seeded:", chunks.length, "chunks");

        vm.stopBroadcast();

        console2.log("");
        console2.log("Done. Extension:", address(ext));
        console2.log(
            "Total trades now reading from on-chain counter:", uint256(BUYS) + uint256(SELLS)
        );
    }
}
