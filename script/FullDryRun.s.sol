// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {
    LiquidityLayerAutoForwardExtension
} from "../src/extensions/LiquidityLayerAutoForwardExtension.sol";
import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";

import {IScriptyBuilderV2, IScriptyStorageV2} from "../src/interfaces/IScripty.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

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

interface ILayerToken {
    function setMetadataRenderer(address) external;
    function metadataRenderer() external view returns (address);
    function totalSupply() external view returns (uint256);
}

/// @title  FullDryRun
/// @notice Single-script end-to-end dry run on a mainnet fork. Executes
///         Phase 2 + Phase 3 in one process so we can do a real V4 swap
///         right after wire-in and confirm every assertion in one trace.
///
/// Usage:
///   forge script script/FullDryRun.s.sol --fork-url $MAINNET_RPC_URL \
///     --sender 0xCB43078C32423F5348Cab5885911C3B5faE217F9 -vv
contract FullDryRun is Script, StdCheats {
    using PoolIdLibrary for PoolKey;

    address constant LAYER = 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant HOOK = 0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc;
    address constant LP_LOCKER = 0x75BE7E95745915fD0C1761B74F3f9650ad2d1118;
    address constant FEE_LOCKER = 0x1143db0913Ca5eCe8A42FC01b625fD81F9386b05;
    address constant PFC = 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60;
    address constant BURN_ROUTER = 0x2eDBdF011768d8cd4Ef537658b41440900C52000;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    address constant SCRIPTY_BUILDER = 0xD7587F110E08F4D120A231bA97d3B577A81Df022;
    address constant SCRIPTY_STORAGE = 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699;

    address constant LAYER_TOKEN_ADMIN = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;

    uint128 constant BUYS = 318;
    uint128 constant SELLS = 408;

    function _layerPoolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(LAYER),
            currency1: Currency.wrap(WETH),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(HOOK)
        });
    }

    function _historyChunks() internal pure returns (uint256[] memory c) {
        c = new uint256[](3);
        c[0] = 0x3a3f8fc323303478c64ab69dfb1180e3ac00e11ea00008056004a008c800000;
        c[1] = 0x0064088cc9e67001655a6ab9620057fed53fee88377d7a08200330d1174fdeff;
        c[2] = 0xff00000000002da7df67fba372020203c3aa0f9fff90175cfbe0c067acd62314;
    }

    function run() external {
        PoolKey memory pk = _layerPoolKey();
        PoolId pid = pk.toId();
        address allowlist = ILayerHook(HOOK).poolExtensionAllowlist();

        console2.log("=== FULL DRY RUN ===");
        console2.log("Sender:", msg.sender);
        console2.log("");

        // ─── Phase 2: extension ────────────────────────────────────────

        console2.log("--- Phase 2: extension wire-in + backfill ---");
        vm.startBroadcast();
        LiquidityLayerAutoForwardExtension ext = new LiquidityLayerAutoForwardExtension(
            HOOK, LP_LOCKER, FEE_LOCKER, PFC, BURN_ROUTER, msg.sender
        );
        console2.log("ext deployed:        ", address(ext));

        IAllowlist(allowlist).setPoolExtension(address(ext), true);
        require(IAllowlist(allowlist).enabledExtensions(address(ext)), "allowlist");
        console2.log("ext allowlisted");

        ILayerHook(HOOK).setPoolExtension(pk, address(ext), "");
        require(ILayerHook(HOOK).poolExtension(pid) == address(ext), "swap-in");
        require(ext.tokenForPool(pid) == LAYER, "init");
        console2.log("ext wired into LAYER pool");

        ext.seedCounters(pid, BUYS, SELLS);
        ext.seedHistory(pid, _historyChunks());
        (uint128 b, uint128 s) = ext.counts(pid);
        require(b == BUYS && s == SELLS, "seed");
        console2.log("counter seeded:", b, "buys,", s);
        console2.log("sells:", s);
        vm.stopBroadcast();

        // ─── Phase 3: renderer ─────────────────────────────────────────

        console2.log("");
        console2.log("--- Phase 3: renderer migration ---");
        vm.startBroadcast();
        LiquidityLayerOnchainRenderer renderer = new LiquidityLayerOnchainRenderer({
            initialOwner: msg.sender,
            counter_: LiquidityLayerCounterPoolExtension(address(ext)),
            scriptyBuilder_: IScriptyBuilderV2(SCRIPTY_BUILDER),
            scriptyStorage_: IScriptyStorageV2(SCRIPTY_STORAGE),
            sketchScriptName_: "ll/sketch.b64.1778120217836",
            monaAssetName_: "ll/mona.1778120217836",
            monaMimeType_: "image/jpeg",
            projectDescription_: "Until nothing remains but speculation"
        });
        renderer.setHistoryAsset("ll/history.b64.1778120217836");
        renderer.setImageOverrideUri(
            "ipfs://bafkreiguuln4aa23vdrsx53ashjqxcrst2oms7mow2bu7u2axvncmkikiu"
        );
        renderer.setSupplyConfig(1_000_000_000 * 1e18, 18);
        console2.log("renderer deployed:   ", address(renderer));

        ILayerToken(LAYER).setMetadataRenderer(address(renderer));
        require(
            ILayerToken(LAYER).metadataRenderer() == address(renderer), "metadataRenderer not set"
        );
        console2.log("LAYER.metadataRenderer set");
        vm.stopBroadcast();

        // ─── Real V4 swap → afterSwap fires ────────────────────────────

        console2.log("");
        console2.log("--- Live swap: empty pipeline (counter only) ---");
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        address trader = address(0xD1);
        deal(WETH, trader, 1 ether);

        vm.startPrank(trader);
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory ts =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(pk, params, ts, "");
        vm.stopPrank();

        (uint128 b1, uint128 s1) = ext.counts(pid);
        console2.log("counter after empty swap:", b1, "buys,", s1);
        console2.log("sells:", s1);
        require(uint256(b1) + uint256(s1) == 727, "counter advanced");

        // ─── Live swap with Stage 4 ready ──────────────────────────────

        console2.log("");
        console2.log("--- Live swap: Stage 4 fires (BurnRouter has LAYER) ---");
        deal(LAYER, BURN_ROUTER, 1000 ether);
        uint256 supplyBefore = IERC20(LAYER).totalSupply();

        vm.prank(trader);
        swapRouter.swap(pk, params, ts, "");

        uint256 supplyAfter = IERC20(LAYER).totalSupply();
        require(supplyBefore - supplyAfter == 1000 ether, "stage 4 burn");
        require(IERC20(LAYER).balanceOf(BURN_ROUTER) == 0, "router drained");
        console2.log("LAYER burned:        ", supplyBefore - supplyAfter);
        console2.log("totalSupply now:     ", supplyAfter);

        // ─── Live swap with Stage 3 ready ──────────────────────────────

        console2.log("");
        console2.log("--- Live swap: Stage 3 fires (PFC has WETH) ---");
        deal(WETH, PFC, 0.05 ether);
        uint256 pfcBefore = IERC20(WETH).balanceOf(PFC);
        vm.prank(trader);
        swapRouter.swap(pk, params, ts, "");
        uint256 pfcAfter = IERC20(WETH).balanceOf(PFC);
        require(pfcAfter < pfcBefore, "stage 3 fired");
        console2.log("PFC WETH before:     ", pfcBefore);
        console2.log("PFC WETH after:      ", pfcAfter);

        // ─── Renderer outputs valid metadata ───────────────────────────

        console2.log("");
        console2.log("--- Renderer contractURI sanity ---");
        string memory uri = renderer.contractURI(LAYER);
        require(bytes(uri).length > 100, "uri non-trivial");
        console2.log("contractURI length:  ", bytes(uri).length);
        console2.log("first 80 chars:");
        bytes memory uriBytes = bytes(uri);
        bytes memory head = new bytes(80);
        for (uint256 i = 0; i < 80 && i < uriBytes.length; i++) {
            head[i] = uriBytes[i];
        }
        console2.log(string(head));

        console2.log("");
        console2.log("=== ALL CHECKS PASSED ===");
        console2.log("Extension address:   ", address(ext));
        console2.log("Renderer address:    ", address(renderer));
        console2.log("");
        console2.log("Mainnet broadcast commands (paste these):");
        console2.log("");
        console2.log("forge script script/SetUpLayerAutoForward.s.sol \\");
        console2.log("  --rpc-url $MAINNET_RPC_URL --broadcast \\");
        console2.log("  --account <ledger-or-keystore-name> -vvv");
        console2.log("");
        console2.log("# Then with the printed extension address:");
        console2.log("NEW_EXTENSION=<addr> forge script script/MigrateLayerRenderer.s.sol \\");
        console2.log("  --rpc-url $MAINNET_RPC_URL --broadcast \\");
        console2.log("  --account <ledger-or-keystore-name> -vvv");
    }
}
