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

contract MintToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title LpPresetCompareTest
/// @notice Runs the same buy ladder against multiple LP-shape presets and
///         reports a comparison so we can pick a saner launch curve.
///
///         Compares:
///           [Baseline]  current LaunchDefaults shape (4 positions, start -230400)
///           [Preset A]  same shape, start +20000 ticks higher (raises floor)
///           [Preset B]  split P1 into 3 sub-bands (smooth early curve)
///           [Preset C]  6-zone shape (5/10/20/40/15/10), wider total range
///           [Preset D]  combo: moderate start raise + reshape
///
/// Run:
///   forge test --match-contract LpPresetCompareTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract LpPresetCompareTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    int24 constant TICK_SPACING = 200;
    uint24 constant FEE = 10_000; // 1%

    uint256 constant LP_ALLOCATION = 639_800_000e18;

    PoolModifyLiquidityTest internal liqRouter;
    PoolSwapTest internal swapRouter;
    bool internal _onFork;

    struct Preset {
        string name;
        int24 startTick;
        // Tick offsets from startTick (must be aligned to 200).
        int24[] lowerOffsets;
        int24[] upperOffsets;
        // BPS must sum to 10_000.
        uint16[] bps;
    }

    struct Result {
        string name;
        uint256 ethTo50M; // cumulative ETH at first 50M LAYER acquired
        uint256 ethTo100M;
        uint256 ethTo250M;
        uint256 ethToHalfLp; // first 320M
        uint256 ethToExhaust; // ~99% of LP
        uint256 layerFor05Eth;
        uint256 layerFor1Eth;
        uint256 layerFor2Eth;
        uint256 layerFor5Eth;
        uint256 layerFor10Eth;
        uint256 layerFor50Eth;
        // Tick after each milestone (for FDV calc).
        int256 tickAt05Eth;
        int256 tickAt1Eth;
        int256 tickAt2Eth;
        int256 tickAt10Eth;
        int256 tickAt50Eth;
        int256 finalTick;
        // Inputs for reporting.
        int24 startTick;
        int24 endTick; // top of last position (offset from start)
        uint256 numPositions;
    }

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: no fork detected");
            return;
        }
        _onFork = true;
        liqRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
    }

    receive() external payable {}

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    function test_compare_presets() public onlyFork {
        // Headline: G + 3 new 12-position candidates.
        Result[] memory results = new Result[](4);
        results[0] = _runPreset(_presetG(), FEE);
        results[1] = _runPreset(_presetK(), FEE);
        results[2] = _runPreset(_presetL(), FEE);
        results[3] = _runPreset(_presetM(), FEE);

        console2.log("");
        console2.log("=========== HEAD-TO-HEAD ===========");
        for (uint256 i = 0; i < results.length; i++) {
            _logResult(results[i]);
        }
    }

    /// @notice Compares the multi-position presets against TokenWorks-style
    ///         single wide LP presets. Same launch tokenomics for all.
    function test_compare_singlePosition() public onlyFork {
        Result[] memory results = new Result[](7);
        results[0] = _runPreset(_baseline(), FEE);
        results[1] = _runPreset(_presetG(), FEE);
        results[2] = _runPreset(_presetK(), FEE);
        results[3] = _runPreset(_presetL(), FEE);
        results[4] = _runPreset(_presetS1(), FEE);
        results[5] = _runPreset(_presetS2(), FEE);
        results[6] = _runPreset(_presetS3(), FEE);

        console2.log("");
        console2.log("======= MULTI vs SINGLE-POSITION COMPARISON =======");
        for (uint256 i = 0; i < results.length; i++) {
            _logResult(results[i]);
        }
    }

    /// @notice Hypothetical anti-sniper model: fees from the elevated MEV
    ///         schedule are used to buy-and-burn LAYER (not paid to LP).
    ///         For each fee tier and chosen preset, simulate two swaps:
    ///           1. Buyer swap: (input * (1 - fee)) ETH -> LAYER for buyer
    ///           2. Burn swap:  (input * fee) ETH -> LAYER -> burned
    ///         Pool is initialized with fee=0 so each swap walks the LP
    ///         curve cleanly; the fee is modeled externally.
    ///
    ///         Reports per tier: ETH in, fee%, fee ETH, buyer ETH, buyer
    ///         LAYER, burn LAYER, final tick, FDV.
    function test_antisniperBurnModel_S3() public onlyFork {
        _antisniperBurnSweep(_presetS3());
    }

    function test_antisniperBurnModel_K() public onlyFork {
        _antisniperBurnSweep(_presetK());
    }

    function test_antisniperBurnModel_L() public onlyFork {
        _antisniperBurnSweep(_presetL());
    }

    function _antisniperBurnSweep(Preset memory p) internal {
        uint16[6] memory feePcts =
            [uint16(50), uint16(25), uint16(15), uint16(7), uint16(3), uint16(1)];
        string[6] memory names = [
            "min 0    (50% sniper fee)",
            "min 1-3  (25% sniper fee)",
            "min 3-5  (15% sniper fee)",
            "min 5-10 ( 7% sniper fee)",
            "min 10-15( 3% sniper fee)",
            "min 15+  ( 1% normal fee)"
        ];

        console2.log("");
        console2.log("======= ANTI-SNIPER (fees -> buy-and-burn) =======");
        console2.log(p.name);

        for (uint256 i = 0; i < feePcts.length; i++) {
            (uint256 buyerLayer, uint256 burnLayer, int256 finalLayerTick) =
                _runBurnModel(p, 0.5 ether, feePcts[i]);

            uint256 feeEth = uint256(feePcts[i]) * 0.5 ether / 100;
            uint256 buyerEth = 0.5 ether - feeEth;
            uint256 fdv = _fdvAtTick(finalLayerTick);
            console2.log(
                string.concat(
                    names[i],
                    ":  buyer=",
                    _u(buyerLayer / 1e18),
                    "M",
                    "  burned=",
                    _u(burnLayer / 1e18),
                    "M",
                    "  feeETH=",
                    _u(feeEth / 1e15),
                    "m",
                    "  FDV=$",
                    _u(fdv)
                )
            );
        }
    }

    function _runBurnModel(Preset memory p, uint256 ethIn, uint16 feePct)
        internal
        returns (uint256 buyerLayer, uint256 burnLayer, int256 finalLayerTick)
    {
        // Fresh pool with NO LP fee — fees modeled externally.
        MintToken layer = new MintToken("Liquidity Layer", "LAYER");
        bool layerIsToken0 = address(layer) < WETH;
        (address c0, address c1) = layerIsToken0 ? (address(layer), WETH) : (WETH, address(layer));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        int24 initTick = layerIsToken0 ? p.startTick : -p.startTick;
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(initTick));

        layer.mint(address(this), LP_ALLOCATION);
        IERC20(address(layer)).approve(address(liqRouter), type(uint256).max);
        vm.deal(address(this), 100 ether);
        IWETH9(payable(WETH)).deposit{value: 5 ether}();
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);

        for (uint256 i = 0; i < p.bps.length; i++) {
            _seedOne(
                key,
                layer,
                p.startTick,
                p.lowerOffsets[i],
                p.upperOffsets[i],
                p.bps[i],
                layerIsToken0
            );
        }

        uint256 feeEth = uint256(feePct) * ethIn / 100;
        uint256 buyerEth = ethIn - feeEth;

        // Step 1: buyer swap.
        uint256 layerBefore = layer.balanceOf(address(this));
        try this._buy(key, layerIsToken0, buyerEth) {
            buyerLayer = layer.balanceOf(address(this)) - layerBefore;
        } catch {
            buyerLayer = 0;
        }

        // Step 2: burn swap.
        if (feeEth > 0) {
            uint256 layerBefore2 = layer.balanceOf(address(this));
            try this._buy(key, layerIsToken0, feeEth) {
                burnLayer = layer.balanceOf(address(this)) - layerBefore2;
            } catch {
                burnLayer = 0;
            }
        }

        (, int24 finalTick,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        finalLayerTick = layerIsToken0 ? int256(finalTick) : -int256(finalTick);
    }

    /// @notice Anti-sniper impact: same preset, varying pool fee tier to model
    ///         the stepped MEV schedule. The preset evaluated here should be
    ///         the chosen winner from test_compare_presets.
    function test_antisniper_impact_on_K() public onlyFork {
        // Fee tiers in v4 ppm: 1% = 10_000, 3% = 30_000, 7% = 70_000,
        // 15% = 150_000, 25% = 250_000, 50% = 500_000.
        uint24[6] memory tiers = [
            uint24(500_000), // 0-60s        (50%)
            uint24(250_000), // 60-180s      (25%)
            uint24(150_000), // 180-300s     (15%)
            uint24(70_000), // 300-600s     (7%)
            uint24(30_000), // 600-900s     (3%)
            uint24(10_000) // 900s+        (1% normal)
        ];
        string[6] memory tierNames = [
            string("min 0   (50% sniper fee)"),
            string("min 1-3 (25% sniper fee)"),
            string("min 3-5 (15% sniper fee)"),
            string("min 5-10 (7% sniper fee)"),
            string("min 10-15 (3% sniper fee)"),
            string("min 15+   (1% normal)")
        ];

        console2.log("");
        console2.log("======= ANTI-SNIPER IMPACT (Preset K, first 0.5 ETH buy) =======");
        for (uint256 i = 0; i < tiers.length; i++) {
            (uint256 layerOut, int24 tickAfter) = _runFirstBuy(_presetK(), tiers[i], 0.5 ether);
            console2.log(
                string.concat(
                    tierNames[i],
                    ":  ",
                    _u(layerOut / 1e18),
                    "M LAYER  (tick=",
                    _i(int256(tickAfter)),
                    ")"
                )
            );
        }
    }

    // ─── presets ─────────────────────────────────────────────────────────

    function _baseline() internal pure returns (Preset memory p) {
        p.name = "Baseline (current LaunchDefaults)";
        p.startTick = -230_400;
        p.lowerOffsets = _arr4(0, 16_400, 75_400, 89_400);
        p.upperOffsets = _arr4(16_400, 75_400, 89_400, 110_400);
        p.bps = _bpsArr4(2500, 4500, 2000, 1000);
    }

    function _presetA() internal pure returns (Preset memory p) {
        p.name = "A: same shape, start +20000 ticks higher";
        p.startTick = -210_400;
        p.lowerOffsets = _arr4(0, 16_400, 75_400, 89_400);
        p.upperOffsets = _arr4(16_400, 75_400, 89_400, 110_400);
        p.bps = _bpsArr4(2500, 4500, 2000, 1000);
    }

    function _presetB() internal pure returns (Preset memory p) {
        p.name = "B: split P1 into 3 sub-bands (P1a/P1b/P1c)";
        p.startTick = -230_400;
        // P1 was [0, 16400) at 2500 bps. Split into 3:
        //   P1a [0, 5400)     = 500 bps  (thin floor)
        //   P1b [5400, 10800) = 1000 bps
        //   P1c [10800, 16400) = 1000 bps
        // Then unchanged: P2 [16400, 75400) 4500, P3 2000, P4 1000.
        // Total = 500 + 1000 + 1000 + 4500 + 2000 + 1000 = 10_000.
        int24[] memory lo = new int24[](6);
        int24[] memory hi = new int24[](6);
        uint16[] memory b = new uint16[](6);
        lo[0] = 0;
        hi[0] = 5400;
        b[0] = 500;
        lo[1] = 5400;
        hi[1] = 10_800;
        b[1] = 1000;
        lo[2] = 10_800;
        hi[2] = 16_400;
        b[2] = 1000;
        lo[3] = 16_400;
        hi[3] = 75_400;
        b[3] = 4500;
        lo[4] = 75_400;
        hi[4] = 89_400;
        b[4] = 2000;
        lo[5] = 89_400;
        hi[5] = 110_400;
        b[5] = 1000;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    function _presetC() internal pure returns (Preset memory p) {
        p.name = "C: 6-zone reshape (5/10/20/40/15/10)";
        p.startTick = -230_400;
        // Wider, more granular distribution. floor 5% / early 10% / launch 20%
        // / main 40% / maturity 15% / tail 10%. Stretches across same total
        // range as baseline (110_400 ticks) but shifts mass upward.
        int24[] memory lo = new int24[](6);
        int24[] memory hi = new int24[](6);
        uint16[] memory b = new uint16[](6);
        lo[0] = 0; // floor
        hi[0] = 8000;
        b[0] = 500;
        lo[1] = 8000; // early
        hi[1] = 24_000;
        b[1] = 1000;
        lo[2] = 24_000; // launch
        hi[2] = 50_000;
        b[2] = 2000;
        lo[3] = 50_000; // main growth
        hi[3] = 80_000;
        b[3] = 4000;
        lo[4] = 80_000; // maturity
        hi[4] = 100_000;
        b[4] = 1500;
        lo[5] = 100_000; // tail
        hi[5] = 130_000;
        b[5] = 1000;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    function _presetD() internal pure returns (Preset memory p) {
        p.name = "D: combo - start +10000 + 6-zone reshape";
        p.startTick = -220_400; // halfway between baseline and A
        int24[] memory lo = new int24[](6);
        int24[] memory hi = new int24[](6);
        uint16[] memory b = new uint16[](6);
        lo[0] = 0;
        hi[0] = 8000;
        b[0] = 500;
        lo[1] = 8000;
        hi[1] = 24_000;
        b[1] = 1000;
        lo[2] = 24_000;
        hi[2] = 50_000;
        b[2] = 2000;
        lo[3] = 50_000;
        hi[3] = 80_000;
        b[3] = 4000;
        lo[4] = 80_000;
        hi[4] = 100_000;
        b[4] = 1500;
        lo[5] = 100_000;
        hi[5] = 130_000;
        b[5] = 1000;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    function _presetE() internal pure returns (Preset memory p) {
        p.name = "E: same shape, start +30000 (-200400)";
        p.startTick = -200_400;
        p.lowerOffsets = _arr4(0, 16_400, 75_400, 89_400);
        p.upperOffsets = _arr4(16_400, 75_400, 89_400, 110_400);
        p.bps = _bpsArr4(2500, 4500, 2000, 1000);
    }

    function _presetF() internal pure returns (Preset memory p) {
        p.name = "F: same shape, start +40000 (-190400)";
        p.startTick = -190_400;
        p.lowerOffsets = _arr4(0, 16_400, 75_400, 89_400);
        p.upperOffsets = _arr4(16_400, 75_400, 89_400, 110_400);
        p.bps = _bpsArr4(2500, 4500, 2000, 1000);
    }

    function _presetG() internal pure returns (Preset memory p) {
        p.name = "G: 6-zone reshape + start +30000 (-200400)";
        p.startTick = -200_400;
        int24[] memory lo = new int24[](6);
        int24[] memory hi = new int24[](6);
        uint16[] memory b = new uint16[](6);
        lo[0] = 0;
        hi[0] = 8000;
        b[0] = 500;
        lo[1] = 8000;
        hi[1] = 24_000;
        b[1] = 1000;
        lo[2] = 24_000;
        hi[2] = 50_000;
        b[2] = 2000;
        lo[3] = 50_000;
        hi[3] = 80_000;
        b[3] = 4000;
        lo[4] = 80_000;
        hi[4] = 100_000;
        b[4] = 1500;
        lo[5] = 100_000;
        hi[5] = 130_000;
        b[5] = 1000;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    /// @dev Presets H/I/J compress total tick width while raising start, to
    ///      hit both "0.5 ETH ≤ 100M" and "exhaust ≈ 200 ETH" simultaneously.
    function _presetH() internal pure returns (Preset memory p) {
        p.name = "H: start +20000 + tight width (~17500 ticks total)";
        p.startTick = -210_400;
        // Same 25/45/20/10 bps but compressed into ~17500 ticks total.
        p.lowerOffsets = _arr4(0, 4000, 11_800, 14_000);
        p.upperOffsets = _arr4(4000, 11_800, 14_000, 17_400);
        p.bps = _bpsArr4(2500, 4500, 2000, 1000);
    }

    function _presetI() internal pure returns (Preset memory p) {
        p.name = "I: start +20000 + medium width (~35000) + 6-zone";
        p.startTick = -210_400;
        // 6 zones, total width 35000 ticks.
        int24[] memory lo = new int24[](6);
        int24[] memory hi = new int24[](6);
        uint16[] memory b = new uint16[](6);
        lo[0] = 0; // floor 5%
        hi[0] = 2400;
        b[0] = 500;
        lo[1] = 2400; // early 10%
        hi[1] = 7400;
        b[1] = 1000;
        lo[2] = 7400; // launch 20%
        hi[2] = 16_000;
        b[2] = 2000;
        lo[3] = 16_000; // main growth 40%
        hi[3] = 25_400;
        b[3] = 4000;
        lo[4] = 25_400; // maturity 15%
        hi[4] = 31_000;
        b[4] = 1500;
        lo[5] = 31_000; // tail 10%
        hi[5] = 35_000;
        b[5] = 1000;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    /// @dev K — 12-position, start -195400, total width 75000 ticks. Aggressive
    ///      taper. Floor positions are tiny so 0.5 ETH walks past them quickly.
    ///      Mid-range carries the bulk of LAYER for real price discovery.
    function _presetK() internal pure returns (Preset memory p) {
        p.name = "K: 12-pos, start -195400, width 75000, aggressive taper";
        p.startTick = -195_400;
        int24[] memory lo = new int24[](12);
        int24[] memory hi = new int24[](12);
        uint16[] memory b = new uint16[](12);
        // sums to 10_000:  100+200+400+700+1000+1500+2000+1500+1000+700+600+300
        lo[0] = 0;
        hi[0] = 2000;
        b[0] = 100;
        lo[1] = 2000;
        hi[1] = 4400;
        b[1] = 200;
        lo[2] = 4400;
        hi[2] = 8000;
        b[2] = 400;
        lo[3] = 8000;
        hi[3] = 13_000;
        b[3] = 700;
        lo[4] = 13_000;
        hi[4] = 19_400;
        b[4] = 1000;
        lo[5] = 19_400;
        hi[5] = 27_400;
        b[5] = 1500;
        lo[6] = 27_400;
        hi[6] = 36_400;
        b[6] = 2000;
        lo[7] = 36_400;
        hi[7] = 46_000;
        b[7] = 1500;
        lo[8] = 46_000;
        hi[8] = 54_400;
        b[8] = 1000;
        lo[9] = 54_400;
        hi[9] = 62_400;
        b[9] = 700;
        lo[10] = 62_400;
        hi[10] = 69_400;
        b[10] = 600;
        lo[11] = 69_400;
        hi[11] = 75_000;
        b[11] = 300;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    /// @dev L — 12-position, start -190400 (higher), width 60000 (tighter).
    ///      Even thinner floor (50 bps). Heavier mid-range.
    function _presetL() internal pure returns (Preset memory p) {
        p.name = "L: 12-pos, start -190400, width 60000, thin floor";
        p.startTick = -190_400;
        int24[] memory lo = new int24[](12);
        int24[] memory hi = new int24[](12);
        uint16[] memory b = new uint16[](12);
        // sums: 50+150+300+500+800+1300+1700+1700+1300+1000+800+400 = 10000
        lo[0] = 0;
        hi[0] = 1400;
        b[0] = 50;
        lo[1] = 1400;
        hi[1] = 3400;
        b[1] = 150;
        lo[2] = 3400;
        hi[2] = 6000;
        b[2] = 300;
        lo[3] = 6000;
        hi[3] = 9400;
        b[3] = 500;
        lo[4] = 9400;
        hi[4] = 14_000;
        b[4] = 800;
        lo[5] = 14_000;
        hi[5] = 19_400;
        b[5] = 1300;
        lo[6] = 19_400;
        hi[6] = 26_000;
        b[6] = 1700;
        lo[7] = 26_000;
        hi[7] = 33_000;
        b[7] = 1700;
        lo[8] = 33_000;
        hi[8] = 40_000;
        b[8] = 1300;
        lo[9] = 40_000;
        hi[9] = 47_000;
        b[9] = 1000;
        lo[10] = 47_000;
        hi[10] = 53_400;
        b[10] = 800;
        lo[11] = 53_400;
        hi[11] = 60_000;
        b[11] = 400;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    /// @dev M — 12-position, start -200400, wider width 85000. Very thin floor
    ///      (50 bps), more upside headroom for moonshot price discovery.
    function _presetM() internal pure returns (Preset memory p) {
        p.name = "M: 12-pos, start -200400, width 85000, wide tail";
        p.startTick = -200_400;
        int24[] memory lo = new int24[](12);
        int24[] memory hi = new int24[](12);
        uint16[] memory b = new uint16[](12);
        // sums: 50+150+300+500+800+1200+1700+1700+1200+1000+800+600 = 10000
        lo[0] = 0;
        hi[0] = 2400;
        b[0] = 50;
        lo[1] = 2400;
        hi[1] = 5400;
        b[1] = 150;
        lo[2] = 5400;
        hi[2] = 9400;
        b[2] = 300;
        lo[3] = 9400;
        hi[3] = 14_400;
        b[3] = 500;
        lo[4] = 14_400;
        hi[4] = 21_000;
        b[4] = 800;
        lo[5] = 21_000;
        hi[5] = 29_000;
        b[5] = 1200;
        lo[6] = 29_000;
        hi[6] = 38_000;
        b[6] = 1700;
        lo[7] = 38_000;
        hi[7] = 47_400;
        b[7] = 1700;
        lo[8] = 47_400;
        hi[8] = 57_000;
        b[8] = 1200;
        lo[9] = 57_000;
        hi[9] = 66_400;
        b[9] = 1000;
        lo[10] = 66_400;
        hi[10] = 76_000;
        b[10] = 800;
        lo[11] = 76_000;
        hi[11] = 85_000;
        b[11] = 600;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    // ─── single-position TokenWorks-style presets ────────────────────────
    //
    // Single wide position holding all 639.8M LAYER. Liquidity L is uniform
    // across the range, which means LAYER amount per tick is _not_ uniform —
    // at the floor (low sqrtPrice) each unit of L holds a lot of LAYER, at
    // the ceiling each unit holds very little. Practically this means a
    // single wide position concentrates LAYER at the cheap end, the opposite
    // of what we want for sniper resistance unless the floor itself is high.

    /// @dev S1 — Very wide single position. Mirrors the original LAYER curve
    ///      bounds: floor at -230400, ceiling near -50000. All 639.8M LAYER.
    ///      Maximum simplicity, maximum range, but expect terrible floor.
    function _presetS1() internal pure returns (Preset memory p) {
        p.name = "S1: single wide [-230400, -50000), 1 position";
        p.startTick = -230_400;
        int24[] memory lo = new int24[](1);
        int24[] memory hi = new int24[](1);
        uint16[] memory b = new uint16[](1);
        lo[0] = 0;
        hi[0] = 180_400; // -230400 + 180400 = -50000
        b[0] = 10_000;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    /// @dev S2 — Single position with Preset G's bounds. Range matches G's
    ///      tapered version so we can isolate the single-position cost.
    function _presetS2() internal pure returns (Preset memory p) {
        p.name = "S2: single [-200400, -70400), 1 position (G's bounds)";
        p.startTick = -200_400;
        int24[] memory lo = new int24[](1);
        int24[] memory hi = new int24[](1);
        uint16[] memory b = new uint16[](1);
        lo[0] = 0;
        hi[0] = 130_000;
        b[0] = 10_000;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    /// @dev S3 — Higher floor, narrower upside. Aimed at the same sniper-
    ///      resistance band as L/K but with a single position.
    function _presetS3() internal pure returns (Preset memory p) {
        p.name = "S3: single [-190400, -100400), 1 position (compressed)";
        p.startTick = -190_400;
        int24[] memory lo = new int24[](1);
        int24[] memory hi = new int24[](1);
        uint16[] memory b = new uint16[](1);
        lo[0] = 0;
        hi[0] = 90_000;
        b[0] = 10_000;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    function _presetJ() internal pure returns (Preset memory p) {
        p.name = "J: start +30000 + tight width (~25000) + 6-zone";
        p.startTick = -200_400;
        int24[] memory lo = new int24[](6);
        int24[] memory hi = new int24[](6);
        uint16[] memory b = new uint16[](6);
        lo[0] = 0;
        hi[0] = 1600;
        b[0] = 500;
        lo[1] = 1600;
        hi[1] = 5400;
        b[1] = 1000;
        lo[2] = 5400;
        hi[2] = 11_400;
        b[2] = 2000;
        lo[3] = 11_400;
        hi[3] = 18_400;
        b[3] = 4000;
        lo[4] = 18_400;
        hi[4] = 22_400;
        b[4] = 1500;
        lo[5] = 22_400;
        hi[5] = 25_400;
        b[5] = 1000;
        p.lowerOffsets = lo;
        p.upperOffsets = hi;
        p.bps = b;
    }

    // ─── runner ──────────────────────────────────────────────────────────

    function _runPreset(Preset memory p, uint24 poolFee) internal returns (Result memory r) {
        r.name = p.name;
        r.startTick = p.startTick;
        r.numPositions = p.bps.length;
        r.endTick = p.startTick + p.upperOffsets[p.upperOffsets.length - 1];

        // Fresh token = fresh pool.
        MintToken layer = new MintToken("Liquidity Layer", "LAYER");
        bool layerIsToken0 = address(layer) < WETH;
        (address c0, address c1) = layerIsToken0 ? (address(layer), WETH) : (WETH, address(layer));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: poolFee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        int24 initTick = layerIsToken0 ? p.startTick : -p.startTick;
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(initTick));

        layer.mint(address(this), LP_ALLOCATION);
        IERC20(address(layer)).approve(address(liqRouter), type(uint256).max);

        vm.deal(address(this), 5000 ether);
        IWETH9(payable(WETH)).deposit{value: 5000 ether}();
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);

        for (uint256 i = 0; i < p.bps.length; i++) {
            _seedOne(
                key,
                layer,
                p.startTick,
                p.lowerOffsets[i],
                p.upperOffsets[i],
                p.bps[i],
                layerIsToken0
            );
        }

        uint256[18] memory buys = [
            uint256(0.1 ether),
            uint256(0.5 ether),
            uint256(1 ether),
            uint256(2 ether),
            uint256(5 ether),
            uint256(10 ether),
            uint256(15 ether),
            uint256(25 ether),
            uint256(50 ether),
            uint256(75 ether),
            uint256(100 ether),
            uint256(150 ether),
            uint256(200 ether),
            uint256(300 ether),
            uint256(500 ether),
            uint256(750 ether),
            uint256(1000 ether),
            uint256(1500 ether)
        ];

        uint256 cumEth = 0;
        uint256 cumLayer = 0;
        for (uint256 i = 0; i < buys.length; i++) {
            uint256 ethIn = buys[i];
            uint256 layerBefore = layer.balanceOf(address(this));
            try this._buy(key, layerIsToken0, ethIn) {
                uint256 layerOut = layer.balanceOf(address(this)) - layerBefore;
                cumEth += ethIn;
                cumLayer += layerOut;

                (, int24 tk,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
                // Normalize: store "LAYER tick" (positive = LAYER expensive)
                // independent of token0/token1 sort order.
                int256 lt = layerIsToken0 ? int256(tk) : -int256(tk);

                if (r.layerFor05Eth == 0 && cumEth >= 0.5 ether) {
                    r.layerFor05Eth = cumLayer;
                    r.tickAt05Eth = lt;
                }
                if (r.layerFor1Eth == 0 && cumEth >= 1 ether) {
                    r.layerFor1Eth = cumLayer;
                    r.tickAt1Eth = lt;
                }
                if (r.layerFor2Eth == 0 && cumEth >= 2 ether) {
                    r.layerFor2Eth = cumLayer;
                    r.tickAt2Eth = lt;
                }
                if (r.layerFor5Eth == 0 && cumEth >= 5 ether) {
                    r.layerFor5Eth = cumLayer;
                }
                if (r.layerFor10Eth == 0 && cumEth >= 10 ether) {
                    r.layerFor10Eth = cumLayer;
                    r.tickAt10Eth = lt;
                }
                if (r.layerFor50Eth == 0 && cumEth >= 50 ether) {
                    r.layerFor50Eth = cumLayer;
                    r.tickAt50Eth = lt;
                }

                if (r.ethTo50M == 0 && cumLayer >= 50_000_000e18) r.ethTo50M = cumEth;
                if (r.ethTo100M == 0 && cumLayer >= 100_000_000e18) r.ethTo100M = cumEth;
                if (r.ethTo250M == 0 && cumLayer >= 250_000_000e18) r.ethTo250M = cumEth;
                if (r.ethToHalfLp == 0 && cumLayer >= LP_ALLOCATION / 2) r.ethToHalfLp = cumEth;
                if (r.ethToExhaust == 0 && cumLayer >= (LP_ALLOCATION * 99) / 100) {
                    r.ethToExhaust = cumEth;
                }
            } catch {
                break;
            }
        }

        (, int24 finalTk,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        r.finalTick = int256(finalTk);
    }

    /// @notice Seed once + execute a single buy at given ETH; return LAYER out and tick after.
    ///         Used for anti-sniper impact sweep (different pool fees).
    function _runFirstBuy(Preset memory p, uint24 poolFee, uint256 ethIn)
        internal
        returns (uint256 layerOut, int24 tickAfter)
    {
        MintToken layer = new MintToken("Liquidity Layer", "LAYER");
        bool layerIsToken0 = address(layer) < WETH;
        (address c0, address c1) = layerIsToken0 ? (address(layer), WETH) : (WETH, address(layer));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: poolFee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        int24 initTick = layerIsToken0 ? p.startTick : -p.startTick;
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(initTick));

        layer.mint(address(this), LP_ALLOCATION);
        IERC20(address(layer)).approve(address(liqRouter), type(uint256).max);
        vm.deal(address(this), 100 ether);
        IWETH9(payable(WETH)).deposit{value: 10 ether}();
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);

        for (uint256 i = 0; i < p.bps.length; i++) {
            _seedOne(
                key,
                layer,
                p.startTick,
                p.lowerOffsets[i],
                p.upperOffsets[i],
                p.bps[i],
                layerIsToken0
            );
        }

        uint256 layerBefore = layer.balanceOf(address(this));
        this._buy(key, layerIsToken0, ethIn);
        layerOut = layer.balanceOf(address(this)) - layerBefore;
        (, tickAfter,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
    }

    function _seedOne(
        PoolKey memory key,
        MintToken layer,
        int24 startTick,
        int24 lowerOffset,
        int24 upperOffset,
        uint16 bps,
        bool layerIsToken0
    ) internal {
        uint256 amount = (LP_ALLOCATION * bps) / 10_000;
        int24 lower;
        int24 upper;
        if (layerIsToken0) {
            lower = startTick + lowerOffset;
            upper = startTick + upperOffset;
        } else {
            lower = -(startTick + upperOffset);
            upper = -(startTick + lowerOffset);
        }
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        uint128 L = layerIsToken0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, amount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, amount);
        liqRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(L)),
                salt: bytes32(0)
            }),
            ""
        );
        layer; // silence unused
    }

    /// @dev External so we can wrap with try/catch.
    function _buy(PoolKey memory key, bool layerIsToken0, uint256 wethIn) external {
        bool zeroForOne = !layerIsToken0;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(wethIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(
            key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
    }

    function _logResult(Result memory r) internal pure {
        console2.log("");
        console2.log("---");
        console2.log(r.name);
        console2.log(
            string.concat(
                "  start=",
                _i(int256(r.startTick)),
                "  end=",
                _i(int256(r.endTick)),
                "  width=",
                _u(uint256(int256(r.endTick - r.startTick))),
                "  positions=",
                _u(r.numPositions)
            )
        );
        console2.log("  LP=639.8M LAYER, no ETH/WETH seed");
        console2.log(string.concat("  0.5 ETH -> ", _u(r.layerFor05Eth / 1e18), "M LAYER"));
        console2.log(string.concat("  1.0 ETH -> ", _u(r.layerFor1Eth / 1e18), "M LAYER"));
        console2.log(string.concat("  2.0 ETH -> ", _u(r.layerFor2Eth / 1e18), "M LAYER"));
        console2.log(string.concat("  5.0 ETH -> ", _u(r.layerFor5Eth / 1e18), "M LAYER"));
        console2.log(string.concat("  10  ETH -> ", _u(r.layerFor10Eth / 1e18), "M LAYER"));
        console2.log(string.concat("  50  ETH -> ", _u(r.layerFor50Eth / 1e18), "M LAYER"));
        console2.log(string.concat("  Exhaust  : ", _u(r.ethToExhaust / 1e15), " mETH"));
        console2.log(string.concat("  FDV @ 0.5 ETH: ~$", _u(_fdvAtTick(r.tickAt05Eth))));
        console2.log(string.concat("  FDV @ 1   ETH: ~$", _u(_fdvAtTick(r.tickAt1Eth))));
        console2.log(string.concat("  FDV @ 2   ETH: ~$", _u(_fdvAtTick(r.tickAt2Eth))));
        console2.log(string.concat("  FDV @ 10  ETH: ~$", _u(_fdvAtTick(r.tickAt10Eth))));
        // Post-burn total = 739.8M (LP 639.8M + airdrop 100M).
        console2.log(
            string.concat(
                "  Wallet capture @ 0.5 ETH: ",
                _u(r.layerFor05Eth * 10_000 / 739_800_000e18),
                " bps of post-burn (739.8M)  /  ",
                _u(r.layerFor05Eth * 10_000 / LP_ALLOCATION),
                " bps of LP (639.8M)"
            )
        );
    }

    /// @dev Approximate FDV in USD at given pool tick. Assumes ETH=$2300,
    ///      LAYER post-burn supply 739.8M. Uses sqrtPrice math with shift to
    ///      avoid uint256 overflow at extreme ticks.
    function _fdvAtTick(int256 layerTick) internal pure returns (uint256) {
        if (layerTick == 0) return 0;
        if (layerTick < TickMath.MIN_TICK || layerTick > TickMath.MAX_TICK) return 0;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(int24(layerTick));
        uint256 q = uint256(sqrtP) >> 64; // q ≤ ~2^96
        uint256 q2 = q * q; // ≤ ~2^192
        if (q2 == 0) return 0;
        // wpl_e18 = WETH per LAYER scaled to 1e18 (when LAYER=token0):
        //   = sqrtP^2 / 2^192 * 1e18 = q2 * 1e18 / 2^64
        // Watch overflow: q2 * 1e18 ≤ 2^192 * 2^60 = 2^252 → fits.
        uint256 wpl_e18 = (q2 * 1e18) >> 64;
        // FDV USD = supply_layer × WETH_per_layer × ETH_USD
        // supply 739.8M = 739_800_000, ETH_USD = 2300.
        // result in plain USD (no decimals).
        return (uint256(739_800_000) * wpl_e18 * 2300) / 1e18;
    }

    function _i(int256 x) internal pure returns (string memory) {
        if (x < 0) return string.concat("-", _u(uint256(-x)));
        return _u(uint256(x));
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _arr4(int24 a, int24 b, int24 c, int24 d) internal pure returns (int24[] memory r) {
        r = new int24[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    function _bpsArr4(uint16 a, uint16 b, uint16 c, uint16 d)
        internal
        pure
        returns (uint16[] memory r)
    {
        r = new uint16[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    function _u(uint256 x) internal pure returns (string memory) {
        return vm.toString(x);
    }
}
