// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

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

/// @title LpTierWalkthroughTest
/// @notice Mainnet-fork simulation of LAYER's 4-position single-sided LP under
///         repeated ETH-side buying. Logs price progression, per-tier WETH
///         received, and LAYER consumed as buy pressure walks the price up
///         through P1 → P2 → P3 → P4.
///
///         Useful for sanity-checking the LP shape: how much WETH does it
///         take to traverse each band, and what's the marginal price at
///         each milestone? No hook, no fee distribution — just the LP curve.
///
/// Run:
///   forge test --match-contract LpTierWalkthroughTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract LpTierWalkthroughTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Same starting tick LAYER will use on mainnet (matches Base launch).
    int24 constant STARTING_TICK = -230_400;
    /// @dev LP allocation after migration burn (260.2M) and airdrop (100M):
    ///      1B − 260.2M − 100M = 639.8M LAYER. Matches LaunchLayer.s.sol:62.
    uint256 constant LP_ALLOCATION = 639_800_000e18;

    MintToken internal layer;
    PoolModifyLiquidityTest internal liqRouter;
    PoolSwapTest internal swapRouter;
    PoolKey internal poolKey;
    bool internal _onFork;
    bool internal _layerIsToken0;

    // Per-tier state for reporting.
    int24[4] internal lowerTicks;
    int24[4] internal upperTicks;
    uint256[4] internal layerSeeded;
    uint128[4] internal liquidityPerTier;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: no fork detected. Run with --fork-url $MAINNET_RPC_URL");
            return;
        }
        _onFork = true;

        layer = new MintToken("Liquidity Layer", "LAYER");
        liqRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        // Build canonical key: LAYER/WETH, no hook, 1% static fee, tickSpacing 200.
        // Matches LaunchLayer.s.sol's PoolKey shape modulo the hook (omitted
        // here — we want to isolate LP behavior from the MEV stepped-fee module).
        _layerIsToken0 = address(layer) < WETH;
        (address c0, address c1) = _layerIsToken0 ? (address(layer), WETH) : (WETH, address(layer));
        poolKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LaunchDefaults.BUY_FEE, // 1% static
            tickSpacing: LaunchDefaults.TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // Initialize at the same starting tick LAYER ships with.
        // If LAYER ends up as token1 the factory flips the sign — replicate that here.
        int24 initTick = _layerIsToken0 ? STARTING_TICK : -STARTING_TICK;
        IPoolManager(POOL_MANAGER).initialize(poolKey, TickMath.getSqrtPriceAtTick(initTick));

        // Mint LAYER for seeding.
        layer.mint(address(this), LP_ALLOCATION);
        IERC20(address(layer)).approve(address(liqRouter), type(uint256).max);

        // Wrap a chunk of ETH for the buyer.
        vm.deal(address(this), 5000 ether);
        IWETH9(payable(WETH)).deposit{value: 5000 ether}();
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);

        _seedFourPositions(initTick);
    }

    receive() external payable {}

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    /// @notice Walks ETH-side buy pressure into the pool and reports tier
    ///         progression. Buys are sized to roughly clear each tier in turn.
    function test_walkthrough_buyPressure() public onlyFork {
        console2.log("");
        console2.log("=== LAYER LP tier walkthrough (single-sided) ===");
        console2.log("Starting tick:    %s", _i(STARTING_TICK));
        console2.log("LP allocation:    %s LAYER", LP_ALLOCATION / 1e18);
        _logSeedTable();

        // Snap pool state.
        (uint160 sqrtP, int24 tick,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        console2.log("");
        console2.log("Initial tick:                %s", _i(tick));
        console2.log("Initial LAYER per 1 ETH:     %s", _laYerPerEthAtTick(tick) / 1e18);

        // Buy series: increasing sizes, log after each.
        uint256[10] memory buys = [
            uint256(0.5 ether),
            uint256(2 ether),
            uint256(5 ether),
            uint256(10 ether),
            uint256(25 ether),
            uint256(50 ether),
            uint256(100 ether),
            uint256(250 ether),
            uint256(500 ether),
            uint256(1000 ether)
        ];

        uint256 cumulativeEthIn = 0;
        uint256 cumulativeLayerOut = 0;
        uint256 lastTier = 0;

        for (uint256 i = 0; i < buys.length; i++) {
            uint256 ethIn = buys[i];
            uint256 layerBefore = layer.balanceOf(address(this));
            _buyLayer(ethIn);
            uint256 layerOut = layer.balanceOf(address(this)) - layerBefore;

            cumulativeEthIn += ethIn;
            cumulativeLayerOut += layerOut;

            (, int24 tickAfter,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
            uint256 currentTier = _tierAt(tickAfter);

            if (currentTier != lastTier) {
                console2.log("");
                console2.log("--- ENTERED %s ---", _tierName(currentTier));
                lastTier = currentTier;
            }

            // If LP is fully exhausted past P4, the pool is pinned at MAX_SQRT.
            // Any further swap reverts. Stop here — data above is the full picture.
            if (currentTier == 5) {
                console2.log("");
                console2.log("LP exhausted. Stopping walk.");
                break;
            }

            console2.log(
                string.concat(
                    "Buy ",
                    _u(i + 1),
                    ": ",
                    _u(ethIn / 1e18),
                    ".",
                    _u((ethIn % 1e18) / 1e15),
                    " ETH in -> ",
                    _u(layerOut / 1e18),
                    " LAYER out"
                )
            );
            string memory marginal = currentTier == 5
                ? "LP exhausted"
                // Divide by 1e18 so the number is "LAYER per 1 ETH".
                : _u(_laYerPerEthAtTick(tickAfter) / 1e18);
            console2.log(
                string.concat(
                    "  tick=",
                    _i(tickAfter),
                    "  marginal LAYER/ETH=",
                    marginal,
                    "  cum ETH=",
                    _u(cumulativeEthIn / 1e18),
                    ".",
                    _u((cumulativeEthIn % 1e18) / 1e15) // milliseconds-of-ETH
                )
            );
        }

        console2.log("");
        console2.log("=== Summary ===");
        console2.log("Total ETH spent:        %s ETH", cumulativeEthIn / 1e18);
        console2.log("Total LAYER acquired:   %s LAYER", cumulativeLayerOut / 1e18);
        console2.log(
            "LAYER remaining in LP:  %s LAYER", (LP_ALLOCATION - cumulativeLayerOut) / 1e18
        );
        console2.log(
            "Pct of LP consumed:     %s bps", (cumulativeLayerOut * 10_000) / LP_ALLOCATION
        );
        (, int24 finalTick,,) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
        console2.log("Final tick:             %s", _i(finalTick));
        console2.log("Final tier:             %s", _tierName(_tierAt(finalTick)));
        // FDV implied = (1B / LAYER per ETH) * ETH price (USD); we leave USD math
        // to the reader, since ETH price drifts over the test's lifetime.
    }

    // ─── seeding ─────────────────────────────────────────────────────────

    function _seedFourPositions(int24 startTick) internal {
        // From LaunchDefaults: 4 single-sided LAYER positions whose LAYER amounts
        // are split per `positionBps` over LP_ALLOCATION.
        (int24[] memory tl, int24[] memory tu, uint16[] memory bps) =
            LaunchDefaults.buildRecommendedPositions(startTick);

        for (uint256 i = 0; i < 4; i++) {
            uint256 amount = (LP_ALLOCATION * bps[i]) / 10_000;
            // If LAYER is token1 (sorts higher than WETH), flip the position
            // to the other side of the price by negating offsets — matches
            // the factory's tick-flipping behavior.
            int24 lower;
            int24 upper;
            if (_layerIsToken0) {
                lower = tl[i];
                upper = tu[i];
            } else {
                // For token1-side LP: the LAYER ladder needs to be on the
                // other side of price. Negate and swap so lower < upper.
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

            lowerTicks[i] = lower;
            upperTicks[i] = upper;
            layerSeeded[i] = amount;
            liquidityPerTier[i] = L;
        }
    }

    // ─── trading ─────────────────────────────────────────────────────────

    function _buyLayer(uint256 wethIn) internal {
        // zeroForOne is "swap currency0 for currency1". We want to spend WETH
        // and receive LAYER. So zeroForOne = (WETH is currency0).
        bool zeroForOne = !_layerIsToken0;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(wethIn), // exact-input
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(
            poolKey,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ─── reporting helpers ───────────────────────────────────────────────

    function _logSeedTable() internal view {
        console2.log("");
        console2.log("Per-tier seed:");
        for (uint256 i = 0; i < 4; i++) {
            string memory line = string.concat(
                "P",
                _u(i + 1),
                "  ticks=[",
                _i(lowerTicks[i]),
                ", ",
                _i(upperTicks[i]),
                ")  LAYER=",
                _u(layerSeeded[i] / 1e18),
                "  L=",
                _u(uint256(liquidityPerTier[i]))
            );
            console2.log(line);
        }
    }

    function _tierAt(int24 currentTick) internal view returns (uint256) {
        // Walk through the 4 tiers in launch order. A tick "in" a tier means
        // remaining LAYER lives there. As price rises, tiers get exhausted in
        // order; current tier = lowest tier whose upper bound exceeds current tick.
        if (_layerIsToken0) {
            for (uint256 i = 0; i < 4; i++) {
                if (currentTick < upperTicks[i]) return i + 1;
            }
            return 5; // past P4 (all consumed)
        } else {
            // For token1-side, ladder runs in opposite direction.
            for (uint256 i = 0; i < 4; i++) {
                if (currentTick > lowerTicks[i]) return i + 1;
            }
            return 5;
        }
    }

    function _tierName(uint256 t) internal pure returns (string memory) {
        if (t == 1) return "P1 (launch zone)";
        if (t == 2) return "P2 (main growth)";
        if (t == 3) return "P3 (maturity)";
        if (t == 4) return "P4 (moon tail)";
        return "PAST P4 (LP exhausted)";
    }

    /// @dev "LAYER per ETH" at a given tick, scaled to integer units.
    ///      Uses the inverse of price = 1.0001^tick when LAYER is token0,
    ///      and the direct ratio when LAYER is token1. Very approximate (we
    ///      lose precision in the 96-bit sqrt), but good enough to trace
    ///      orders of magnitude through the band progression.
    /// @dev Approximate LAYER-per-ETH at a given tick. Pre-shifts sqrtP by 64
    ///      bits before squaring so the intermediate fits in uint256 even when
    ///      sqrtP is near MAX_SQRT_PRICE. Some precision lost; fine for logs.
    ///      Returns 0 if computation would overflow (LP fully exhausted).
    function _laYerPerEthAtTick(int24 tick) internal view returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 q = uint256(sqrtP) >> 64; // up to ~2^96
        uint256 q2 = q * q; // up to ~2^192 — fits
        if (q2 == 0) return 0;
        // q2 = sqrtP^2 / 2^128 (after the >>64). price = sqrtP^2 / 2^192.
        // So price = q2 / 2^64.
        // LAYER/ETH:
        //   LAYER=token0:   inverse * 1e18 = 1e18 * 2^64 / q2
        //   LAYER=token1:   price * 1e18  = q2 * 1e18 / 2^64
        if (_layerIsToken0) {
            return (uint256(1e18) << 64) / q2;
        } else {
            return (q2 * 1e18) >> 64;
        }
    }

    /// @dev int24 → string for console2. Forge's console2 already handles ints,
    ///      but the `%s` formatter chokes on negatives in some versions.
    function _i(int256 x) internal pure returns (string memory) {
        if (x < 0) return string.concat("-", _u(uint256(-x)));
        return _u(uint256(x));
    }

    function _u(uint256 x) internal pure returns (string memory) {
        return vm.toString(x);
    }
}
