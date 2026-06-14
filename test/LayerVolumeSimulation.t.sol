// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {LaunchDefaults} from "../script/LaunchDefaults.sol";

contract MintToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title LayerVolumeSimulation
/// @notice End-to-end resilience test: deploys Preset L on a mainnet fork
///         and walks ~80 mixed buy/sell trades through it (sniper-window
///         small buys, then mixed flow, then steady state). At each
///         milestone reports tier consumption, price, fee accruals and
///         simulated LAYER burn under the current fee architecture
///         (1% pool fee, 50% to burn, 50% to artist+treasury).
///
///         Pool runs WITHOUT the artcoins hook — this isolates LP-shape
///         behavior from hook side-effects so we can read pure curve
///         dynamics. Hook-level fee math is validated separately by
///         HookProtocolFeeNumeratorZeroTest + FeeMathReconciliationForkTest.
///
/// Run:
///   forge test --match-contract LayerVolumeSimulation \
///     --fork-url $MAINNET_RPC_URL -vv
contract LayerVolumeSimulationTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    int24 constant LAYER_STARTING_TICK = -190_400;
    uint256 constant LP_ALLOCATION = 639_800_000e18;
    uint24 constant POOL_FEE = LaunchDefaults.BUY_FEE; // 10_000 ppm = 1%

    PoolModifyLiquidityTest internal liqRouter;
    PoolSwapTest internal swapRouter;
    bool internal _onFork;
    bool internal _layerIsToken0;
    PoolKey internal poolKey;
    MintToken internal layer;

    // Sim state
    uint256 totalEthIn; // gross ETH paid by buyers (incl. anti-sniper fee)
    uint256 totalEthOut; // gross ETH received by sellers (post-fee)
    uint256 totalLayerBought; // LAYER actually delivered to buyers
    uint256 totalLayerSold; // LAYER actually surrendered by sellers
    uint256 totalAntiSniperFeeWei; // sum of "extra fee above 1%" charged
    uint256 totalNormalFeeWei; // sum of normal 1% pool fee charged

    // Per-buy capture telemetry (during sniper window only)
    uint256 captureCum_05;
    uint256 captureTickAt_05;
    uint256 captureCum_1;
    uint256 captureTickAt_1;
    uint256 captureCum_2;
    uint256 captureTickAt_2;
    uint256 captureCum_10;
    uint256 captureTickAt_10;
    bool _capturedSnap_05;
    bool _capturedSnap_1;
    bool _capturedSnap_2;
    bool _capturedSnap_10;

    // Per-tier mapping (12 positions of Preset L)
    int24[12] tierLowers;
    int24[12] tierUppers;
    uint16[12] tierBps;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: not on mainnet fork");
            return;
        }
        _onFork = true;

        layer = new MintToken("Liquidity Layer", "LAYER");
        liqRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        _layerIsToken0 = address(layer) < WETH;
        (address c0, address c1) = _layerIsToken0 ? (address(layer), WETH) : (WETH, address(layer));
        poolKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: LaunchDefaults.TICK_SPACING,
            hooks: IHooks(address(0))
        });

        int24 initTick = _layerIsToken0 ? LAYER_STARTING_TICK : -LAYER_STARTING_TICK;
        IPoolManager(POOL_MANAGER).initialize(poolKey, TickMath.getSqrtPriceAtTick(initTick));

        layer.mint(address(this), LP_ALLOCATION);
        IERC20(address(layer)).approve(address(liqRouter), type(uint256).max);
        IERC20(address(layer)).approve(address(swapRouter), type(uint256).max);

        // Whale wallet for the simulated trader.
        vm.deal(address(this), 5000 ether);
        IWETH9(payable(WETH)).deposit{value: 4000 ether}();
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);

        _seedPresetL();
    }

    receive() external payable {}

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    function _seedPresetL() internal {
        (int24[] memory tl, int24[] memory tu, uint16[] memory bps) =
            LaunchDefaults.buildLayerThinFloor12Positions(LAYER_STARTING_TICK);
        for (uint256 i = 0; i < 12; i++) {
            tierLowers[i] = tl[i];
            tierUppers[i] = tu[i];
            tierBps[i] = bps[i];
            uint256 amount = (LP_ALLOCATION * bps[i]) / 10_000;
            int24 lower;
            int24 upper;
            if (_layerIsToken0) {
                lower = tl[i];
                upper = tu[i];
            } else {
                lower = -tu[i];
                upper = -tl[i];
            }
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
            uint128 L = _layerIsToken0
                ? LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, amount)
                : LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, amount);
            liqRouter.modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: lower,
                    tickUpper: upper,
                    liquidityDelta: int256(uint256(L)),
                    salt: bytes32(0)
                }),
                ""
            );
        }
    }

    /// @notice Same flow as the baseline, but with stepped anti-sniper applied
    ///         during phase 1. Phase 1's 24 trades are bucketed into the
    ///         schedule's 5 fee tiers.
    function test_volume_realisticDay_withAntiSniper() public onlyFork {
        console2.log("");
        console2.log("======= LAYER PRESET L VOLUME SIM (anti-sniper ON) =======");
        console2.log("Setup notes:");
        console2.log("  - Sim models the MEV stepped fee schedule manually.");
        console2.log("    The pool itself runs at static 1% (no hook), and");
        console2.log("    each phase-1 buy has its input pre-reduced by the");
        console2.log("    extra fee for that minute. The reduction directly");
        console2.log("    represents the EXTRA portion that the live");
        console2.log("    ArtCoinsMevSniperSteppedFees module would skim and");
        console2.log("    route 100% to BurnRouter via the new sniper-extra");
        console2.log("    fee path on the hook.");
        console2.log("  - protocolFeeNumerator: 0 (asserted in launch script");
        console2.log("    + HookProtocolFeeNumeratorZero fork test). Trader");
        console2.log("    pays exactly the active fee (no hook double-skim).");
        console2.log("  - Anti-sniper schedule: 50/25/15/7/3% over 15 min,");
        console2.log("    then 1% normal. After-15min trades use 100 bps.");
        console2.log("  - LIVE ROUTING (post-change):");
        console2.log("      EXTRA above 1% -> 100%% LAYER buy-and-burn");
        console2.log("                          (no artist/treasury share)");
        console2.log("      1% base        -> normal locker split");
        console2.log("                          (38% artist, 42% project burn,");
        console2.log("                           12% artcoins treasury,");
        console2.log("                           8% protocol-side burn)");
        _logCurrentState("INITIAL");

        // Phase 1: 24 trades bucketed into the 5 sniper-window tiers.
        console2.log("\n--- PHASE 1: sniper window (m0-15), small buys w/ stepped fee ---");
        _runPhase1WithAntiSniper();
        _logCurrentState("AFTER PHASE 1");
        _logSniperWindowCaptures();

        // Phases 2-4: post-window, no anti-sniper. Re-use baseline trades.
        console2.log("\n--- PHASE 2: post-window (m15-60), mixed flow @ 1% ---");
        _runPhase(_phase2Trades(), 2);
        _logCurrentState("AFTER PHASE 2");

        console2.log("\n--- PHASE 3: steady state (h1-6), rotation flow @ 1% ---");
        _runPhase(_phase3Trades(), 3);
        _logCurrentState("AFTER PHASE 3");

        console2.log("\n--- PHASE 4: consolidation (h6-24), balanced @ 1% ---");
        _runPhase(_phase4Trades(), 4);
        _logCurrentState("AFTER PHASE 4 (24h)");

        _logFinalReport_withAntiSniper();
    }

    function _runPhase1WithAntiSniper() internal {
        // Bucket the 24 phase-1 trades into the schedule:
        //   0-1m   (50%): trades 0-1     (2 trades)
        //   1-3m   (25%): trades 2-4     (3 trades)
        //   3-5m   (15%): trades 5-7     (3 trades)
        //   5-10m  (7%):  trades 8-14    (7 trades)
        //   10-15m (3%):  trades 15-23   (9 trades)
        int256[] memory trades = _phase1Trades();
        uint16[24] memory feeTiers = [
            uint16(5000),
            uint16(5000), // 50%
            uint16(2500),
            uint16(2500),
            uint16(2500), // 25%
            uint16(1500),
            uint16(1500),
            uint16(1500), // 15%
            uint16(700),
            uint16(700),
            uint16(700),
            uint16(700),
            uint16(700),
            uint16(700),
            uint16(700), // 7%
            uint16(300),
            uint16(300),
            uint16(300),
            uint16(300),
            uint16(300),
            uint16(300),
            uint16(300),
            uint16(300),
            uint16(300) // 3%
        ];
        for (uint256 i = 0; i < trades.length; i++) {
            int256 t = trades[i];
            require(t > 0, "phase 1 should be all buys");
            _doBuyAtFeeTier(uint256(t), feeTiers[i]);
        }
    }

    function _logSniperWindowCaptures() internal view {
        console2.log("\n  --- Per-cumulative-buy capture (sniper window) ---");
        if (_capturedSnap_05) {
            console2.log(
                string.concat(
                    "  After first 0.5 ETH cumulative buys: ", _u(captureCum_05 / 1e18), "M LAYER"
                )
            );
        }
        if (_capturedSnap_1) {
            console2.log(
                string.concat(
                    "  After first 1.0 ETH cumulative buys: ", _u(captureCum_1 / 1e18), "M LAYER"
                )
            );
        }
        if (_capturedSnap_2) {
            console2.log(
                string.concat(
                    "  After first 2.0 ETH cumulative buys: ", _u(captureCum_2 / 1e18), "M LAYER"
                )
            );
        }
        if (_capturedSnap_10) {
            console2.log(
                string.concat(
                    "  After first 10  ETH cumulative buys: ", _u(captureCum_10 / 1e18), "M LAYER"
                )
            );
        }
    }

    function _logFinalReport_withAntiSniper() internal view {
        console2.log("\n=========== FINAL REPORT (anti-sniper ON) ===========");
        console2.log(
            string.concat("Total ETH paid by buyers (gross):     ", _u(totalEthIn / 1e15), "mETH")
        );
        console2.log(
            string.concat("Total ETH received by sellers (net):  ", _u(totalEthOut / 1e15), "mETH")
        );
        uint256 grossVolEth = totalEthIn + totalEthOut;
        console2.log(
            string.concat("Gross volume:                         ", _u(grossVolEth / 1e15), "mETH")
        );
        console2.log(
            string.concat(
                "Net ETH inflow to LP:                 ", _diffMETH(totalEthIn, totalEthOut)
            )
        );
        console2.log(
            string.concat(
                "Net LAYER outflow:                    ", _diffM(totalLayerBought, totalLayerSold)
            )
        );

        // ─── New dual-path routing accounting ───────────────────────────
        // Fees collected:
        //   - Anti-sniper extra fees: routed 100% to BurnRouter (LAYER burn).
        //   - Normal 1% pool fees: split via locker
        //     (38% artist / 42% project burn / 12% artcoins treasury / 8%
        //     protocol burn).
        uint256 totalFees = totalAntiSniperFeeWei + totalNormalFeeWei;
        uint256 burnFromBase = totalNormalFeeWei * 50 / 100; // project-burn 42% + protocol-burn 8% = 50%
        uint256 artistFromBase = totalNormalFeeWei * 38 / 100;
        uint256 artcoinsTreasuryFromBase = totalNormalFeeWei * 12 / 100;
        uint256 burnTotal = burnFromBase + totalAntiSniperFeeWei; // base burn + 100% of extra

        console2.log("\nFee breakdown (NEW dual-path routing):");
        console2.log(
            string.concat(
                "  Anti-sniper extra fees (-> 100% burn): ",
                _u(totalAntiSniperFeeWei / 1e15),
                "mETH"
            )
        );
        console2.log(
            string.concat(
                "  Normal 1% pool fees (-> locker split): ", _u(totalNormalFeeWei / 1e15), "mETH"
            )
        );
        console2.log(
            string.concat("  Total fees collected:                  ", _u(totalFees / 1e15), "mETH")
        );
        console2.log(
            string.concat("    -> LAYER buy-and-burn (base+extra):  ", _u(burnTotal / 1e15), "mETH")
        );
        console2.log(
            string.concat(
                "    -> artist treasury (38% of base):    ", _u(artistFromBase / 1e15), "mETH"
            )
        );
        console2.log(
            string.concat(
                "    -> artcoins treasury (12% of base):  ",
                _u(artcoinsTreasuryFromBase / 1e15),
                "mETH"
            )
        );

        // Δ comparison to OLD routing where extra also flowed through the
        // normal split. Quantifies the improvement: the snipers' extra fee
        // is now entirely deflationary; treasuries no longer get a windfall
        // share of it.
        uint256 oldBurn = totalFees / 2; // would be 50% of all fees
        uint256 oldTreasury = totalFees - oldBurn; // 50% to artist + treasury
        uint256 burnDelta = burnTotal > oldBurn ? burnTotal - oldBurn : 0;
        uint256 treasuryDelta = oldTreasury > (artistFromBase + artcoinsTreasuryFromBase)
            ? oldTreasury - (artistFromBase + artcoinsTreasuryFromBase)
            : 0;
        console2.log(string.concat("  Delta vs OLD routing (extra-shared-50/50):"));
        console2.log(
            string.concat("    extra LAYER burned (vs OLD):       +", _u(burnDelta / 1e15), "mETH")
        );
        console2.log(
            string.concat(
                "    treasury reduction (vs OLD):       -", _u(treasuryDelta / 1e15), "mETH"
            )
        );

        (, int24 finalTk,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        int256 layerTick = _layerIsToken0 ? int256(finalTk) : -int256(finalTk);
        console2.log(
            string.concat("\nFinal FDV at $3500/ETH:               $", _u(_fdvUsd(layerTick)))
        );
    }

    /// @notice The volume sim itself. ~80 trades in 4 phases.
    function test_volume_realisticDay() public onlyFork {
        console2.log("");
        console2.log("=========== LAYER PRESET L VOLUME SIM ===========");
        console2.log("Pool: 1% static fee, no hook (LP-shape isolation)");
        console2.log("LP allocation:    639,800,000 LAYER");
        console2.log("Starting tick:    -190,400");
        _logCurrentState("INITIAL");

        // Phase 1: Sniper window. Many small buys, no sells. Simulates
        // FOMO + bot activity in the first 15 minutes.
        console2.log("\n--- PHASE 1: sniper window (m0-15), small buys ---");
        _runPhase(_phase1Trades(), 1);
        _logCurrentState("AFTER PHASE 1");

        // Phase 2: Post-window mixed flow. Some larger buys, first sells.
        console2.log("\n--- PHASE 2: post-window (m15-60), mixed flow ---");
        _runPhase(_phase2Trades(), 2);
        _logCurrentState("AFTER PHASE 2");

        // Phase 3: Steady state. Rotation: more sells, occasional whale buy.
        console2.log("\n--- PHASE 3: steady state (h1-6), rotation flow ---");
        _runPhase(_phase3Trades(), 3);
        _logCurrentState("AFTER PHASE 3");

        // Phase 4: Consolidation. Smaller, balanced trades.
        console2.log("\n--- PHASE 4: consolidation (h6-24), balanced ---");
        _runPhase(_phase4Trades(), 4);
        _logCurrentState("AFTER PHASE 4 (24h)");

        _logFinalReport();
    }

    /// @dev Trade encoding: positive int = ETH-in BUY of LAYER (in wei).
    ///                     negative int = LAYER-in SELL (in -wei).
    /// Sized for a launch that targets ~$1M-3M day-one volume @ ETH=$3500.

    function _phase1Trades() internal pure returns (int256[] memory t) {
        // ~24 small buys totalling ~10 ETH. Sniper era; many tiny FOMO buys.
        t = new int256[](24);
        // Tiny early bot probes
        t[0] = 0.05 ether;
        t[1] = 0.1 ether;
        t[2] = 0.2 ether;
        t[3] = 0.05 ether;
        t[4] = 0.5 ether;
        t[5] = 0.3 ether;
        t[6] = 0.15 ether;
        t[7] = 0.4 ether;
        t[8] = 1 ether;
        t[9] = 0.6 ether;
        t[10] = 0.25 ether;
        t[11] = 0.8 ether;
        t[12] = 0.35 ether;
        t[13] = 0.5 ether;
        t[14] = 1 ether;
        t[15] = 0.4 ether;
        t[16] = 0.7 ether;
        t[17] = 0.5 ether;
        t[18] = 0.3 ether;
        t[19] = 0.2 ether;
        t[20] = 0.6 ether;
        t[21] = 0.5 ether;
        t[22] = 0.4 ether;
        t[23] = 0.5 ether;
    }

    function _phase2Trades() internal pure returns (int256[] memory t) {
        // ~22 trades, ~30 ETH gross volume, mostly buys with first sells.
        t = new int256[](22);
        t[0] = 2 ether;
        t[1] = -50_000_000e18;
        t[2] = 3 ether;
        t[3] = 1.5 ether;
        t[4] = 2.5 ether;
        t[5] = -30_000_000e18;
        t[6] = 4 ether;
        t[7] = 1 ether;
        t[8] = 2 ether;
        t[9] = -40_000_000e18;
        t[10] = 3 ether;
        t[11] = 1.5 ether;
        t[12] = 2 ether;
        t[13] = -25_000_000e18;
        t[14] = 2 ether;
        t[15] = 1 ether;
        t[16] = 2 ether;
        t[17] = -20_000_000e18;
        t[18] = 1.5 ether;
        t[19] = 2 ether;
        t[20] = 1 ether;
        t[21] = 2.5 ether;
    }

    function _phase3Trades() internal pure returns (int256[] memory t) {
        // ~20 trades, larger sizes, more sells. Rotation phase.
        t = new int256[](20);
        t[0] = -60_000_000e18;
        t[1] = 5 ether;
        t[2] = -50_000_000e18;
        t[3] = 3 ether;
        t[4] = -40_000_000e18;
        t[5] = 2 ether;
        t[6] = -30_000_000e18;
        t[7] = 4 ether;
        t[8] = 10 ether;
        t[9] = -80_000_000e18;
        t[10] = -50_000_000e18;
        t[11] = 5 ether;
        t[12] = -40_000_000e18;
        t[13] = 3 ether;
        t[14] = -30_000_000e18;
        t[15] = 4 ether;
        t[16] = -50_000_000e18;
        t[17] = 2 ether;
        t[18] = -30_000_000e18;
        t[19] = 3 ether;
    }

    function _phase4Trades() internal pure returns (int256[] memory t) {
        // ~15 trades, balanced.
        t = new int256[](15);
        t[0] = 1 ether;
        t[1] = -15_000_000e18;
        t[2] = 2 ether;
        t[3] = -20_000_000e18;
        t[4] = 1.5 ether;
        t[5] = -10_000_000e18;
        t[6] = 1 ether;
        t[7] = -15_000_000e18;
        t[8] = 2 ether;
        t[9] = -20_000_000e18;
        t[10] = 1.5 ether;
        t[11] = -10_000_000e18;
        t[12] = 1 ether;
        t[13] = -15_000_000e18;
        t[14] = 2 ether;
    }

    function _runPhase(int256[] memory trades, uint256 phaseNum) internal {
        for (uint256 i = 0; i < trades.length; i++) {
            int256 t = trades[i];
            if (t > 0) {
                // BUY: t = ETH in
                _doBuy(uint256(t));
            } else if (t < 0) {
                // SELL: -t = LAYER in
                _doSell(uint256(-t));
            }
        }
        phaseNum; // silence unused
    }

    function _doBuy(uint256 ethIn) internal {
        _doBuyAtFeeTier(ethIn, 100); // 100 bps = 1%, the normal pool fee
    }

    /// @dev Buy at a given total fee tier (in bps of input). The pool itself
    ///      runs at a static 1% fee, so we model the schedule by reducing
    ///      the input passed to the swap by the EXTRA fee above 1% and
    ///      accounting for the diff externally as anti-sniper fee.
    ///
    ///      Trader "pays" ethIn. Of that:
    ///        - extraFeeWei = ethIn × (totalFeeBps - 100) / 10_000
    ///        - effectiveSwap = ethIn - extraFeeWei
    ///        - pool charges 1% of effectiveSwap as normal LP fee
    ///      Buyer LAYER reflects the curve walked by effectiveSwap.
    ///
    ///      Modeling drift: the pool's 1% is charged on top of the simulated
    ///      extra fee, so trader's effective cost is slightly above
    ///      totalFeeBps (e.g., 50.5% instead of 50% at the worst tier). For
    ///      telemetry purposes (recipient flows, FDV trajectories) this
    ///      drift is negligible.
    function _doBuyAtFeeTier(uint256 ethIn, uint16 totalFeeBps) internal {
        uint256 extraFeeWei = totalFeeBps > 100 ? ethIn * uint256(totalFeeBps - 100) / 10_000 : 0;
        uint256 effectiveSwap = ethIn - extraFeeWei;

        uint256 layerBefore = layer.balanceOf(address(this));
        bool zeroForOne = !_layerIsToken0;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(effectiveSwap),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap(
            poolKey,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            uint256 layerOut = layer.balanceOf(address(this)) - layerBefore;
            totalEthIn += ethIn; // trader paid the full amount
            totalLayerBought += layerOut;
            totalAntiSniperFeeWei += extraFeeWei;
            totalNormalFeeWei += effectiveSwap / 100; // 1% of effective input
            _captureSnaps(ethIn);
        } catch {
            // pool exhausted on this side
        }
    }

    /// @dev Capture per-cumulative-buy snapshots used to answer "how much
    ///      LAYER does the first 0.5/1/2/10 ETH of buys receive during the
    ///      sniper window?".
    function _captureSnaps(uint256) internal {
        if (!_capturedSnap_05 && totalEthIn >= 0.5 ether) {
            captureCum_05 = totalLayerBought;
            _capturedSnap_05 = true;
            captureTickAt_05 = uint256(int256(_currentLayerTick()));
        }
        if (!_capturedSnap_1 && totalEthIn >= 1 ether) {
            captureCum_1 = totalLayerBought;
            _capturedSnap_1 = true;
            captureTickAt_1 = uint256(int256(_currentLayerTick()));
        }
        if (!_capturedSnap_2 && totalEthIn >= 2 ether) {
            captureCum_2 = totalLayerBought;
            _capturedSnap_2 = true;
            captureTickAt_2 = uint256(int256(_currentLayerTick()));
        }
        if (!_capturedSnap_10 && totalEthIn >= 10 ether) {
            captureCum_10 = totalLayerBought;
            _capturedSnap_10 = true;
            captureTickAt_10 = uint256(int256(_currentLayerTick()));
        }
    }

    function _currentLayerTick() internal view returns (int256) {
        (, int24 tk,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        return _layerIsToken0 ? int256(tk) : -int256(tk);
    }

    function _doSell(uint256 layerIn) internal {
        uint256 myLayer = layer.balanceOf(address(this));
        if (myLayer < layerIn) layerIn = myLayer;
        if (layerIn == 0) return;

        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        bool zeroForOne = _layerIsToken0;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(layerIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap(
            poolKey,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            uint256 wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
            totalEthOut += wethOut;
            totalLayerSold += layerIn;
        } catch {
            // pool exhausted on the WETH side (would need WETH in pool to sell into)
        }
    }

    function _logCurrentState(string memory label) internal view {
        (, int24 tk,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        int256 layerTick = _layerIsToken0 ? int256(tk) : -int256(tk);
        uint256 layerPerEth = _layerPerEth(layerTick);
        uint256 fdvUsd = _fdvUsd(layerTick);

        console2.log(
            string.concat(
                "  ", label, "  pool tick=", _i(int256(tk)), "  LAYER tick=", _i(layerTick)
            )
        );
        console2.log(
            string.concat(
                "    LAYER/ETH (marginal): ",
                _u(layerPerEth / 1e18),
                "    FDV @ $3500/ETH: $",
                _u(fdvUsd)
            )
        );
        console2.log(
            string.concat(
                "    cumulative buys: ",
                _u(totalEthIn / 1e15),
                "mETH",
                "  / sells: ",
                _u(totalEthOut / 1e15),
                "mETH"
            )
        );
        console2.log(
            string.concat(
                "    LAYER bought: ",
                _u(totalLayerBought / 1e18),
                "M",
                "  /  sold: ",
                _u(totalLayerSold / 1e18),
                "M",
                "  /  net: ",
                _diffM(totalLayerBought, totalLayerSold)
            )
        );
        _logTierConsumption(layerTick);
    }

    function _logTierConsumption(int256 currentLayerTick) internal view {
        // For each tier, compute % of LAYER consumed based on current tick vs
        // the tier's [tickL, tickU). This is a single-sided LP so:
        //   tickL >= currentTick: untouched
        //   tickU <= currentTick: fully consumed
        //   else: partial; consumed fraction = (sqrt(tick) - sqrt(tickL))
        //                                     / (sqrt(tickU) - sqrt(tickL))
        for (uint256 i = 0; i < 12; i++) {
            uint256 pct;
            if (currentLayerTick <= int256(tierLowers[i])) {
                pct = 0;
            } else if (currentLayerTick >= int256(tierUppers[i])) {
                pct = 10_000;
            } else {
                uint160 sqrtL = TickMath.getSqrtPriceAtTick(tierLowers[i]);
                uint160 sqrtU = TickMath.getSqrtPriceAtTick(tierUppers[i]);
                uint160 sqrtC = TickMath.getSqrtPriceAtTick(int24(currentLayerTick));
                pct = uint256(uint160(sqrtC - sqrtL)) * 10_000 / uint256(uint160(sqrtU - sqrtL));
                // The relationship between tick and LAYER consumed is non-linear,
                // but sqrtPrice progression gives a reasonable approximation
                // for human-readable telemetry.
            }
            string memory bar = _bar(pct);
            console2.log(string.concat("    P", _u(i + 1), " ", bar, " ", _u(pct / 100), "."));
        }
    }

    function _logFinalReport() internal view {
        console2.log("\n=========== FINAL REPORT ===========");
        console2.log(string.concat("Total ETH in (buys):     ", _u(totalEthIn / 1e15), "mETH"));
        console2.log(string.concat("Total ETH out (sells):   ", _u(totalEthOut / 1e15), "mETH"));
        uint256 grossVolEth = totalEthIn + totalEthOut;
        console2.log(string.concat("Gross volume:            ", _u(grossVolEth / 1e15), "mETH"));
        console2.log(string.concat("Net ETH inflow to LP:    ", _diffMETH(totalEthIn, totalEthOut)));
        console2.log(
            string.concat("Net LAYER outflow:       ", _diffM(totalLayerBought, totalLayerSold))
        );

        // Modeled fee accounting at 1% pool fee (post-fix architecture):
        // Total LP fees = 1% of GROSS volume.
        // Of those: 50% goes to LAYER buy-and-burn, 50% to artist+treasury.
        // (This is the SPEC; under the patched hook this matches reality.)
        uint256 totalFeesEth = grossVolEth / 100; // 1% of gross
        uint256 burnEth = totalFeesEth / 2;
        uint256 treasuryEth = totalFeesEth - burnEth;
        console2.log(
            string.concat("Total fees collected (1% of gross): ", _u(totalFeesEth / 1e15), "mETH")
        );
        console2.log(
            string.concat("  -> LAYER buy-and-burn:            ", _u(burnEth / 1e15), "mETH")
        );
        console2.log(
            string.concat("  -> artist + treasury:             ", _u(treasuryEth / 1e15), "mETH")
        );

        // FDV at end
        (, int24 finalTk,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        int256 layerTick = _layerIsToken0 ? int256(finalTk) : -int256(finalTk);
        console2.log(string.concat("Final FDV at $3500/ETH:  $", _u(_fdvUsd(layerTick))));
    }

    // ─── math helpers ────────────────────────────────────────────────

    function _layerPerEth(int256 layerTick) internal pure returns (uint256) {
        if (layerTick < TickMath.MIN_TICK || layerTick > TickMath.MAX_TICK) return 0;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(int24(layerTick));
        uint256 q = uint256(sqrtP) >> 64;
        uint256 q2 = q * q;
        if (q2 == 0) return 0;
        // LAYER per 1 ETH (assume LAYER as token0 in the math):
        return (uint256(1e18) << 64) / q2;
    }

    /// @dev FDV USD at given LAYER tick, assuming ETH=$3500 and post-burn 739.8M supply.
    function _fdvUsd(int256 layerTick) internal pure returns (uint256) {
        if (layerTick == 0) return 0;
        if (layerTick < TickMath.MIN_TICK || layerTick > TickMath.MAX_TICK) return 0;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(int24(layerTick));
        uint256 q = uint256(sqrtP) >> 64;
        uint256 q2 = q * q;
        if (q2 == 0) return 0;
        // wpl_e18 = WETH per LAYER * 1e18 = q2 * 1e18 / 2^64
        uint256 wpl_e18 = (q2 * 1e18) >> 64;
        // FDV = supply * WPL * ETH_USD
        return (uint256(739_800_000) * wpl_e18 * 3500) / 1e18;
    }

    function _bar(uint256 pctBps) internal pure returns (string memory) {
        // pctBps is 0..10000. Render a 20-char bar.
        uint256 filled = pctBps * 20 / 10_000;
        bytes memory b = new bytes(20);
        for (uint256 i = 0; i < 20; i++) {
            b[i] = i < filled ? bytes1("#") : bytes1(".");
        }
        return string(b);
    }

    function _i(int256 x) internal pure returns (string memory) {
        if (x < 0) return string.concat("-", _u(uint256(-x)));
        return _u(uint256(x));
    }

    function _u(uint256 x) internal pure returns (string memory) {
        return vm.toString(x);
    }

    function _diffM(uint256 a, uint256 b) internal pure returns (string memory) {
        if (a >= b) return string.concat("+", _u((a - b) / 1e18), "M");
        return string.concat("-", _u((b - a) / 1e18), "M");
    }

    function _diffMETH(uint256 a, uint256 b) internal pure returns (string memory) {
        if (a >= b) return string.concat("+", _u((a - b) / 1e15), "mETH");
        return string.concat("-", _u((b - a) / 1e15), "mETH");
    }
}
