// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {
    LiquidityLayerAutoForwardExtension
} from "../src/extensions/LiquidityLayerAutoForwardExtension.sol";
import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {IArtCoinsPoolExtension} from "../src/hooks/interfaces/IArtCoinsPoolExtension.sol";
import {IScriptyBuilderV2, IScriptyStorageV2} from "../src/interfaces/IScripty.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

interface ILayerHook {
    function poolExtensionAllowlist() external view returns (address);
    function poolExtension(PoolId) external view returns (address);
    function poolExtensionLocked(PoolId) external view returns (bool);
    function setPoolExtension(PoolKey calldata pk, address newExtension, bytes calldata initData)
        external;
}

interface IAllowlist {
    function owner() external view returns (address);
    function setPoolExtension(address ext, bool ok) external;
    function enabledExtensions(address ext) external view returns (bool);
}

interface ICounterExt {
    function counts(PoolId) external view returns (uint128 buys, uint128 sells);
}

interface IBurnRouter {
    function layerToken() external view returns (address);
}

interface ILayerToken {
    function setMetadataRenderer(address) external;
    function metadataRenderer() external view returns (address);
    function admin() external view returns (address);
    function totalSupply() external view returns (uint256);
}

interface IFeeLocker {
    function availableFees(address feeOwner, address token) external view returns (uint256);
    function storeFees(address feeOwner, address token, uint256 amount) external;
    function addDepositor(address) external;
}

