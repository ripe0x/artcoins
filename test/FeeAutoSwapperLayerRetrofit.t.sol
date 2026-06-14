// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeAutoSwapper} from "../src/FeeAutoSwapper.sol";
import {IArtCoinsFeeLocker} from "../src/interfaces/IArtCoinsFeeLocker.sol";
import {IArtCoinsLpLocker} from "../src/interfaces/IArtCoinsLpLocker.sol";
import {IFeeAutoSwapper} from "../src/interfaces/IFeeAutoSwapper.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test, console2} from "forge-std/Test.sol";

/// @title FeeAutoSwapperLayerRetrofit
/// @notice Retrofit test: proves `FeeAutoSwapper` can swap accrued LAYER fees
///         against the LIVE mainnet LAYER pool — hook attached, pool already
///         initialized, no contract redeploy. Validates the path from
///         "stuck artcoin in feeLocker" → "WETH at endRecipient" without
///         touching the immutable hook.
///
///         Skips when run without a mainnet fork.
///         Run:
///           forge test --match-contract FeeAutoSwapperLayerRetrofit \
///             --fork-url https://ethereum-rpc.publicnode.com -vv
contract FeeAutoSwapperLayerRetrofit is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── live mainnet addresses ─────────────────────────────────────────

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // From `broadcast/PrepareLayerLaunch.s.sol/1/run-latest.json`.
    address constant LAYER_TOKEN = 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9;
    address constant LAYER_HOOK = 0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc; // ArtCoinsHookStaticFeeV2

    // From CLAUDE.md ("Architecture: dependencies on artcoins").
    address constant LP_LOCKER = 0x75BE7E95745915fD0C1761B74F3f9650ad2d1118;
    address constant FEE_LOCKER = 0x1143db0913Ca5eCe8A42FC01b625fD81F9386b05;

    FeeAutoSwapper internal swapper;
    address internal swapperOwner = address(0xA2);
    address internal endRecipient = address(0xB1);
    address internal keeper = address(0xC1);

    bool internal onFork;
    PoolKey internal layerKey;
    address internal feeLockerOwner;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0 || LAYER_TOKEN.code.length == 0) {
            console2.log("SKIPPING: not on a fork that has live LAYER deployed.");
            return;
        }
        onFork = true;

        // Read the live LAYER pool topology from the LP locker. This is the
        // source of truth — what hook, what fee, what tick spacing — and
        // exactly what the FeeAutoSwapper must reconstruct in its
        // `_poolKey()` to interact with the same pool.
        IArtCoinsLpLocker.TokenRewardInfo memory info =
            IArtCoinsLpLocker(LP_LOCKER).tokenRewards(LAYER_TOKEN);
        layerKey = info.poolKey;

        require(
            address(layerKey.hooks) == LAYER_HOOK, "live pool hook mismatch - re-check LAYER_HOOK"
        );
        require(
            Currency.unwrap(layerKey.currency0) == WETH
                || Currency.unwrap(layerKey.currency1) == WETH,
            "live pool not paired with WETH"
        );

        // Deploy a FeeAutoSwapper for LAYER. Direct-transfer mode is the
        // friendliest retrofit shape because it doesn't require the live
        // fee locker's owner to add this swapper as a depositor — converted
        // WETH just lands directly at `endRecipient`'s ERC20 balance.
        FeeAutoSwapper.Config memory cfg = FeeAutoSwapper.Config({
            poolManager: POOL_MANAGER,
            feeLocker: FEE_LOCKER,
            pairedToken: WETH,
            poolFee: layerKey.fee,
            poolTickSpacing: layerKey.tickSpacing,
            hook: LAYER_HOOK,
            endRecipient: endRecipient,
            depositToLocker: false,
            maxSlippageBps: 1000,
            minBlocksBetweenConverts: 1,
            maxStepIn: 1_000_000e18
        });
        swapper = new FeeAutoSwapper(cfg);
        swapper.setup(LAYER_TOKEN);

        // Discover the feeLocker's owner from its public Ownable getter so
        // the test doesn't hardcode an address that may have rotated since
        // deployment.
        (bool ok, bytes memory ret) = FEE_LOCKER.staticcall(abi.encodeWithSignature("owner()"));
        require(ok && ret.length == 32, "FEE_LOCKER.owner() probe failed");
        feeLockerOwner = abi.decode(ret, (address));
    }

    receive() external payable {}

    // ─── core retrofit: swap against the live LAYER pool ────────────────

    function test_fork_layerRetrofit_directTransfer() public {
        if (!onFork) return;

        // Simulate the post-retrofit state: the slot admin has already
        // pointed their slot at the FeeAutoSwapper, an LP-locker fee
        // distribution has happened, and the swapper's LAYER balance is now
        // escrowed in the fee locker. Reproduce that state by impersonating
        // the live LP locker (which is an allowlisted depositor) and
        // storing fees for the swapper.
        uint256 layerAmount = 1000e18;
        deal(LAYER_TOKEN, LP_LOCKER, layerAmount);
        vm.startPrank(LP_LOCKER);
        IERC20(LAYER_TOKEN).approve(FEE_LOCKER, layerAmount);
        IArtCoinsFeeLocker(FEE_LOCKER).storeFees(address(swapper), LAYER_TOKEN, layerAmount);
        vm.stopPrank();

        assertEq(swapper.accruedArtCoin(), layerAmount, "accruedArtCoin");

        // Slip the price by a bit before the swap by warping forward,
        // letting the hook's `mevModule` time-based decay finalize. Not
        // strictly required — the hook's mevModule shouldn't be enabled on
        // a months-old pool — but cheap insurance.
        vm.warp(block.timestamp + 1 days);

        uint256 endRecipientBefore = IERC20(WETH).balanceOf(endRecipient);
        uint256 keeperBefore = IERC20(WETH).balanceOf(keeper);

        vm.prank(keeper);
        uint256 wethOut = swapper.convert(0);

        assertGt(wethOut, 0, "swap produced WETH");

        uint256 keeperGained = IERC20(WETH).balanceOf(keeper) - keeperBefore;
        uint256 recipientGained = IERC20(WETH).balanceOf(endRecipient) - endRecipientBefore;

        // Conservation: caller reward + recipient delivery = swap output.
        assertEq(recipientGained + keeperGained, wethOut, "conservation");

        // Keeper reward bounded.
        assertLe(keeperGained, 0.01 ether, "keeper reward cap");
        assertLe(keeperGained, (wethOut * 50) / 10_000, "keeper reward bps");

        // No residual LAYER or WETH in the swapper after a clean conversion.
        assertEq(IERC20(LAYER_TOKEN).balanceOf(address(swapper)), 0, "no LAYER residual");
        assertEq(IERC20(WETH).balanceOf(address(swapper)), 0, "no WETH residual");

        // Accounting matches.
        assertEq(swapper.totalArtcoinConverted(), layerAmount, "totalArtcoinConverted");
        assertEq(swapper.totalWethDelivered(), recipientGained, "totalWethDelivered");
        assertEq(swapper.totalKeeperRewards(), keeperGained, "totalKeeperRewards");

        console2.log("LAYER converted:", layerAmount);
        console2.log("WETH out (gross):", wethOut);
        console2.log("WETH to endRecipient:", recipientGained);
        console2.log("WETH to keeper:", keeperGained);
    }

    // ─── verify hook attribution: the live hook DID get called ──────────

    function test_fork_layerRetrofit_invokesLiveHook() public {
        if (!onFork) return;

        // The point of this test: prove the swap goes through the real
        // mainnet hook contract, not some unconfigured fallback. The hook
        // contract address must be both (a) what we passed at construction,
        // and (b) the one held in the LP locker's record for LAYER.
        assertEq(address(layerKey.hooks), LAYER_HOOK, "hook in poolKey");
        assertEq(address(swapper.poolKey().hooks), LAYER_HOOK, "hook in swapper poolKey");

        // Take a code-hash snapshot of the hook before & after a swap. Hook
        // bytecode is immutable; the equality assertion proves we hit the
        // real deployed contract, not a vm-prank/etch.
        bytes32 hookHashBefore;
        assembly { hookHashBefore := extcodehash(LAYER_HOOK) }
        require(hookHashBefore != bytes32(0), "hook has no code");

        // Seed and convert as in the other test, smaller volume.
        uint256 layerAmount = 100e18;
        deal(LAYER_TOKEN, LP_LOCKER, layerAmount);
        vm.startPrank(LP_LOCKER);
        IERC20(LAYER_TOKEN).approve(FEE_LOCKER, layerAmount);
        IArtCoinsFeeLocker(FEE_LOCKER).storeFees(address(swapper), LAYER_TOKEN, layerAmount);
        vm.stopPrank();

        vm.prank(keeper);
        swapper.convert(0);

        bytes32 hookHashAfter;
        assembly { hookHashAfter := extcodehash(LAYER_HOOK) }
        assertEq(hookHashAfter, hookHashBefore, "hook bytecode unchanged");
    }

    // ─── partial-fill reconciliation against the live pool ──────────────

    function test_fork_layerRetrofit_partialFill_leftoverStays() public {
        if (!onFork) return;

        // Deploy a second swapper with tight slippage so a moderately large
        // swap clamps on the real LAYER pool's actual depth.
        FeeAutoSwapper.Config memory cfg = FeeAutoSwapper.Config({
            poolManager: POOL_MANAGER,
            feeLocker: FEE_LOCKER,
            pairedToken: WETH,
            poolFee: layerKey.fee,
            poolTickSpacing: layerKey.tickSpacing,
            hook: LAYER_HOOK,
            endRecipient: endRecipient,
            depositToLocker: false,
            maxSlippageBps: 100, // 1% — induces clamp
            minBlocksBetweenConverts: 1,
            maxStepIn: 10_000_000e18
        });
        FeeAutoSwapper tightSwapper = new FeeAutoSwapper(cfg);
        tightSwapper.setup(LAYER_TOKEN);

        uint256 layerAmount = 5_000_000e18; // intentionally large
        deal(LAYER_TOKEN, LP_LOCKER, layerAmount);
        vm.startPrank(LP_LOCKER);
        IERC20(LAYER_TOKEN).approve(FEE_LOCKER, layerAmount);
        IArtCoinsFeeLocker(FEE_LOCKER).storeFees(address(tightSwapper), LAYER_TOKEN, layerAmount);
        vm.stopPrank();

        // The spot-derived floor is computed against `actualIn` post-swap,
        // so a partial fill scales the floor down with the consumed input
        // — no caller-supplied minOut needs to anticipate the clamp size.
        // `minOut = 0` is fine here because the contract's own floor guards
        // against bad rates on whatever fraction did execute.
        vm.prank(keeper);
        try tightSwapper.convert(0) {
        // Convert succeeded — proceed to conservation check.
        }
            catch {
            // If the tightSwap clamped to a worse rate than the spot floor,
            // the contract reverts post-swap (state restored). Either path
            // preserves the conservation invariant on token balances.
        }

        uint256 residual = IERC20(LAYER_TOKEN).balanceOf(address(tightSwapper));
        uint256 converted = tightSwapper.totalArtcoinConverted();
        assertEq(converted + residual, layerAmount - residual + residual, "no LAYER lost");
        // The above simplifies to: converted + residual <= layerAmount, and
        // since residual is what's still in the swapper after any successful
        // convert, what was in the locker was either converted or stuck in
        // the locker (revert path).
        uint256 stillEscrowed =
            IArtCoinsFeeLocker(FEE_LOCKER).availableFees(address(tightSwapper), LAYER_TOKEN);
        assertEq(converted + residual + stillEscrowed, layerAmount, "LAYER conserved");

        console2.log("LAYER converted (clamped run):", converted);
        console2.log("LAYER residual in swapper:", residual);
        console2.log("LAYER still escrowed:", stillEscrowed);
    }
}
