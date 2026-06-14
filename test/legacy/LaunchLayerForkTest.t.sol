// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {LiquiditySupportReceiver} from "../../src/protocol-fee/LiquiditySupportReceiver.sol";
import {BurnRouter} from "../../src/protocol-fee/legacy/BurnRouter.sol";
import {ProtocolFeeController} from "../../src/protocol-fee/legacy/ProtocolFeeController.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

contract MintableBurnableToken is ERC20, ERC20Burnable {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title LaunchLayerForkTest
/// @notice Mainnet-fork integration test for the LAYER fee-routing stack.
///         Skips when not running against a fork. Closes Phase A.2:
///           - Real WETH / Universal Router / Permit2 from mainnet
///           - Initializes a fresh LAYER/WETH V4 pool with seed liquidity
///           - Exercises BurnRouter.processBurnWeth end-to-end (real swap +
///             real LAYER burn)
///
/// Run:
///   forge test --match-contract LaunchLayerForkTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract LaunchLayerForkTest is Test {
    // ─── mainnet addresses ───────────────────────────────────────────────
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ─── stack ───────────────────────────────────────────────────────────
    MintableBurnableToken internal layer;
    ProtocolFeeController internal controller;
    BurnRouter internal router;
    LiquiditySupportReceiver internal liqSupport;
    PoolModifyLiquidityTest internal liquidityRouter;

    address internal admin = address(0xA1);
    address internal treasury = address(0xB1);
    address internal trader = address(0xC1);
    PoolKey internal poolKey;
    bool internal _onFork;

    function setUp() public {
        // Skip if not on a fork that has the mainnet PoolManager deployed.
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: no fork detected. Run with --fork-url $MAINNET_RPC_URL");
            return;
        }
        _onFork = true;

        // 1. Deploy fresh LAYER mock (mintable + burnable for the test).
        layer = new MintableBurnableToken("Liquidity Layer", "LAYER");

        // 2. Deploy the v4-core test helper for seeding liquidity via raw
        //    PoolManager.unlock callbacks. Avoids the PositionManager+Permit2
        //    dance for an isolated test setup.
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));

        // 3. Deploy the fee-routing stack.
        router = new BurnRouter(admin);
        liqSupport = new LiquiditySupportReceiver(admin, address(layer), WETH);
        controller = new ProtocolFeeController(admin, treasury, address(router));

        // 4. Build the canonical LAYER/WETH pool key (no hook, static 0.3% fee,
        //    tickSpacing 60). Currencies sorted ascending per V4 convention.
        (address c0, address c1) =
            address(layer) < WETH ? (address(layer), WETH) : (WETH, address(layer));
        poolKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // 5. Initialize the V4 pool at 1 LAYER = 1 WETH (sqrtPrice = 2^96).
        //    Toy price chosen so the swap math is easy to read in the report.
        IPoolManager(POOL_MANAGER).initialize(poolKey, uint160(1) << 96);

        // 6. Seed the pool with real LAYER + WETH liquidity. Mint LAYER to
        //    this contract; wrap ETH for WETH; approve the liquidity router.
        //    Liquidity sized so a 1 ETH swap moves price by <0.1% — enough to
        //    let the burn-router test assert a near-1:1 swap output without
        //    needing absurd LP capital.
        layer.mint(address(this), 1_000_000e18);
        vm.deal(address(this), 1000 ether);
        IWETH9(payable(WETH)).deposit{value: 1000 ether}();
        IERC20(address(layer)).approve(address(liquidityRouter), type(uint256).max);
        IERC20(WETH).approve(address(liquidityRouter), type(uint256).max);

        // For a position spanning both sides of price=1, ~half of L is paid
        // in each currency. liquidityDelta = 1e20 → ~95 tokens per side.
        liquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e20, salt: bytes32(0)
            }),
            ""
        );

        // 7. Initialize the BurnRouter against the real Universal Router and Permit2.
        vm.startPrank(admin);
        router.initialize(address(layer), WETH, UNIVERSAL_ROUTER, PERMIT2, poolKey);
        router.setMinLayerOutPerWeth(0.9e18);
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    /// @dev PoolModifyLiquidityTest forwards any ETH dust back to msg.sender
    ///      via a plain `.transfer()`. Accept it.
    receive() external payable {}

    // ─── tests ───────────────────────────────────────────────────────────

    function test_fork_burnRouterInitialized() public onlyFork {
        assertTrue(router.initialized());
        assertEq(router.layerToken(), address(layer));
        assertEq(router.weth(), WETH);
        assertEq(address(router.universalRouter()), UNIVERSAL_ROUTER);
        assertEq(address(router.permit2()), PERMIT2);
    }

    function test_fork_processBurnLayer_realBurn() public onlyFork {
        // Send LAYER to the router and call processBurnLayer.
        layer.mint(address(router), 1000e18);
        uint256 supplyBefore = layer.totalSupply();

        uint256 burned = router.processBurnLayer();

        assertEq(burned, 1000e18);
        assertEq(layer.totalSupply(), supplyBefore - 1000e18);
        assertEq(layer.balanceOf(address(router)), 0);
    }

    function test_fork_processBurnWeth_realSwapAndBurn() public onlyFork {
        // Send WETH to the router. processBurnWeth should swap it for LAYER on
        // the real V4 pool, then burn the LAYER it received.
        uint256 wethIn = 1 ether;
        IERC20(WETH).transfer(address(router), wethIn);
        assertEq(IERC20(WETH).balanceOf(address(router)), wethIn);

        uint256 layerSupplyBefore = layer.totalSupply();

        // Permissionless, with caller slippage at the owner-set floor.
        uint256 minLayerOut = router.requiredMinLayerOutForCurrentWethBalance();
        (uint256 wethConsumed, uint256 layerBurned) = router.processBurnWeth(minLayerOut);

        // WETH was fully spent.
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
        assertEq(wethConsumed, wethIn);

        // LAYER was burned.
        assertGt(layerBurned, 0);
        assertEq(layer.totalSupply(), layerSupplyBefore - layerBurned);
        assertEq(layer.balanceOf(address(router)), 0);

        // Sanity: at 1:1 with a 0.3% pool fee + ~95 tokens of LP per side,
        // 1 WETH in yields ~0.987 LAYER (0.3% fee + ~1% price impact).
        // Lower bound: 0.95 LAYER. Upper bound: 1.0 LAYER.
        assertGe(layerBurned, 0.95 ether);
        assertLe(layerBurned, 1 ether);

        console2.log("--- processBurnWeth result ---");
        console2.log("WETH consumed:        ", wethConsumed);
        console2.log("LAYER burned (wei):   ", layerBurned);
        console2.log("LAYER supply before:  ", layerSupplyBefore);
        console2.log("LAYER supply after:   ", layer.totalSupply());
    }

    function test_fork_processBurnWeth_belowThresholdReverts() public onlyFork {
        // Default threshold is 0.01 ETH. Send 0.001 ETH and expect revert.
        IERC20(WETH).transfer(address(router), 0.001 ether);
        vm.expectRevert(
            abi.encodeWithSelector(BurnRouter.BelowMinThreshold.selector, 0.001 ether, 0.01 ether)
        );
        router.processBurnWeth(0);
    }

    function test_fork_endToEnd_controllerToBurnRouter() public onlyFork {
        // Simulate the locker's protocol slot routing: controller receives
        // LAYER and WETH from a hypothetical pool's fee accrual. Call
        // processFees(token) for each, then processBurnWeth + processBurnLayer
        // and confirm everything ended up where it should.

        // 1. Pretend 1000 LAYER + 1 WETH worth of protocol fees accrued.
        layer.mint(address(controller), 1000e18);
        IERC20(WETH).transfer(address(controller), 1 ether);

        // 2. Controller splits 60/40/0 → treasury / burnRouter / rewards.
        controller.processFees(address(layer));
        controller.processFees(WETH);

        // After processFees, the controller's balance is empty.
        assertEq(layer.balanceOf(address(controller)), 0);
        assertEq(IERC20(WETH).balanceOf(address(controller)), 0);

        // Treasury got 60%, burnRouter got 40%.
        assertEq(layer.balanceOf(treasury), 600e18);
        assertEq(layer.balanceOf(address(router)), 400e18);
        assertEq(IERC20(WETH).balanceOf(treasury), 0.6 ether);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0.4 ether);

        uint256 layerSupplyBefore = layer.totalSupply();

        // 3. Burn router processes its LAYER and WETH.
        router.processBurnLayer(); // burns 400 LAYER directly
        uint256 minLayerOut = router.requiredMinLayerOutForCurrentWethBalance();
        (, uint256 layerFromSwap) = router.processBurnWeth(minLayerOut); // swaps 0.4 WETH for LAYER, burns

        // LAYER total supply decreased by the direct burn + swap-and-burn.
        uint256 expectedBurned = 400e18 + layerFromSwap;
        assertEq(layer.totalSupply(), layerSupplyBefore - expectedBurned);

        // Router balance is empty.
        assertEq(layer.balanceOf(address(router)), 0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);

        console2.log("--- end-to-end protocol-fee burn ---");
        console2.log("Direct LAYER burned:     ", uint256(400e18));
        console2.log("LAYER from swap+burn:    ", layerFromSwap);
        console2.log("Total LAYER burned:      ", expectedBurned);
        console2.log("Treasury LAYER balance:  ", layer.balanceOf(treasury));
        console2.log("Treasury WETH balance:   ", IERC20(WETH).balanceOf(treasury));
    }
}
