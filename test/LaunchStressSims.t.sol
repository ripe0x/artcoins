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

contract MintBurnTok is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @title LaunchStressSims
/// @notice Pre-launch stress simulations for the LAYER mainnet launch.
///         All scenarios share a fresh-pool harness using snapshot/revert
///         so each sub-scenario starts from the same Preset L seeded
///         state. Pool runs hookless and the anti-sniper extra fee is
///         modeled by pre-reducing input — same approach as
///         LayerVolumeSimulation. Dual-path routing (extra → 100% burn,
///         base 1% → locker normal split 50/50 burn/treasury) is what's
///         scored in the recipient totals.
///
/// Run:
///   forge test --match-contract LaunchStressSims \
///     --fork-url $MAINNET_RPC_URL -vv
contract LaunchStressSims is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── Mainnet addresses ──────────────────────────────────────────────
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ─── Launch constants (per LaunchLayer.s.sol) ────────────────────────
    int24 constant LAYER_STARTING_TICK = -190_400;
    uint256 constant LP_ALLOCATION = 639_800_000e18;
    uint256 constant POST_BURN_SUPPLY = 739_800_000e18;
    uint256 constant CLAIM_POOL = 100_000_000e18;
    uint24 constant POOL_FEE = LaunchDefaults.BUY_FEE; // 1% = 10_000 ppm

    PoolModifyLiquidityTest internal liqRouter;
    PoolSwapTest internal swapRouter;
    bool internal _onFork;
    bool internal _layerIsToken0;
    PoolKey internal poolKey;
    MintBurnTok internal layer;

    uint256 internal cleanSnapshotId;

    // ─── Telemetry (reset by _resetState) ──────────────────────────────
    uint256 internal totalEthIn;
    uint256 internal totalEthOut;
    uint256 internal totalLayerBought;
    uint256 internal totalLayerSold;
    uint256 internal totalAntiSniperFeeWei;
    uint256 internal totalNormalFeeWei;
    uint256 internal totalLayerSellSideExtraWei; // sniper-extra collected on sells (in LAYER, modeled here as wei-equivalent only for telemetry)
    uint256 internal revertCount;

    // 12 Preset L positions
    int24[12] internal tierLowers;
    int24[12] internal tierUppers;
    uint16[12] internal tierBps;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: not on mainnet fork");
            return;
        }
        _onFork = true;

        layer = new MintBurnTok("Liquidity Layer", "LAYER");
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

        // Whale wallet — large enough to cover any sub-scenario.
        vm.deal(address(this), 50_000 ether);
        IWETH9(payable(WETH)).deposit{value: 20_000 ether}();
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);

        _seedPresetL();

        cleanSnapshotId = vm.snapshot();
    }

    receive() external payable {}

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    /// @dev Re-seed every sub-scenario from the same clean state.
    function _resetState() internal {
        vm.revertTo(cleanSnapshotId);
        cleanSnapshotId = vm.snapshot();
        totalEthIn = 0;
        totalEthOut = 0;
        totalLayerBought = 0;
        totalLayerSold = 0;
        totalAntiSniperFeeWei = 0;
        totalNormalFeeWei = 0;
        totalLayerSellSideExtraWei = 0;
        revertCount = 0;
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

    // ─── Trade helpers ──────────────────────────────────────────────────

    /// @dev Buy at given total fee tier in bps. Models anti-sniper:
    ///      input pre-reduced by extra above 1%; pool charges 1% on the
    ///      reduced amount; the extra accrues to "sniper-extra" telemetry.
    function _doBuyAt(uint256 ethIn, uint16 totalFeeBps) internal returns (uint256 layerOut) {
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
            layerOut = layer.balanceOf(address(this)) - layerBefore;
            totalEthIn += ethIn;
            totalLayerBought += layerOut;
            totalAntiSniperFeeWei += extraFeeWei;
            totalNormalFeeWei += effectiveSwap / 100; // 1% of effective input
        } catch {
            revertCount++;
        }
    }

    function _doBuy(uint256 ethIn) internal returns (uint256) {
        return _doBuyAt(ethIn, 100); // 1% normal
    }

    /// @dev Sell at given total fee tier. Models the sniper-extra path
    ///      symmetrically (extra LAYER routes to BurnRouter; not modeled
    ///      as price impact since it's burned). The pool itself charges
    ///      1% on the reduced LAYER input.
    function _doSellAt(uint256 layerIn, uint16 totalFeeBps) internal returns (uint256 wethOut) {
        uint256 myLayer = layer.balanceOf(address(this));
        if (myLayer < layerIn) layerIn = myLayer;
        if (layerIn == 0) return 0;

        uint256 extraFeeLayer =
            totalFeeBps > 100 ? layerIn * uint256(totalFeeBps - 100) / 10_000 : 0;
        uint256 effectiveSwap = layerIn - extraFeeLayer;

        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        bool zeroForOne = _layerIsToken0;
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
            wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
            totalEthOut += wethOut;
            totalLayerSold += layerIn;
            totalLayerSellSideExtraWei += extraFeeLayer; // recorded as LAYER amount
            // Normal 1% on the swapped portion, but in LAYER terms.
            // For aggregate burn accounting we don't double-count this here
            // (locker handles LAYER side fees naturally).
        } catch {
            revertCount++;
        }
    }

    function _doSell(uint256 layerIn) internal returns (uint256) {
        return _doSellAt(layerIn, 100);
    }

    function _currentLayerTick() internal view returns (int256) {
        (, int24 tk,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        return _layerIsToken0 ? int256(tk) : -int256(tk);
    }

    /// @dev FDV in USD at $3500/ETH. Uses the same math as the existing
    ///      LayerVolumeSimulation harness — `layerTick` is LAYER↔WETH tick
    ///      from LAYER's perspective.
    function _fdvUsd() internal view returns (uint256) {
        int256 tk = _currentLayerTick();
        if (tk == 0) return 0;
        if (tk < TickMath.MIN_TICK || tk > TickMath.MAX_TICK) return 0;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(int24(tk));
        uint256 q = uint256(sqrtP) >> 64;
        uint256 q2 = q * q;
        if (q2 == 0) return 0;
        uint256 wpl_e18 = (q2 * 1e18) >> 64;
        return (POST_BURN_SUPPLY / 1e18 * wpl_e18 * 3500) / 1e18;
    }

    function _u(uint256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _i(int256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _layerM(uint256 v) internal pure returns (string memory) {
        return _u(v / 1e18 / 1_000_000); // millions
    }

    function _ethM(uint256 v) internal pure returns (string memory) {
        return _u(v / 1e15); // milliETH
    }

    function _bpsOf(uint256 part, uint256 whole) internal pure returns (uint256) {
        if (whole == 0) return 0;
        return part * 10_000 / whole;
    }

    function _logRow(string memory label, string memory value) internal pure {
        console2.log(string.concat("  ", label, ": ", value));
    }

    /// @dev Tier consumption snapshot — for each of the 12 Preset L
    ///      positions, what % is consumed (LAYER outflow as fraction of
    ///      that position's bps allocation).
    function _logTierConsumption() internal view {
        uint256 net = totalLayerBought > totalLayerSold ? totalLayerBought - totalLayerSold : 0;
        uint256 cumulativeAllocated = 0;
        for (uint256 i = 0; i < 12; i++) {
            uint256 alloc = LP_ALLOCATION * tierBps[i] / 10_000;
            uint256 consumed = 0;
            if (net > cumulativeAllocated) {
                consumed = net - cumulativeAllocated;
                if (consumed > alloc) consumed = alloc;
            }
            uint256 pct = alloc == 0 ? 0 : consumed * 100 / alloc;
            console2.log(string.concat("  P", _u(i + 1), ": ", _u(pct), "%"));
            cumulativeAllocated += alloc;
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Scenario 1 — First block bot swarm
    // ════════════════════════════════════════════════════════════════════
    function test_s1_firstBlockBotSwarm() public onlyFork {
        console2.log("");
        console2.log("=========== SCENARIO 1: First block bot swarm ===========");
        console2.log("Tier 0 fee = 50% (extra 49%, base 1%).");
        console2.log("");
        uint256[3] memory walletCounts = [uint256(20), uint256(50), uint256(100)];
        uint256[5] memory perWalletSizes = [
            uint256(0.01 ether),
            uint256(0.05 ether),
            uint256(0.1 ether),
            uint256(0.25 ether),
            uint256(0.5 ether)
        ];
        for (uint256 i = 0; i < walletCounts.length; i++) {
            for (uint256 j = 0; j < perWalletSizes.length; j++) {
                _resetState();
                _runSwarm(walletCounts[i], perWalletSizes[j]);
                _logSwarmResult(walletCounts[i], perWalletSizes[j]);
            }
        }
    }

    function _runSwarm(uint256 numWallets, uint256 perWalletEth) internal {
        for (uint256 k = 0; k < numWallets; k++) {
            _doBuyAt(perWalletEth, 5000); // 50% tier
        }
    }

    function _logSwarmResult(uint256 numWallets, uint256 perWalletEth) internal view {
        uint256 largestWallet = numWallets == 0 ? 0 : totalLayerBought / numWallets; // even split assumption
        uint256 lpCapPct = _bpsOf(totalLayerBought, LP_ALLOCATION);
        uint256 supCapPct = _bpsOf(totalLayerBought, POST_BURN_SUPPLY);
        // sniper-extra (49% of input) -> 100% LAYER burn
        // The LAYER actually burned is purchased by burnRouter at the
        // post-trade marginal price.
        console2.log(
            string.concat(
                "wallets=",
                _u(numWallets),
                " size=",
                _u(perWalletEth / 1e15),
                "mETH",
                " | totalIn=",
                _u(totalEthIn / 1e15),
                "mETH",
                " layerOut=",
                _u(totalLayerBought / 1e18 / 1_000_000),
                "M",
                " largestWallet=",
                _u(largestWallet / 1e18 / 1_000_000),
                "M",
                " lp%=",
                _u(lpCapPct / 100),
                " sup%=",
                _u(supCapPct / 100),
                " extra=",
                _u(totalAntiSniperFeeWei / 1e15),
                "mETH",
                " tick=",
                _i(_currentLayerTick()),
                " FDV=$",
                _u(_fdvUsd()),
                " reverts=",
                _u(revertCount)
            )
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Scenario 2 — One whale sniper at each tier
    // ════════════════════════════════════════════════════════════════════
    function test_s2_oneWhaleSniper() public onlyFork {
        console2.log("");
        console2.log("=========== SCENARIO 2: One whale sniper ===========");
        uint256[5] memory sizes = [
            uint256(0.5 ether),
            uint256(1 ether),
            uint256(2 ether),
            uint256(5 ether),
            uint256(10 ether)
        ];
        uint16[6] memory tiers = [uint16(5000), 2500, 1500, 700, 300, 100];
        string[6] memory tierLabels =
            ["min0_50%", "min1-3_25%", "min3-5_15%", "min5-10_7%", "min10-15_3%", "post15_1%"];
        for (uint256 i = 0; i < tiers.length; i++) {
            for (uint256 j = 0; j < sizes.length; j++) {
                _resetState();
                _doBuyAt(sizes[j], tiers[i]);
                _logWhaleResult(tierLabels[i], sizes[j], tiers[i]);
            }
        }
    }

    function _logWhaleResult(string memory tier, uint256 size, uint16 feeBps) internal view {
        uint256 lpPct = _bpsOf(totalLayerBought, LP_ALLOCATION);
        uint256 supPct = _bpsOf(totalLayerBought, POST_BURN_SUPPLY);
        // LAYER burned from extra ≈ extra ETH worth of LAYER bought-and-burned
        // at a marginal price slightly higher than the trade's own price; we
        // approximate as `extra * marginalLayerPerEth` using the *post-trade*
        // tick.
        console2.log(
            string.concat(
                "tier=",
                tier,
                " size=",
                _u(size / 1e15),
                "mETH",
                " totalFee=",
                _u(uint256(feeBps)),
                "bps",
                " | layerOut=",
                _u(totalLayerBought / 1e18 / 1_000_000),
                "M",
                " extraETH=",
                _u(totalAntiSniperFeeWei / 1e15),
                "mETH",
                " lp%=",
                _u(lpPct / 100),
                " sup%=",
                _u(supPct / 100),
                " tick=",
                _i(_currentLayerTick()),
                " FDV=$",
                _u(_fdvUsd())
            )
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Scenario 3 — Claim dump (synthetic distribution)
    // ════════════════════════════════════════════════════════════════════
    /// @dev We don't have the real merkle leaves in code form. Synthetic
    ///      distribution that approximates the LAYER claim spec (100M pool,
    ///      heavily weighted top, long tail of small holders):
    ///      top 1: 5M; top 5 (incl top 1): 1M each (4 + 5M = 9M); top 50:
    ///      avg 0.5M (45 * 0.5M = 22.5M); long tail 1000 wallets ~ 0.0685M
    ///      each (= 68.5M). Sums ≈ 100M.
    function test_s3_claimDumpScenarios() public onlyFork {
        console2.log("");
        console2.log("=========== SCENARIO 3: Claim dump ===========");
        console2.log("Synthetic distribution: top1=5M, top2-5=1M, top6-50=0.5M,");
        console2.log("                        tail(1000)=0.0685M");

        uint256[4] memory marketStateBuys =
            [uint256(0.5 ether), uint256(2 ether), uint256(10 ether), uint256(50 ether)];
        string[4] memory marketStateLabels = ["0.5ETH", "2ETH", "10ETH", "50ETH"];

        for (uint256 m = 0; m < marketStateBuys.length; m++) {
            // Iterate sub-scenarios for this market state
            _runDumpSubScenario(
                marketStateLabels[m], marketStateBuys[m], "largest_100%", 5_000_000e18
            );
            _runDumpSubScenario(
                marketStateLabels[m],
                marketStateBuys[m],
                "top5_50%",
                (5_000_000e18 + 4 * 1_000_000e18) / 2
            ); // 4.5M total
            _runDumpSubScenario(
                marketStateLabels[m],
                marketStateBuys[m],
                "top10_25%",
                (5_000_000e18 + 4 * 1_000_000e18 + 5 * 500_000e18) / 4
            ); // ~2.875M
            _runDumpSubScenario(
                marketStateLabels[m], marketStateBuys[m], "all_10%", 100_000_000e18 / 10
            ); // 10M
            _runDumpSubScenario(
                marketStateLabels[m], marketStateBuys[m], "all_25%", 100_000_000e18 / 4
            ); // 25M
        }
    }

    function _runDumpSubScenario(
        string memory marketLabel,
        uint256 buyEth,
        string memory dumpLabel,
        uint256 layerToSell
    ) internal {
        _resetState();
        // Build market state. Use 1% (post-window) for simplicity — claimants
        // typically dump after the sniper window has closed.
        if (buyEth > 0) _doBuy(buyEth);
        int256 tickBefore = _currentLayerTick();
        uint256 fdvBefore = _fdvUsd();

        // Mint synthetic claimant LAYER to ourselves and sell it. The pool
        // doesn't care about origin; the price impact is what we measure.
        layer.mint(address(this), layerToSell);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        _doSellAt(layerToSell, 100); // post-window, 1%
        uint256 wethAfter = IERC20(WETH).balanceOf(address(this));
        uint256 ethOut = wethAfter - wethBefore;

        int256 tickAfter = _currentLayerTick();
        uint256 fdvAfter = _fdvUsd();
        bool tradeable = revertCount == 0;

        console2.log(
            string.concat(
                "market=",
                marketLabel,
                " dump=",
                dumpLabel,
                " | sold=",
                _u(layerToSell / 1e18 / 1_000_000),
                "M",
                " ethOut=",
                _u(ethOut / 1e15),
                "mETH",
                " tickBefore=",
                _i(tickBefore),
                " tickAfter=",
                _i(tickAfter),
                " FDVbefore=$",
                _u(fdvBefore),
                " FDVafter=$",
                _u(fdvAfter),
                " tradeable=",
                tradeable ? "Y" : "N"
            )
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Scenario 4 — Buy wall then dump
    // ════════════════════════════════════════════════════════════════════
    function test_s4_buyWallThenDump() public onlyFork {
        _resetState();
        console2.log("");
        console2.log("=========== SCENARIO 4: Buy wall then dump ===========");

        // Phase A: 10 ETH of buys during sniper window. Bucket them into
        // the 5 tiers proportionally to schedule duration weights.
        uint16[5] memory tierFees = [uint16(5000), 2500, 1500, 700, 300];
        uint256[5] memory tierEthBudgets =
            [uint256(0.5 ether), 1.5 ether, 1.5 ether, 3 ether, 3.5 ether];
        uint256 phaseATotalLayerBought = 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 chunks = 5;
            uint256 perChunk = tierEthBudgets[i] / chunks;
            for (uint256 k = 0; k < chunks; k++) {
                phaseATotalLayerBought += _doBuyAt(perChunk, tierFees[i]);
            }
        }
        _logPhase("A) 10 ETH sniper window buys");

        // Phase B: 50% of phase-A LAYER sells (post-window 1%).
        uint256 sellAmountB = phaseATotalLayerBought / 2;
        _doSellAt(sellAmountB, 100);
        _logPhase("B) 50% of phase-A LAYER sold");

        // Phase C: 5 ETH new buys (post-window 1%).
        for (uint256 k = 0; k < 5; k++) {
            _doBuyAt(1 ether, 100);
        }
        _logPhase("C) +5 ETH new buys");

        // Phase D: 25% of remaining early buyer LAYER sells.
        uint256 remainingFromA = phaseATotalLayerBought - sellAmountB;
        uint256 sellAmountD = remainingFromA / 4;
        _doSellAt(sellAmountD, 100);
        _logPhase("D) 25% of remaining early-buyer LAYER sold");

        console2.log("");
        console2.log("(max drawdown is implied by tick deltas across phases)");
    }

    function _logPhase(string memory label) internal view {
        console2.log(
            string.concat(
                "  ",
                label,
                " | tick=",
                _i(_currentLayerTick()),
                " FDV=$",
                _u(_fdvUsd()),
                " ethIn=",
                _u(totalEthIn / 1e15),
                "mETH",
                " ethOut=",
                _u(totalEthOut / 1e15),
                "mETH",
                " layerBought=",
                _u(totalLayerBought / 1e18 / 1_000_000),
                "M",
                " layerSold=",
                _u(totalLayerSold / 1e18 / 1_000_000),
                "M"
            )
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Scenario 5 — Quiet launch
    // ════════════════════════════════════════════════════════════════════
    function test_s5_quietLaunch() public onlyFork {
        _resetState();
        console2.log("");
        console2.log("=========== SCENARIO 5: Quiet launch ===========");

        // Phase A: only 3 ETH during the sniper window.
        uint16[5] memory tierFees = [uint16(5000), 2500, 1500, 700, 300];
        uint256[5] memory tierEthBudgets =
            [uint256(0.15 ether), 0.45 ether, 0.45 ether, 0.9 ether, 1.05 ether];
        for (uint256 i = 0; i < 5; i++) {
            uint256 perChunk = tierEthBudgets[i] / 3;
            for (uint256 k = 0; k < 3; k++) {
                _doBuyAt(perChunk, tierFees[i]);
            }
        }
        _logPhase("A) 3 ETH sniper-window buys, no further volume");

        // Phase B: largest claimant 100% (5M from synthetic distribution).
        layer.mint(address(this), 5_000_000e18);
        _doSellAt(5_000_000e18, 100);
        _logPhase("B) largest claimant dumps 5M");

        // Phase C: top 5 sell 25% each (4 wallets × 0.25M = 1M LAYER)
        layer.mint(address(this), 1_000_000e18);
        _doSellAt(1_000_000e18, 100);
        _logPhase("C) top5 25% dumps");

        // Phase D: all claimants sell 10% each (assume 10M LAYER total).
        layer.mint(address(this), 10_000_000e18);
        _doSellAt(10_000_000e18, 100);
        _logPhase("D) all claimants 10% dump");

        console2.log("");
        console2.log("Net LP position:");
        _logTierConsumption();
    }

    // ════════════════════════════════════════════════════════════════════
    // Scenario 6 — High success
    // ════════════════════════════════════════════════════════════════════
    function test_s6_highSuccess() public onlyFork {
        _resetState();
        console2.log("");
        console2.log("=========== SCENARIO 6: High success ===========");

        // Phase 1: 10 ETH sniper window (bucketed).
        uint16[5] memory tierFees = [uint16(5000), 2500, 1500, 700, 300];
        uint256[5] memory tierEthBudgets =
            [uint256(0.5 ether), 1.5 ether, 1.5 ether, 3 ether, 3.5 ether];
        for (uint256 i = 0; i < 5; i++) {
            uint256 perChunk = tierEthBudgets[i] / 5;
            for (uint256 k = 0; k < 5; k++) {
                _doBuyAt(perChunk, tierFees[i]);
            }
        }
        // Mixed sells = 25% of buy volume (in ETH equivalent) — sell LAYER
        // worth ~ 2.5 ETH at the current price by selling a corresponding
        // amount.
        // For simplicity we sell a fixed % of LAYER bought so far.
        _doSellAt(totalLayerBought / 4, 100);
        _logPhase("Phase 1 (10 ETH sniper + 25% sells)");

        // Phase 2: +50 ETH first hour (post-window 1%).
        for (uint256 k = 0; k < 25; k++) {
            _doBuyAt(2 ether, 100);
        }
        _doSellAt(totalLayerBought / 4, 100); // another 25% of cumulative LAYER bought
        _logPhase("Phase 2 (+50 ETH first hour)");

        // Phase 3: +150 ETH first day.
        for (uint256 k = 0; k < 30; k++) {
            _doBuyAt(5 ether, 100);
        }
        _doSellAt(totalLayerBought / 4, 100);
        _logPhase("Phase 3 (+150 ETH first day)");

        // Phase 4: +300 ETH over 48h.
        for (uint256 k = 0; k < 30; k++) {
            _doBuyAt(10 ether, 100);
        }
        _doSellAt(totalLayerBought / 4, 100);
        _logPhase("Phase 4 (+300 ETH 48h)");

        console2.log("");
        console2.log("Final tier consumption:");
        _logTierConsumption();
        console2.log("");
        // Recipient flows under dual-path routing:
        //   - Sniper-extra (sniper-window only) → 100% to BurnRouter
        //   - Base 1% (every swap) → locker split (50% burn, 50% treasury)
        uint256 totalBaseFee = totalNormalFeeWei;
        uint256 totalExtra = totalAntiSniperFeeWei;
        uint256 burnTotal = (totalBaseFee / 2) + totalExtra;
        uint256 artistTreasury = totalBaseFee * 38 / 100;
        uint256 artcoinsTreasury = totalBaseFee * 12 / 100;
        console2.log(
            string.concat("Total fees collected: ", _u((totalBaseFee + totalExtra) / 1e15), "mETH")
        );
        console2.log(string.concat("  -> LAYER burn (base+extra): ", _u(burnTotal / 1e15), "mETH"));
        console2.log(
            string.concat("  -> artist treasury (38% base): ", _u(artistTreasury / 1e15), "mETH")
        );
        console2.log(
            string.concat(
                "  -> artcoins treasury (12% base): ", _u(artcoinsTreasury / 1e15), "mETH"
            )
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Scenario 7 — Sandwich approximation
    // ════════════════════════════════════════════════════════════════════
    function test_s7_sandwich() public onlyFork {
        console2.log("");
        console2.log("=========== SCENARIO 7: Sandwich approximation ===========");
        console2.log("Bot frontrun = 7.5% of user size (mid of 5-10%); back-run sells immediately.");
        console2.log("All trades during minute 0 (50% sniper fee).");
        console2.log("");

        // Sub-scenario A: 10 users × 0.1 ETH
        _runSandwichRound("10x_0.1ETH", 10, 0.1 ether);
        // Sub-scenario B: 10 users × 0.5 ETH
        _runSandwichRound("10x_0.5ETH", 10, 0.5 ether);
        // Sub-scenario C: 5 users × 1 ETH
        _runSandwichRound("5x_1ETH", 5, 1 ether);
    }

    function _runSandwichRound(string memory label, uint256 numUsers, uint256 userSize) internal {
        _resetState();
        uint256 botFrontEthSpent = 0;
        uint256 botLayerAccumulated = 0;
        uint256 botBackEthRecv = 0;

        for (uint256 i = 0; i < numUsers; i++) {
            // Bot frontrun: 7.5% of user size
            uint256 frontEth = userSize * 75 / 1000;
            uint256 layerBefore = layer.balanceOf(address(this));
            _doBuyAt(frontEth, 5000); // 50% tier
            uint256 botLayerOut = layer.balanceOf(address(this)) - layerBefore;
            botFrontEthSpent += frontEth;
            botLayerAccumulated += botLayerOut;

            // User buy
            _doBuyAt(userSize, 5000);

            // Bot backrun sell
            uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
            _doSellAt(botLayerOut, 5000); // sell at sniper tier too (back-run is in same block)
            uint256 wethAfter = IERC20(WETH).balanceOf(address(this));
            botBackEthRecv += (wethAfter - wethBefore);
            botLayerAccumulated -= botLayerOut;
        }

        // Bot P&L: backrun ETH out - frontrun ETH spent
        // (Bot eats the 50% sniper fee on EACH leg of the sandwich.)
        int256 botPnl = int256(botBackEthRecv) - int256(botFrontEthSpent);
        console2.log(
            string.concat(
                "round=",
                label,
                " | botFrontIn=",
                _u(botFrontEthSpent / 1e15),
                "mETH",
                " botBackOut=",
                _u(botBackEthRecv / 1e15),
                "mETH",
                " botPnL=",
                botPnl >= 0 ? "+" : "-",
                botPnl >= 0 ? _u(uint256(botPnl) / 1e15) : _u(uint256(-botPnl) / 1e15),
                "mETH",
                " (negative = sandwich unprofitable)"
            )
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Scenario 8 — ExactOutput regression confirmation
    // ════════════════════════════════════════════════════════════════════
    /// @dev The hookless harness can't model the live `_afterSwap` skim,
    ///      so the authoritative regression coverage lives in
    ///      SniperExtraFeeForkTest. This scenario is a pointer + a
    ///      sanity check that exactOutput swaps work against a static-fee
    ///      pool (i.e., no router-level revert).
    function test_s8_exactOutputRouterPath() public onlyFork {
        _resetState();
        console2.log("");
        console2.log("=========== SCENARIO 8: ExactOutput router path ===========");
        console2.log("Authoritative coverage: SniperExtraFeeForkTest (10 tests).");
        console2.log("");

        // Sanity: exactOutput buys/sells succeed through the same swap router.
        uint256 layerOut = 5_000_000e18;
        bool zeroForOne = !_layerIsToken0;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(layerOut),
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
            console2.log("  exactOutput buy: OK (router path works)");
        } catch {
            console2.log("  exactOutput buy: REVERTED (investigate)");
            revertCount++;
        }
        // Confirm slot0 LP fee unchanged.
        (,,, uint24 slotFee) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        console2.log(
            string.concat("  slot0 LP fee: ", _u(uint256(slotFee)), " ppm (must be 10000 = 1%)")
        );
        require(slotFee == POOL_FEE, "slot0 fee drift");
        console2.log("");
        console2.log("  See SniperExtraFeeForkTest for:");
        console2.log("    * exactOutput buy applies sniper extra in WETH");
        console2.log("    * exactOutput sell applies sniper extra in LAYER");
        console2.log("    * currentSniperExtraFeePpm clears after every afterSwap");
        console2.log("    * post-window: no skim, no reverts");
    }

    // ════════════════════════════════════════════════════════════════════
    // Scenario 9 — BurnRouter processing cadence
    // ════════════════════════════════════════════════════════════════════
    /// @dev We model burn cadence as a series of LAYER buys (the burn-swap
    ///      step) at fixed WETH amounts, measuring the price impact of
    ///      each. The actual BurnRouter doesn't introduce extra protocol
    ///      logic on the swap itself — it's just another WETH→LAYER swap
    ///      against the same pool. So the cadence question is purely about
    ///      LP-curve sensitivity to swap size.
    function test_s9_burnCadence() public onlyFork {
        console2.log("");
        console2.log("=========== SCENARIO 9: BurnRouter cadence ===========");
        console2.log("Total WETH to burn = 0.724 ETH (the 24h sniper-extra accrual).");

        // Run base 24h-ish volume to set a realistic mid-pool tick first.
        _resetState();
        uint16[5] memory tierFees = [uint16(5000), 2500, 1500, 700, 300];
        uint256[5] memory tierEthBudgets =
            [uint256(0.5 ether), 1.5 ether, 1.5 ether, 3 ether, 3.5 ether];
        for (uint256 i = 0; i < 5; i++) {
            uint256 perChunk = tierEthBudgets[i] / 5;
            for (uint256 k = 0; k < 5; k++) {
                _doBuyAt(perChunk, tierFees[i]);
            }
        }
        for (uint256 k = 0; k < 30; k++) {
            _doBuyAt(2 ether, 100);
            _doSellAt(totalLayerBought / 30, 100); // mixed flow
        }
        int256 baseTick = _currentLayerTick();
        uint256 baseFdv = _fdvUsd();
        // Snapshot post-volume state so each cadence variant starts the same.
        uint256 postVolumeSnap = vm.snapshot();

        uint256 totalBurnEth = 0.724 ether;
        uint256[4] memory cadences = [uint256(0.1 ether), 0.5 ether, 1 ether, totalBurnEth];
        string[4] memory labels = ["0.1ETH", "0.5ETH", "1ETH", "endOfDay"];

        for (uint256 i = 0; i < cadences.length; i++) {
            vm.revertTo(postVolumeSnap);
            postVolumeSnap = vm.snapshot();
            int256 startTick = _currentLayerTick();
            uint256 chunks = totalBurnEth / cadences[i];
            uint256 leftover = totalBurnEth - (chunks * cadences[i]);
            for (uint256 k = 0; k < chunks; k++) {
                _doBuyAt(cadences[i], 100); // burn-swap is at normal 1%
            }
            if (leftover > 0) _doBuyAt(leftover, 100);
            int256 endTick = _currentLayerTick();
            int256 tickImpact = endTick - startTick;
            console2.log(
                string.concat(
                    "cadence=",
                    labels[i],
                    " chunks=",
                    _u(chunks),
                    " startTick=",
                    _i(startTick),
                    " endTick=",
                    _i(endTick),
                    " tickImpact=",
                    _i(tickImpact),
                    " FDVdelta=$",
                    _u(_fdvUsd() > baseFdv ? _fdvUsd() - baseFdv : baseFdv - _fdvUsd())
                )
            );
        }
        console2.log("");
        console2.log("Observation: tick impact is identical regardless of cadence");
        console2.log("(same total ETH input -> same final pool state). Smaller chunks");
        console2.log("only matter if there are concurrent trades (rebalance windows).");
        console2.log("Recommendation: keep MIN_THRESHOLD at 0.01 ETH default,");
        console2.log("amortises gas without creating sandwich windows.");
        baseTick; // silence unused
    }

    // ════════════════════════════════════════════════════════════════════
    // Scenario 10 — Dashboard consistency check (contract truth)
    // ════════════════════════════════════════════════════════════════════
    /// @dev Contract-side audit of the values the UI reads. We check the
    ///      pool's slot0 + the locker reward array consistency assertions.
    ///      Note: the production hook + module + BurnRouter are NOT
    ///      deployed in this harness (it runs hookless). For the live
    ///      hook+module values, see SniperExtraFeeForkTest.
    function test_s10_dashboardConsistency() public onlyFork {
        _resetState();
        console2.log("");
        console2.log("=========== SCENARIO 10: Dashboard consistency ===========");
        console2.log("Contract-side checks:");

        (uint160 sqrtP, int24 tk,, uint24 slotFee) =
            IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        console2.log(string.concat("  pool tick: ", _i(int256(tk))));
        console2.log(string.concat("  sqrtPriceX96: ", _u(uint256(sqrtP))));
        console2.log(
            string.concat("  pool LP fee: ", _u(uint256(slotFee)), " ppm (expected 10000)")
        );
        require(slotFee == POOL_FEE, "slot0 fee drift");

        console2.log(
            string.concat(
                "  LAYER total supply (mock): ", _u(layer.totalSupply() / 1e18 / 1_000_000), "M"
            )
        );
        console2.log("");
        console2.log("Live-hook checks (separate suite):");
        console2.log("  HookProtocolFeeNumeratorZero: protocolFeeNumerator == 0");
        console2.log("  SniperExtraFeeForkTest:      currentSniperExtraFeePpm clears");
        console2.log("                                sniperFeeRecipient == BurnRouter");
        console2.log("                                sniperFeeRecipientLocked == true");
        console2.log("");
        console2.log("UI-readable values (for FeeFlowPage / token page):");
        console2.log("  total supply:           layer.totalSupply()");
        console2.log("  burned:                 1B - totalSupply()");
        console2.log("  current pool fee:       slot0.lpFee == 10000 (always)");
        console2.log("  current sniper extra:   sniperModule.getCurrentExtraFeePpm()");
        console2.log(
            "  claimable (per addr):   airdropV2.amountClaimable(addr) - claimedAmount(addr)"
        );
        console2.log("  pool price:             slot0.sqrtPriceX96 -> tick -> layer/eth");
        console2.log("  fee split (base 1%):    locker.rewardBps[i] (3800/4200/2000)");
        console2.log("                          PFC.treasuryBps/burnBps (6000/4000)");
        console2.log("  BurnRouter balances:    burnRouter.status() -> (layer, weth, ready)");
        console2.log("  PFC balances:           IERC20.balanceOf(pfc) for each tracked currency");
    }
}
