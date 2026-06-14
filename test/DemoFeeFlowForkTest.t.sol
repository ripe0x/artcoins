// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";
import {LiquiditySupportReceiver} from "../src/protocol-fee/LiquiditySupportReceiver.sol";
import {ProtocolFeeController} from "../src/protocol-fee/ProtocolFeeController.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

contract MintableBurnableToken is ERC20, ERC20Burnable {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title DemoFeeFlowForkTest
/// @notice End-to-end demonstration on a real mainnet fork:
///           1. Deploys LAYER + ART (a 2nd artcoin) as fresh tokens
///           2. Stands up the artcoins fee-routing stack
///           3. Creates real V4 LAYER/WETH and ART/WETH pools, seeds liquidity
///           4. Issues real swaps on each pool
///           5. Claims accrued LP fees from the seeded positions
///           6. Distributes the fees per each coin's locker reward shape
///           7. Calls ProtocolFeeController.processFees → BurnRouter.process*
///           8. Prints a per-trade and cumulative report — including the
///              actual LAYER burned (project-side direct + protocol-side
///              swap-and-burn from BOTH coin pools' WETH fees)
///
/// Run:
///   forge test --match-contract DemoFeeFlowForkTest \
///     --fork-url https://ethereum-rpc.publicnode.com -vv
///
/// Tweak the trade list in `_layerTrades()` / `_artTrades()` to explore
/// different scenarios.
contract DemoFeeFlowForkTest is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Each coin's locker reward shape (project-side bps + protocol slot).
    // Project bps must sum to 8000; protocol slot is fixed at 2000.
    struct RewardShape {
        uint16 artistBps; // → artist treasury
        uint16 projectBurnBps; // → BurnRouter (project-side direct)
        uint16 liqSupportBps; // → LiquiditySupportReceiver
        // (protocol slot of 2000 bps is implicit; goes to controller)
    }

    struct Trade {
        bool buyCoin; // true = WETH → coin (fee in WETH); false = coin → WETH (fee in coin)
        uint256 amountIn;
    }

    MintableBurnableToken internal layer;
    MintableBurnableToken internal art;

    ProtocolFeeController internal controller;
    BurnRouter internal router;
    LiquiditySupportReceiver internal liqSupport;

    PoolModifyLiquidityTest internal liqRouter;
    PoolSwapTest internal swapRouter;

    address internal feeAdmin = address(0xA1);
    address internal artcoinsTreasury = address(0xB1);
    address internal layerArtist = address(0xC1);
    address internal artArtist = address(0xC2);
    address internal trader = address(0xD1);

    PoolKey internal layerKey;
    PoolKey internal artKey;

    bool internal _onFork;

    // Per-coin book-keeping the demo accumulates
    struct Book {
        // Total LP fee claimed from the pool (across both currencies)
        uint256 feeInWeth;
        uint256 feeInCoin;
        // Per-recipient distributed amounts (filled by _distribute)
        uint256 artistGotWeth;
        uint256 artistGotCoin;
        uint256 projectBurnGotWeth;
        uint256 projectBurnGotCoin;
        uint256 controllerGotWeth;
        uint256 controllerGotCoin;
        uint256 liqSupportGotWeth;
        uint256 liqSupportGotCoin;
    }
    Book internal layerBook;
    Book internal artBook;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: no fork detected. Run with --fork-url $MAINNET_RPC_URL");
            return;
        }
        _onFork = true;

        // 1. Tokens
        layer = new MintableBurnableToken("Liquidity Layer", "LAYER");
        art = new MintableBurnableToken("Art Coin", "ART");

        // 2. V4 helpers
        liqRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        // 3. Fee-routing stack
        router = new BurnRouter(feeAdmin);
        liqSupport = new LiquiditySupportReceiver(feeAdmin, address(layer), WETH);
        controller = new ProtocolFeeController(feeAdmin, artcoinsTreasury, address(router), 6000);

        // 4. Pool keys (no hook, 1% fee = LAYER production, tickSpacing 60, sorted currencies)
        layerKey = _buildKey(address(layer), WETH);
        artKey = _buildKey(address(art), WETH);

        // 5. Initialize both pools at price = 1 (sqrtPrice = 2^96)
        IPoolManager(POOL_MANAGER).initialize(layerKey, uint160(1) << 96);
        IPoolManager(POOL_MANAGER).initialize(artKey, uint160(1) << 96);

        // 6. Seed liquidity in each pool. Sized so 200 ETH swaps move price
        //    by a few percent. liquidityDelta = 5e23 → ~500k tokens per side
        //    at price=1, range -60k..+60k.
        layer.mint(address(this), 2_000_000e18);
        art.mint(address(this), 2_000_000e18);
        vm.deal(address(this), 2_000_000 ether);
        IWETH9(payable(WETH)).deposit{value: 2_000_000 ether}();
        IERC20(address(layer)).approve(address(liqRouter), type(uint256).max);
        IERC20(address(art)).approve(address(liqRouter), type(uint256).max);
        IERC20(WETH).approve(address(liqRouter), type(uint256).max);

        liqRouter.modifyLiquidity(
            layerKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 5e23, salt: bytes32(0)
            }),
            ""
        );
        liqRouter.modifyLiquidity(
            artKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 5e23, salt: bytes32(0)
            }),
            ""
        );

        // 7. Initialize BurnRouter against the LAYER/WETH pool key. Leave
        //    minProcessThreshold at its production default (0.01 ETH) so the
        //    demo exercises the real swap-trigger condition.
        vm.startPrank(feeAdmin);
        router.initialize(address(layer), WETH, layerKey, POOL_MANAGER);
        vm.stopPrank();

        // 8. Fund trader and pre-approve swap router. Trader needs enough of
        //    each currency to cover the trade list's cumulative `amountIn`.
        layer.mint(trader, 1_000_000e18);
        art.mint(trader, 1_000_000e18);
        vm.deal(trader, 5000 ether);
        vm.startPrank(trader);
        IWETH9(payable(WETH)).deposit{value: 3000 ether}();
        IERC20(address(layer)).approve(address(swapRouter), type(uint256).max);
        IERC20(address(art)).approve(address(swapRouter), type(uint256).max);
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    receive() external payable {}

    function _buildKey(address coin, address weth) internal pure returns (PoolKey memory) {
        (address c0, address c1) = coin < weth ? (coin, weth) : (weth, coin);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            // 1% static fee — matches LAYER's production trading fee.
            // The real LAYER pool uses dynamic fees (the artcoins hook
            // sets 1% for normal trading and ramps up during anti-sniper),
            // but the demo runs without the hook for setup simplicity.
            // The static 1% gives the same fee economics for normal trading.
            fee: 10_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    // ─── per-coin reward shapes ──────────────────────────────────────────

    function _layerShape() internal pure returns (RewardShape memory) {
        // LAYER mainnet shape: artist 3800, projectBurn 4200, liqSupport 0.
        // Project total = 8000; protocol slot = 2000 (controller); sum 10_000.
        return RewardShape({artistBps: 3800, projectBurnBps: 4200, liqSupportBps: 0});
    }

    function _artShape() internal pure returns (RewardShape memory) {
        // ART artist's chosen split (just to show artcoins can differ from LAYER):
        //   5000 → themselves, 3000 → project-side burn (in ART, awaiting cross-
        //   artcoin conversion), 0 → liquidity support (disabled at protocol level).
        // Project total = 8000; protocol slot = 2000; sum 10_000.
        return RewardShape({artistBps: 5000, projectBurnBps: 3000, liqSupportBps: 0});
    }

    // ─── trade lists ─────────────────────────────────────────────────────

    function _layerTrades() internal pure returns (Trade[] memory t) {
        // 12 trades, sizes 50–500 ETH and 20k–100k LAYER. Seed pool has ~500k
        // tokens per side, so a 500 ETH swap is ~0.1% of pool capital.
        // Cumulative buy volume: ~1100 ETH; cumulative sell volume: ~285k LAYER.
        t = new Trade[](12);
        t[0] = Trade({buyCoin: true, amountIn: 50 ether}); // 50 ETH buy
        t[1] = Trade({buyCoin: false, amountIn: 80_000e18}); // 80k LAYER sell
        t[2] = Trade({buyCoin: true, amountIn: 200 ether});
        t[3] = Trade({buyCoin: false, amountIn: 50_000e18});
        t[4] = Trade({buyCoin: true, amountIn: 100 ether});
        t[5] = Trade({buyCoin: false, amountIn: 30_000e18});
        t[6] = Trade({buyCoin: true, amountIn: 500 ether});
        t[7] = Trade({buyCoin: false, amountIn: 100_000e18});
        t[8] = Trade({buyCoin: true, amountIn: 150 ether});
        t[9] = Trade({buyCoin: false, amountIn: 60_000e18});
        t[10] = Trade({buyCoin: true, amountIn: 80 ether});
        t[11] = Trade({buyCoin: false, amountIn: 25_000e18});
    }

    function _artTrades() internal pure returns (Trade[] memory t) {
        // 10 trades for ART. Cumulative buy volume: ~290 ETH; sell: ~190k ART.
        t = new Trade[](10);
        t[0] = Trade({buyCoin: true, amountIn: 20 ether});
        t[1] = Trade({buyCoin: false, amountIn: 40_000e18});
        t[2] = Trade({buyCoin: true, amountIn: 80 ether});
        t[3] = Trade({buyCoin: false, amountIn: 60_000e18});
        t[4] = Trade({buyCoin: true, amountIn: 120 ether});
        t[5] = Trade({buyCoin: false, amountIn: 30_000e18});
        t[6] = Trade({buyCoin: true, amountIn: 50 ether});
        t[7] = Trade({buyCoin: false, amountIn: 50_000e18});
        t[8] = Trade({buyCoin: true, amountIn: 30 ether});
        t[9] = Trade({buyCoin: false, amountIn: 15_000e18});
    }

    // ─── the demo ────────────────────────────────────────────────────────

    function test_fork_demoFeeFlow() public {
        if (!_onFork) return;

        console2.log("\n========================================================");
        console2.log("DEMO: LAYER + ART fee distribution on real mainnet fork");
        console2.log("========================================================");
        console2.log("Initial LAYER total supply:", LAYER_MINTED_BASELINE);
        console2.log("Initial ART total supply:  ", art.totalSupply());
        console2.log("Pool fee tier: 1% (10_000 ppm) -- matches LAYER's production fee");
        console2.log("Reward shapes (bps out of 10_000):");
        console2.log("  LAYER: artist 3800, projectBurn 4200, controller 2000");
        console2.log("  ART:   artist 5000, projectBurn 3000, controller 2000");
        console2.log("");

        // Run trades on each pool
        _runTrades("LAYER", layerKey, address(layer), _layerTrades());
        _runTrades("ART  ", artKey, address(art), _artTrades());

        // Claim accrued LP fees from each pool back to ourselves
        _claimFees(layerKey, address(layer), layerBook);
        _claimFees(artKey, address(art), artBook);

        // Distribute claimed fees per each coin's reward shape
        _distribute(address(layer), layerBook, _layerShape(), layerArtist);
        _distribute(address(art), artBook, _artShape(), artArtist);

        // Process the controller's accumulated balances
        _processController();

        // Process the burn router's accumulated balances
        _processBurnRouter();

        // Final report
        _printReport();
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    /// @dev Issue swaps via PoolSwapTest. After each, log the trade.
    function _runTrades(
        string memory label,
        PoolKey memory key,
        address coin,
        Trade[] memory trades
    ) internal {
        bool coinIsCurrency0 = coin < WETH;

        console2.log("--- Trades on", label, "pool ---");
        for (uint256 i = 0; i < trades.length; i++) {
            Trade memory t = trades[i];
            // zeroForOne: which currency is being paid in.
            // buy coin = pay WETH = sell currency!=coin.
            //   if coin is currency0, then WETH is currency1 → zeroForOne = false
            //   if coin is currency1, then WETH is currency0 → zeroForOne = true
            // sell coin = pay coin.
            //   if coin is currency0 → zeroForOne = true
            //   if coin is currency1 → zeroForOne = false
            bool zeroForOne;
            if (t.buyCoin) {
                zeroForOne = !coinIsCurrency0;
            } else {
                zeroForOne = coinIsCurrency0;
            }

            int256 amtSpec = -int256(t.amountIn); // exact-input
            uint160 priceLimit =
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

            vm.prank(trader);
            BalanceDelta delta = swapRouter.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: amtSpec, sqrtPriceLimitX96: priceLimit
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            // Log the trade direction + sizes. Print in whole units (token
            // units, not wei) for readability — assumes 18-decimal tokens.
            uint256 inUnits = t.amountIn / 1e18;
            uint256 inMilli = (t.amountIn % 1e18) / 1e15;
            if (t.buyCoin) {
                console2.log("  BUY  coin: WETH in =", inUnits, "tokens");
            } else {
                console2.log("  SELL coin: coin in =", inUnits, "tokens");
            }
            inMilli; // silence unused-var warning for the fractional remainder
            delta;
        }
        console2.log("");
    }

    /// @dev Claim all accrued fees from the seeded position by calling
    ///      modifyLiquidity with delta=0. Fees come back as positive deltas
    ///      in both currencies; PoolModifyLiquidityTest takes them to msg.sender.
    function _claimFees(PoolKey memory key, address coin, Book storage book) internal {
        bool coinIsCurrency0 = coin < WETH;

        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 coinBefore = IERC20(coin).balanceOf(address(this));

        liqRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 0, salt: bytes32(0)
            }),
            ""
        );

        uint256 wethGain = IERC20(WETH).balanceOf(address(this)) - wethBefore;
        uint256 coinGain = IERC20(coin).balanceOf(address(this)) - coinBefore;

        // Fees can come back as either currency depending on swap directions.
        if (coinIsCurrency0) {
            book.feeInCoin = coinGain;
            book.feeInWeth = wethGain;
        } else {
            book.feeInCoin = coinGain;
            book.feeInWeth = wethGain;
        }
    }

    /// @dev Distribute claimed fees per the reward shape. Project-side bps
    ///      sum to 8000; the remaining 2000 goes to the controller (protocol
    ///      slot). All transfers happen from this contract (acting as the
    ///      hypothetical locker) to each recipient.
    function _distribute(
        address coin,
        Book storage book,
        RewardShape memory shape,
        address artistAddr
    ) internal {
        // Project-side: artist + project burn + liq support
        // Controller: 2000 bps (the protocol slot)
        uint16 controllerBps = 2000;

        // Apply to both fee currencies (WETH and coin)
        _send(coin, address(this), artistAddr, book.feeInCoin, shape.artistBps);
        _send(WETH, address(this), artistAddr, book.feeInWeth, shape.artistBps);
        book.artistGotCoin = book.feeInCoin * shape.artistBps / 10_000;
        book.artistGotWeth = book.feeInWeth * shape.artistBps / 10_000;

        if (shape.projectBurnBps > 0) {
            _send(coin, address(this), address(router), book.feeInCoin, shape.projectBurnBps);
            _send(WETH, address(this), address(router), book.feeInWeth, shape.projectBurnBps);
            book.projectBurnGotCoin = book.feeInCoin * shape.projectBurnBps / 10_000;
            book.projectBurnGotWeth = book.feeInWeth * shape.projectBurnBps / 10_000;
        }

        if (shape.liqSupportBps > 0) {
            _send(coin, address(this), address(liqSupport), book.feeInCoin, shape.liqSupportBps);
            _send(WETH, address(this), address(liqSupport), book.feeInWeth, shape.liqSupportBps);
            book.liqSupportGotCoin = book.feeInCoin * shape.liqSupportBps / 10_000;
            book.liqSupportGotWeth = book.feeInWeth * shape.liqSupportBps / 10_000;
        }

        _send(coin, address(this), address(controller), book.feeInCoin, controllerBps);
        _send(WETH, address(this), address(controller), book.feeInWeth, controllerBps);
        book.controllerGotCoin = book.feeInCoin * controllerBps / 10_000;
        book.controllerGotWeth = book.feeInWeth * controllerBps / 10_000;
    }

    function _send(address token, address from, address to, uint256 base, uint16 bps) internal {
        uint256 amt = base * bps / 10_000;
        if (amt == 0) return;
        if (from == address(this)) {
            IERC20(token).transfer(to, amt);
        } else {
            vm.prank(from);
            IERC20(token).transfer(to, amt);
        }
    }

    function _processController() internal {
        // Controller has WETH from both pools, plus LAYER and ART. Process
        // each token: 60% → artcoins treasury, 40% → BurnRouter.
        if (IERC20(WETH).balanceOf(address(controller)) > 0) {
            controller.processFees(WETH);
        }
        if (IERC20(address(layer)).balanceOf(address(controller)) > 0) {
            controller.processFees(address(layer));
        }
        if (IERC20(address(art)).balanceOf(address(controller)) > 0) {
            controller.processFees(address(art));
        }
    }

    uint256 internal layerBurnedDirect;
    uint256 internal layerBurnedFromSwap;
    uint256 internal wethSwapped;

    function _processBurnRouter() internal {
        // Burn the LAYER directly. The router holds:
        //   - Project-side LAYER (from LAYER trades sell-side)
        //   - Controller's 40% share of LAYER (from controller.processFees(LAYER))
        uint256 layerHeld = IERC20(address(layer)).balanceOf(address(router));
        if (layerHeld > 0) {
            layerBurnedDirect = router.processBurnLayer();
        }

        // Swap the router's WETH for LAYER and burn. WETH came from:
        //   - Project-side LAYER trades (buy-side fees)
        //   - Controller's 40% share of all WETH fees (LAYER pool + ART pool)
        uint256 wethHeld = IERC20(WETH).balanceOf(address(router));
        if (wethHeld >= router.minProcessThreshold()) {
            uint256 minLayerOut = router.requiredMinLayerOutForCurrentWethBalance();
            (wethSwapped, layerBurnedFromSwap) = router.processBurnWeth(minLayerOut);
        }

        // ART tokens accumulated in the burn router stay there permanently.
        // The router has no permissionless conversion path; only adminSweepHeldToken
        // can move them, and only to a recipient the admin chooses per-call.
    }

    /// @dev Total LAYER minted at setup (LP + trader). Used to compute the
    ///      "burned this demo" delta. Update in lockstep with the mints in
    ///      `setUp()` if those amounts change.
    uint256 internal constant LAYER_MINTED_BASELINE = 2_000_000e18 + 1_000_000e18; // LP + trader

    function _printReport() internal view {
        console2.log("\n========================================================");
        console2.log("DISTRIBUTION REPORT");
        console2.log("========================================================");

        console2.log("\n--- LP fees claimed from pools ---");
        _logBook("LAYER pool", layerBook, address(layer));
        _logBook("ART   pool", artBook, address(art));

        console2.log("\n--- Recipient balances after distribution ---");
        console2.log("LAYER artist (", layerArtist, ")");
        console2.log("  LAYER:", layer.balanceOf(layerArtist));
        console2.log("  WETH: ", IERC20(WETH).balanceOf(layerArtist));
        console2.log("ART   artist (", artArtist, ")");
        console2.log("  ART:  ", art.balanceOf(artArtist));
        console2.log("  WETH: ", IERC20(WETH).balanceOf(artArtist));

        console2.log("\nartcoins protocol treasury (", artcoinsTreasury, ")");
        console2.log("  LAYER:", layer.balanceOf(artcoinsTreasury));
        console2.log("  ART:  ", art.balanceOf(artcoinsTreasury));
        console2.log("  WETH: ", IERC20(WETH).balanceOf(artcoinsTreasury));

        console2.log("\nBurnRouter (after processing)");
        console2.log("  LAYER:  ", layer.balanceOf(address(router)));
        console2.log(
            "  ART (held; only adminSweepHeldToken can move):", art.balanceOf(address(router))
        );
        console2.log("  WETH:   ", IERC20(WETH).balanceOf(address(router)));

        console2.log("\n--- LAYER burn outcome ---");
        console2.log("Direct burn (project-side LAYER fees + controller's LAYER share):");
        console2.log("  ", layerBurnedDirect);
        console2.log("Swap-and-burn (WETH from both pools' protocol slot + LAYER pool's");
        console2.log("project burn share):");
        console2.log("  WETH swapped: ", wethSwapped);
        console2.log("  LAYER bought and burned:", layerBurnedFromSwap);
        console2.log("Total LAYER burned this demo:", layerBurnedDirect + layerBurnedFromSwap);
        console2.log("LAYER current totalSupply:  ", layer.totalSupply());

        console2.log("\n--- Cumulative across both pools ---");
        uint256 totalArtistTreasuryWeth =
            IERC20(WETH).balanceOf(layerArtist) + IERC20(WETH).balanceOf(artArtist);
        console2.log("Total WETH to all artist treasuries:     ", totalArtistTreasuryWeth);
        console2.log(
            "Total WETH to artcoins protocol treasury:", IERC20(WETH).balanceOf(artcoinsTreasury)
        );
        console2.log("Total WETH burned (swapped to LAYER):    ", wethSwapped);

        console2.log("\n--- Notes ---");
        console2.log("- Swaps were real V4 swaps on the forked mainnet PoolManager.");
        console2.log("- Pool fee accrual is real (1%/swap on the inbound currency).");
        console2.log("- LAYER burn via swap is a real Universal Router V4_SWAP back");
        console2.log("  through the same LAYER/WETH pool we seeded.");
        console2.log("- Distribution into recipient buckets simulates locker behavior;");
        console2.log("  the bps math matches what the locker would do on-chain.");
        console2.log("- ART tokens held in BurnRouter stay there. The contract has no");
        console2.log("  permissionless conversion path. Admin can move them via");
        console2.log("  adminSweepHeldToken(token, recipient, amount).");
        console2.log("- minProcessThreshold runs at production default (0.01 ETH).");
    }

    function _logBook(string memory label, Book storage b, address coin) internal view {
        console2.log(label);
        console2.log("  fee in WETH:", b.feeInWeth);
        if (coin == address(layer)) {
            console2.log("  fee in LAYER:", b.feeInCoin);
        } else {
            console2.log("  fee in ART:", b.feeInCoin);
        }
    }
}