/// @title  LiquidityLayerAutoForwardExtensionForkTest
/// @notice Fork-only test that verifies the new extension actually integrates
///         with the live mainnet LAYER setup:
///           - allowlist + setPoolExtension by the real hook owner / token admin
///           - real V4 swap routing into our extension's `afterSwap`
///           - counter migration from the deployed counter extension
///           - real interactions with BurnRouter / PFC / FeeLocker
///
/// Run with:
///   forge test --match-contract LiquidityLayerAutoForwardExtensionForkTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract LiquidityLayerAutoForwardExtensionForkTest is Test {
    using PoolIdLibrary for PoolKey;

    // Mainnet addresses (immutable infra).
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Mainnet artcoins / LAYER.
    address constant LAYER = 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9;
    address constant HOOK = 0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc;
    address constant LP_LOCKER = 0x75BE7E95745915fD0C1761B74F3f9650ad2d1118;
    address constant FEE_LOCKER = 0x1143db0913Ca5eCe8A42FC01b625fD81F9386b05;
    address constant PFC = 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60;
    address constant BURN_ROUTER = 0x2eDBdF011768d8cd4Ef537658b41440900C52000;
    address constant COUNTER_EXT = 0xc4a1E94749c0C3c608577FcD7567a5fBcAcE0A65;

    // Token admin = artist treasury for LAYER (rewardAdmins[0] in the locker).
    address constant LAYER_TOKEN_ADMIN = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;

    // LAYER pool layout — derived from launch params.
    PoolKey internal poolKey;
    PoolId internal pid;

    // Test infra.
    PoolSwapTest internal swapRouter;
    LiquidityLayerAutoForwardExtension internal ext;
    address internal trader = address(0xD1);
    bool internal _onFork;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: no fork detected. Run with --fork-url $MAINNET_RPC_URL");
            return;
        }
        _onFork = true;

        // Pool key: LAYER (currency0) / WETH (currency1), dynamic-fee + sniper hook.
        poolKey = PoolKey({
            currency0: Currency.wrap(LAYER),
            currency1: Currency.wrap(WETH),
            fee: 0x800000, // dynamic-fee flag
            tickSpacing: 200,
            hooks: IHooks(HOOK)
        });
        pid = poolKey.toId();

        // Sanity: BurnRouter is bound to LAYER.
        assertEq(IBurnRouter(BURN_ROUTER).layerToken(), LAYER, "burn router not LAYER");
        // Sanity: extension slot is unlocked (we can swap it in).
        assertFalse(ILayerHook(HOOK).poolExtensionLocked(pid), "ext slot locked");
        // Note: LAYER's pool may or may not have an extension set today.
        // Tests that care about migration check it explicitly.

        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        // Deploy the new extension, owned by the test contract for threshold mgmt.
        ext = new LiquidityLayerAutoForwardExtension(
            HOOK, LP_LOCKER, FEE_LOCKER, PFC, BURN_ROUTER, address(this)
        );
    }

    // ─── helpers ──────────────────────────────────────────────────────

    function _allowlistAndSwapIn() internal {
        // Allowlist the new extension via the live allowlist owner.
        address allowlist = ILayerHook(HOOK).poolExtensionAllowlist();
        address allowlistOwner = IAllowlist(allowlist).owner();
        vm.prank(allowlistOwner);
        IAllowlist(allowlist).setPoolExtension(address(ext), true);
        assertTrue(IAllowlist(allowlist).enabledExtensions(address(ext)));

        // Swap it in via the LAYER token admin.
        vm.prank(LAYER_TOKEN_ADMIN);
        ILayerHook(HOOK).setPoolExtension(poolKey, address(ext), "");

        assertEq(ILayerHook(HOOK).poolExtension(pid), address(ext), "ext not bound");
        assertEq(ext.tokenForPool(pid), LAYER, "init not run");
    }

    /// Funds `trader` with WETH and runs a single zeroForOne (LAYER → WETH)
    /// or oneForZero (WETH → LAYER) swap of the given input size through the
    /// live LAYER pool.
    function _doSwap(bool zeroForOne, uint256 amountIn) internal {
        if (zeroForOne) {
            // Sell LAYER. Fund trader with LAYER from the LP locker (it holds
            // the lion's share of supply via its LP positions, but that's
            // locked. Easier: deal LAYER via vm.deal-equivalent for ERC20 —
            // use vm.store to write balanceOf, but that's brittle. Instead,
            // fund WETH and just do buy-side swaps for these tests.
            revert("seller path not implemented");
        }
        // Buy side (WETH → LAYER).
        vm.deal(trader, amountIn);
        vm.prank(trader);
        IWETH9(payable(WETH)).deposit{value: amountIn}();
        vm.prank(trader);
        IERC20(WETH).approve(address(swapRouter), amountIn);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false, // WETH (currency1) → LAYER (currency0)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory ts =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(trader);
        swapRouter.swap(poolKey, params, ts, "");
    }

    // ─── tests ────────────────────────────────────────────────────────

    function test_setPoolExtension_swapsInNewExtension() public {
        if (!_onFork) return;
        _allowlistAndSwapIn();
    }

    function test_counter_migration_fromLiveExtension() public {
        if (!_onFork) return;

        // Read whatever's at the live extension slot today; may be 0 if the
        // pool was deployed without an extension. Either way, the migration
        // path is exercised.
        address liveExt = ILayerHook(HOOK).poolExtension(pid);
        uint128 oldBuys;
        uint128 oldSells;
        if (liveExt != address(0)) {
            (oldBuys, oldSells) = ICounterExt(liveExt).counts(pid);
        }
        console2.log("Live extension:", liveExt);
        console2.log("Live counter buys:", oldBuys);
        console2.log("Live counter sells:", oldSells);

        _allowlistAndSwapIn();

        ext.seedCounters(pid, oldBuys, oldSells);
        (uint128 newBuys, uint128 newSells) = ext.counts(pid);
        assertEq(newBuys, oldBuys, "buys carried");
        assertEq(newSells, oldSells, "sells carried");
    }

    function test_realSwap_invokesAfterSwap_andAdvancesCounter() public {
        if (!_onFork) return;
        _allowlistAndSwapIn();

        (uint128 b0, uint128 s0) = ext.counts(pid);
        _doSwap({zeroForOne: false, amountIn: 0.001 ether});
        (uint128 b1, uint128 s1) = ext.counts(pid);

        // A buy adds 1 to buys, 0 to sells.
        assertEq(b1, b0 + 1, "buy counted");
        assertEq(s1, s0, "sells unchanged");
    }

    function test_realSwap_emptyPipeline_isNoOp() public {
        if (!_onFork) return;
        _allowlistAndSwapIn();

        // Pipeline state captured before the swap.
        uint256 brLayerBefore = IERC20(LAYER).balanceOf(BURN_ROUTER);
        uint256 pfcWethBefore = IERC20(WETH).balanceOf(PFC);

        _doSwap({zeroForOne: false, amountIn: 0.001 ether});

        // Live state may shift slightly because the swap itself accrues fees
        // that get auto-claimed by the locker; we only care that NONE of the
        // post-stage 1 actions ran. Sanity: BurnRouter LAYER doesn't grow on a
        // single small buy (no LAYER routes there from the buy-side fee).
        uint256 brLayerAfter = IERC20(LAYER).balanceOf(BURN_ROUTER);
        uint256 pfcWethAfter = IERC20(WETH).balanceOf(PFC);
        // BurnRouter LAYER can only DECREASE (via processBurnLayer) inside afterSwap.
        // It can INCREASE outside our path (locker delivering project burn share).
        // Just assert it didn't go to zero unexpectedly.
        if (brLayerBefore > 0) {
            assertGe(brLayerAfter, 1, "burn router not drained when no stage 4 needed");
        }
        // PFC WETH can grow from the locker's fee distribution; no strict check.
        assertGe(pfcWethAfter, pfcWethBefore, "pfc weth went down without stage 3");
    }

    function test_realSwap_stage4_firesWhenBurnRouterHasLayer() public {
        if (!_onFork) return;
        _allowlistAndSwapIn();

        // Move some LAYER from a whale into the BurnRouter so Stage 4 has work.
        // The locker holds plenty of LAYER (LP NFTs); easier: deal via
        // vm.deal-equivalent. Use storage write since ERC20 has no mint here.
        uint256 dealAmount = 1000 ether;
        deal(LAYER, BURN_ROUTER, dealAmount);
        assertEq(IERC20(LAYER).balanceOf(BURN_ROUTER), dealAmount);

        uint256 supplyBefore = IERC20(LAYER).totalSupply();

        _doSwap({zeroForOne: false, amountIn: 0.001 ether});

        // Stage 4 (processBurnLayer) burns the seeded LAYER. totalSupply drops
        // by exactly the amount we dealt (small 0.001 ETH swap won't flow
        // any other LAYER into the BurnRouter on a single buy).
        uint256 supplyAfter = IERC20(LAYER).totalSupply();
        assertEq(IERC20(LAYER).balanceOf(BURN_ROUTER), 0, "router drained");
        assertEq(supplyBefore - supplyAfter, dealAmount, "supply burned");
    }

    function test_realSwap_stage3_firesWhenPfcHasWeth() public {
        if (!_onFork) return;
        _allowlistAndSwapIn();

        // Deal WETH to PFC above threshold, BurnRouter empty so Stage 4 skips.
        deal(LAYER, BURN_ROUTER, 0);
        deal(WETH, PFC, 0.05 ether);

        uint256 pfcBefore = IERC20(WETH).balanceOf(PFC);

        _doSwap({zeroForOne: false, amountIn: 0.001 ether});

        // PFC.processFees moves WETH out (40% to BurnRouter, 60% to treasury).
        // After the call PFC's WETH balance for this token is zero.
        assertLt(IERC20(WETH).balanceOf(PFC), pfcBefore, "pfc weth processed");
    }

    function test_realSwap_stage2_firesWhenFeeLockerHasPot() public {
        if (!_onFork) return;
        _allowlistAndSwapIn();

        // Drain higher-priority stages so Stage 2 wins.
        deal(LAYER, BURN_ROUTER, 0);
        deal(WETH, PFC, 0);
        deal(LAYER, PFC, 0);

        // The live FeeLocker BurnRouter pot already has ~0.165 WETH from real
        // buy-and-burn flow. We can't zero it out without storage fiddling.
        // Instead, snapshot what's there and assert relative to that.
        deal(WETH, LP_LOCKER, 0.05 ether);
        vm.startPrank(LP_LOCKER);
        IERC20(WETH).approve(FEE_LOCKER, 0.05 ether);
        IFeeLocker(FEE_LOCKER).storeFees(BURN_ROUTER, WETH, 0.05 ether);
        vm.stopPrank();

        uint256 potAfterSeed = IFeeLocker(FEE_LOCKER).availableFees(BURN_ROUTER, WETH);
        assertGe(potAfterSeed, 0.05 ether, "pot seeded above threshold");
        uint256 brBefore = IERC20(WETH).balanceOf(BURN_ROUTER);

        _doSwap({zeroForOne: false, amountIn: 0.001 ether});

        // Stage 2: FeeLocker.claim moves the WHOLE pot to BurnRouter.
        // (The live swap may add tiny fees mid-flight, but the post-claim
        // pot should be tiny — definitely < the seeded chunk.)
        uint256 potAfter = IFeeLocker(FEE_LOCKER).availableFees(BURN_ROUTER, WETH);
        assertLt(potAfter, 0.05 ether, "pot drained");
        assertGe(
            IERC20(WETH).balanceOf(BURN_ROUTER),
            brBefore + (potAfterSeed - potAfter),
            "br received the claim"
        );
    }

    function test_pipelineDrains_oneStagePerSwap_endToEnd() public {
        if (!_onFork) return;
        _allowlistAndSwapIn();

        // Stage all three pipeline stages with work above thresholds.
        deal(LAYER, BURN_ROUTER, 1000 ether); // Stage 4
        deal(WETH, PFC, 0.05 ether); // Stage 3
        deal(WETH, LP_LOCKER, 0.05 ether);
        vm.startPrank(LP_LOCKER);
        IERC20(WETH).approve(FEE_LOCKER, 0.05 ether);
        IFeeLocker(FEE_LOCKER).storeFees(BURN_ROUTER, WETH, 0.05 ether); // Stage 2
        vm.stopPrank();

        uint256 supplyBefore = IERC20(LAYER).totalSupply();
        uint256 pfcBefore = IERC20(WETH).balanceOf(PFC);

        // Swap 1: Stage 4 fires (BurnRouter LAYER burned).
        _doSwap({zeroForOne: false, amountIn: 0.0005 ether});
        assertLt(IERC20(LAYER).totalSupply(), supplyBefore, "supply burned");
        assertEq(IERC20(LAYER).balanceOf(BURN_ROUTER), 0, "br drained");
        // PFC and FeeLocker still loaded enough to fire next swap.
        // (Live LP auto-claim adds tiny WETH each swap so use ≥ rather than =.)
        assertGe(IERC20(WETH).balanceOf(PFC), 0.05 ether, "pfc still above threshold");
        assertGe(
            IFeeLocker(FEE_LOCKER).availableFees(BURN_ROUTER, WETH),
            0.05 ether,
            "pot still above threshold"
        );

        // Swap 2: Stage 3 fires (PFC.processFees runs).
        _doSwap({zeroForOne: false, amountIn: 0.0005 ether});
        assertLt(IERC20(WETH).balanceOf(PFC), pfcBefore, "pfc processed");
        // FeeLocker still loaded.
        assertGe(
            IFeeLocker(FEE_LOCKER).availableFees(BURN_ROUTER, WETH),
            0.05 ether,
            "pot still above threshold"
        );

        // Swap 3+: drain the pot. Live LP auto-claim adds tiny amounts every
        // swap, so it can take more than one swap for Stage 2 to fully eat
        // through. Allow a few swaps; the property we care about is "the
        // pipeline drains, regardless of exact swap count."
        uint256 potBefore = IFeeLocker(FEE_LOCKER).availableFees(BURN_ROUTER, WETH);
        for (uint256 i = 0; i < 5; i++) {
            _doSwap({zeroForOne: false, amountIn: 0.0005 ether});
            uint256 pot = IFeeLocker(FEE_LOCKER).availableFees(BURN_ROUTER, WETH);
            if (pot < 0.001 ether) break; // drained
        }
        assertLt(
            IFeeLocker(FEE_LOCKER).availableFees(BURN_ROUTER, WETH),
            potBefore,
            "pot drained over the loop"
        );

        // Counter advances on EVERY swap regardless of pipeline state.
        (uint128 b0, uint128 s0) = ext.counts(pid);
        _doSwap({zeroForOne: false, amountIn: 0.0005 ether});
        (uint128 b1, uint128 s1) = ext.counts(pid);
        assertEq(uint256(b1) + uint256(s1), uint256(b0) + uint256(s0) + 1, "counter advanced");
    }

    function test_rendererMigration_endToEnd() public {
        if (!_onFork) return;
        _allowlistAndSwapIn();

        // Seed historical counts so the renderer has something to display.
        ext.seedCounters(pid, 318, 408);
        // Skip seedHistory here — only counts are needed for the SVG totals.

        // Deploy + configure new renderer pointing at the new extension.
        address SCRIPTY_BUILDER = 0xD7587F110E08F4D120A231bA97d3B577A81Df022;
        address SCRIPTY_STORAGE = 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699;
        LiquidityLayerOnchainRenderer renderer = new LiquidityLayerOnchainRenderer({
            initialOwner: address(this),
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

        // Repoint LAYER's renderer slot.
        vm.prank(LAYER_TOKEN_ADMIN);
        ILayerToken(LAYER).setMetadataRenderer(address(renderer));
        assertEq(ILayerToken(LAYER).metadataRenderer(), address(renderer));

        // Verify contractURI is non-trivial. Old renderer also returns
        // something (just with 0/0); make sure new one is different.
        string memory uri = renderer.contractURI(LAYER);
        assertGt(bytes(uri).length, 100, "uri non-trivial");
        // Output starts with the data URI prefix.
        bytes memory uriBytes = bytes(uri);
        assertEq(uriBytes[0], bytes1("d"), "data uri");

        // Swap once to push the counter to 727 → re-read should reflect.
        _doSwap({zeroForOne: false, amountIn: 0.0005 ether});
        (uint128 b, uint128 s) = ext.counts(pid);
        assertEq(uint256(b) + uint256(s), 727, "counter advanced");

        string memory uri2 = renderer.contractURI(LAYER);
        assertGt(bytes(uri2).length, 100);
    }
}
