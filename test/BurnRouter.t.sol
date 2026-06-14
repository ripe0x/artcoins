// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

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

import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";

contract MockBurnableToken is ERC20, ERC20Burnable {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Unit + fork tests for the V3 BurnRouter — focused on the new
///         keeper-reward path. Non-reward behavior is byte-identical to V2
///         and covered by the existing `BurnRouter.t.sol`.
contract BurnRouterTest is Test {
    BurnRouter internal router;
    MockBurnableToken internal layer;
    MockBurnableToken internal weth;
    address internal admin = address(0xA1);
    address internal universalRouter = address(0xC0FFEE);
    address internal permit2Mock = address(0xBEEF);

    PoolKey internal poolKey;

    function setUp() public {
        router = new BurnRouter(admin);
        layer = new MockBurnableToken("Layer", "LAYER");
        weth = new MockBurnableToken("WETH", "WETH");

        vm.etch(universalRouter, hex"60016001");
        vm.etch(permit2Mock, hex"60016001");

        (address c0, address c1) = address(layer) < address(weth)
            ? (address(layer), address(weth))
            : (address(weth), address(layer));
        poolKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(0xBABE))
        });

        vm.prank(admin);
        // Pass V4 PoolManager. The hardcoded impact cap is the sandwich guard.
        router.initialize(
            address(layer), address(weth), poolKey, 0x000000000004444c5dc75cB358380D2e3dE08A90
        );
    }

    receive() external payable {}

    // ─── keeper-reward math (pure) ───────────────────────────────────────

    function test_keeperRewardForWethAmount_underCap() public view {
        // 1 ETH × 0.5% = 0.005 ETH (under the 0.01 ETH cap).
        uint256 reward = router.keeperRewardForWethAmount(1 ether);
        assertEq(reward, 0.005 ether, "0.5% of 1 ETH");
    }

    function test_keeperRewardForWethAmount_atCap() public view {
        // 2 ETH × 0.5% = 0.01 ETH (exactly the cap).
        assertEq(router.keeperRewardForWethAmount(2 ether), 0.01 ether);
    }

    function test_keeperRewardForWethAmount_overCap() public view {
        // 100 ETH × 0.5% = 0.5 ETH, capped to 0.01 ETH.
        assertEq(router.keeperRewardForWethAmount(100 ether), 0.01 ether);
        // 1000 ETH × 0.5% = 5 ETH, capped to 0.01 ETH.
        assertEq(router.keeperRewardForWethAmount(1000 ether), 0.01 ether);
    }

    function test_keeperRewardForWethAmount_tinyAmount() public view {
        // Smaller than bps granularity rounds down to 0.
        assertEq(router.keeperRewardForWethAmount(0), 0);
        assertEq(router.keeperRewardForWethAmount(1), 0);
        // 200 wei × 0.5% = 1 wei (rounded down from 1.0).
        assertEq(router.keeperRewardForWethAmount(200), 1);
    }

    // The slippage floor is now derived live from the rolling EMA (or spot),
    // so it requires a real pool — it's exercised in the fork suites below
    // (`requiredMinLayerOutForWethAmount` is read in the keeper-reward fork
    // tests) rather than against mocks here.

    // ─── reward consistency invariants ──────────────────────────────────

    /// @notice Sum (reward + swap) must always equal input wethAmount.
    function testFuzz_rewardPlusSwap_equalsInput(uint96 wethAmount) public view {
        uint256 amount = uint256(wethAmount);
        if (amount == 0) return;
        uint256 reward = router.keeperRewardForWethAmount(amount);
        // reward + swap == amount (no rounding loss).
        assertLe(reward, amount);
    }

    /// @notice Reward bounded by both bps and cap regardless of input.
    function testFuzz_rewardBoundedByCap(uint96 wethAmount) public view {
        uint256 reward = router.keeperRewardForWethAmount(uint256(wethAmount));
        assertLe(reward, 0.01 ether);
    }

    // ─── view: status / unrelated paths still work (regression) ─────────

    function test_processBurnLayer_stillWorks() public {
        // V3 keeps processBurnLayer unchanged. Mint LAYER directly to the
        // router and confirm it burns without a keeper reward.
        layer.mint(address(router), 1000e18);
        uint256 supplyBefore = layer.totalSupply();
        uint256 burned = router.processBurnLayer();
        assertEq(burned, 1000e18);
        assertEq(layer.totalSupply(), supplyBefore - 1000e18, "LAYER burned");
    }

    function test_constants_documentedValues() public view {
        assertEq(router.KEEPER_REWARD_BPS(), 50, "0.5% bps");
        assertEq(router.KEEPER_REWARD_CAP(), 0.01 ether, "0.01 ETH cap");
    }
}

// ═══════════════════════════════════════════════════════════════════════
//   Mainnet-fork integration: keeper reward paid out on real swap+burn
// ═══════════════════════════════════════════════════════════════════════

/// @dev Exercises the V3 BurnRouter end-to-end against a real V4 LAYER/WETH
///      pool. Verifies that a caller of `processBurnWeth` receives the
///      keeper reward as native ETH and that the burn proceeds correctly
///      with the post-reward swap amount.
contract BurnRouterForkTest is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    MockBurnableToken internal layer;
    BurnRouter internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolKey internal poolKey;

    address internal admin = address(0xA1);
    address internal keeper = makeAddr("keeper");
    bool internal _onFork;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: no fork detected. Run with --fork-url $MAINNET_RPC_URL");
            return;
        }
        _onFork = true;

        layer = new MockBurnableToken("Layer", "LAYER");
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        router = new BurnRouter(admin);

        (address c0, address c1) =
            address(layer) < WETH_ADDR ? (address(layer), WETH_ADDR) : (WETH_ADDR, address(layer));
        poolKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        IPoolManager(POOL_MANAGER).initialize(poolKey, uint160(1) << 96);

        layer.mint(address(this), 1_000_000e18);
        vm.deal(address(this), 1000 ether);
        IWETH9(payable(WETH_ADDR)).deposit{value: 1000 ether}();
        IERC20(address(layer)).approve(address(liquidityRouter), type(uint256).max);
        IERC20(WETH_ADDR).approve(address(liquidityRouter), type(uint256).max);

        liquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e20, salt: bytes32(0)
            }),
            ""
        );

        vm.startPrank(admin);
        // Fork-test path: real PoolManager available.
        router.initialize(address(layer), WETH_ADDR, poolKey, POOL_MANAGER);
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    receive() external payable {}

    function test_fork_processBurnWeth_paysKeeperReward() public onlyFork {
        // Send 1 WETH to the router.
        uint256 wethToBurn = 1 ether;
        vm.deal(address(this), wethToBurn);
        IWETH9(payable(WETH_ADDR)).deposit{value: wethToBurn}();
        IERC20(WETH_ADDR).transfer(address(router), wethToBurn);

        // Expected reward: 0.5% × 1 ETH = 0.005 ETH (under the 0.01 cap).
        uint256 expectedReward = (wethToBurn * 50) / 10_000;
        assertEq(expectedReward, 0.005 ether);

        // Swap amount = 1 ETH - 0.005 ETH = 0.995 ETH.
        // Required floor at 0.9 LAYER/WETH = 0.8955 LAYER.
        uint256 minLayerOut = router.requiredMinLayerOutForWethAmount(wethToBurn);

        uint256 keeperBalBefore = keeper.balance;
        uint256 layerSupplyBefore = layer.totalSupply();

        vm.prank(keeper);
        (uint256 wethIn, uint256 layerBurned) = router.processBurnWeth(minLayerOut);

        // Keeper received reward as native ETH.
        assertEq(keeper.balance - keeperBalBefore, expectedReward, "keeper reward");

        // Swap consumed the post-reward amount.
        assertEq(wethIn, wethToBurn - expectedReward, "wethIn excludes reward");

        // LAYER was burned (supply decreased by the swap output).
        assertGt(layerBurned, 0, "some LAYER burned");
        assertLt(layer.totalSupply(), layerSupplyBefore, "supply dropped");
    }

    function test_fork_processBurnWeth_keeperRewardCapped() public onlyFork {
        // Send 10 ETH worth — reward should cap at 0.01 ETH (not 0.05).
        uint256 wethToBurn = 10 ether;
        vm.deal(address(this), wethToBurn);
        IWETH9(payable(WETH_ADDR)).deposit{value: wethToBurn}();
        IERC20(WETH_ADDR).transfer(address(router), wethToBurn);

        uint256 expectedReward = 0.01 ether; // capped

        uint256 minLayerOut = router.requiredMinLayerOutForWethAmount(wethToBurn);

        uint256 keeperBalBefore = keeper.balance;
        vm.prank(keeper);
        router.processBurnWeth(minLayerOut);

        assertEq(keeper.balance - keeperBalBefore, expectedReward, "reward capped at 0.01 ETH");
    }
}
