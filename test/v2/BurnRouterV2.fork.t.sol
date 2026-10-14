// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./harness/ForkBase.sol";
import {P1Rejector, P1Stray} from "./p1/P1Base.sol";

import {Addresses} from "../../script/Addresses.sol";
import {Constants} from "../../src/Constants.sol";
import {IArtCoinsHookStaticFee} from "../../src/hooks/interfaces/IArtCoinsHookStaticFee.sol";
import {IArtCoinsLpLocker} from "../../src/interfaces/IArtCoinsLpLocker.sol";
import {IBurnRouterV2} from "../../src/v2/interfaces/IBurnRouterV2.sol";
import {BurnRouterV2} from "../../src/v2/protocol-fee/BurnRouterV2.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Calls `processBurn` repeatedly inside one transaction.
contract BurnLooper {
    function loop(BurnRouterV2 r, uint256 n) external returns (uint256 successes) {
        for (uint256 i; i < n; ++i) {
            try r.processBurn(0) {
                ++successes;
            } catch {}
        }
    }

    receive() external payable {}
}

/// @title  BurnRouterV2ForkTest
/// @notice The LAYER burn router against the live LAYER/WETH pool (legacy
///         static fee hook) at the pinned block.
/// Run: MAINNET_RPC_URL=... FOUNDRY_PROFILE=ci forge test --match-path test/v2/BurnRouterV2.fork.t.sol -vv
contract BurnRouterV2ForkTest is ForkBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant LAYER = Addresses.COIN_LAYER;
    IPoolManager internal pm = IPoolManager(POOL_MANAGER);

    BurnRouterV2 internal router;
    PoolKey internal key;
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        if (!forkMainnet()) return;
        key = IArtCoinsLpLocker(Addresses.LEGACY_LOCKER).tokenRewards(LAYER).poolKey;
        router = new BurnRouterV2(address(this), POOL_MANAGER, WETH, LAYER, key);
        vm.label(address(router), "layerBurnRouter");
        vm.label(LAYER, "LAYER");
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(router).call{value: amount}("");
        assertTrue(ok);
    }

    function _spot() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = pm.getSlot0(key.toId());
    }

    /// @dev Price ratio new/old in bps from two sqrt prices.
    function _priceMoveBps(uint160 a, uint160 b) internal pure returns (uint256) {
        (uint256 hi, uint256 lo) = a > b ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        uint256 r = (hi * 1e18) / lo;
        return ((r * r) / 1e18 - 1e18) * 10_000 / 1e18;
    }

    // ── binding ──────────────────────────────────────────────────────────

    function test_burnV2_binding_liveLayerPool() public onlyFork {
        assertEq(router.coin(), LAYER);
        assertEq(router.weth(), WETH);
        assertEq(Currency.unwrap(key.currency0), LAYER, "LAYER is currency0 live");
        assertFalse(router.wethIsCurrency0());
        assertEq(keccak256(abi.encode(router.poolKey())), keccak256(abi.encode(key)));
        assertEq(router.maxImpactBps(), Constants.PRICE_IMPACT_DEFAULT);
        assertEq(router.SPOT_FLOOR_BPS(), Constants.BURN_SPOT_FLOOR_BPS);
        assertEq(router.constantsHash(), Constants.hash());
        // the floor reads the hook's buy side fee (1% live)
        uint24 buyFee = IArtCoinsHookStaticFee(address(key.hooks)).artCoinFee(key.toId());
        assertEq(router.poolBuyFeePips(), buyFee);
        assertEq(buyFee, 10_000);
    }

    function test_burnV2_constructor_validates() public onlyFork {
        PoolKey memory bad = key;
        bad.currency0 = Currency.wrap(address(0xBEEF));
        vm.expectRevert(IBurnRouterV2.InvalidPoolKey.selector);
        new BurnRouterV2(address(this), POOL_MANAGER, WETH, LAYER, bad);

        bad = key;
        bad.tickSpacing = 60; // a pool that does not exist
        vm.expectRevert(IBurnRouterV2.InvalidPoolKey.selector);
        new BurnRouterV2(address(this), POOL_MANAGER, WETH, LAYER, bad);

        vm.expectRevert(IBurnRouterV2.InvalidPoolKey.selector);
        new BurnRouterV2(address(this), POOL_MANAGER, WETH, COIN_111, key);

        vm.expectRevert(IBurnRouterV2.ZeroAddress.selector);
        new BurnRouterV2(address(this), POOL_MANAGER, address(0), LAYER, key);
        vm.expectRevert(IBurnRouterV2.ZeroAddress.selector);
        new BurnRouterV2(address(this), POOL_MANAGER, WETH, address(0), key);
    }

    // ── burn ─────────────────────────────────────────────────────────────

    function test_burnV2_ethIn_layerBurned_rewardPaid() public onlyFork {
        _fund(0.05 ether);
        uint256 supply0 = IERC20(LAYER).totalSupply();
        uint256 budget = router.swapBudget();
        assertEq(budget, 0.05 ether - router.rewardFor(0.05 ether));
        uint256 floor = router.floorFor(budget);
        assertGt(floor, 0);

        vm.prank(keeper);
        (uint256 wethIn, uint256 burned) = router.processBurn(floor);

        assertEq(wethIn, budget, "small budget fills fully");
        assertGe(burned, floor, "floor enforced on the fill");
        assertEq(IERC20(LAYER).totalSupply(), supply0 - burned, "LAYER supply burned");
        assertEq(IERC20(LAYER).balanceOf(address(router)), 0, "no LAYER left");
        assertEq(keeper.balance, router.rewardFor(wethIn), "reward on consumed, in eth");
        assertEq(address(router).balance, 0, "eth wrapped");
        // the reserve is sized on the balance, the reward on the fill; the
        // difference is weth dust that folds into the next burn
        assertEq(
            IERC20(WETH).balanceOf(address(router)),
            router.rewardFor(0.05 ether) - router.rewardFor(wethIn),
            "budget spent, reward paid, reserve dust stays"
        );
        assertEq(router.lastBurnBlock(), block.number);
    }

    /// @notice Weth sent directly (the v1 routers held weth) is part of the budget.
    function test_burnV2_wethFunded_burns() public onlyFork {
        dealWeth(address(router), 0.02 ether);
        _fund(0.01 ether);
        assertEq(router.swapBudget(), 0.03 ether - router.rewardFor(0.03 ether));
        uint256 supply0 = IERC20(LAYER).totalSupply();
        (uint256 wethIn, uint256 burned) = router.processBurn(0);
        assertEq(
            wethIn,
            router.rewardFor(0.03 ether) > 0
                ? 0.03 ether - router.rewardFor(0.03 ether)
                : 0.03 ether
        );
        assertLt(IERC20(LAYER).totalSupply(), supply0);
        assertGt(burned, 0);
    }

    /// @notice A balance far above the pool's depth fills partially at the
    ///         impact limit and the rest waits for later blocks.
    function test_burnV2_bigBalance_partialFill_impactCapped() public onlyFork {
        _fund(5 ether);
        uint160 pre = _spot();
        vm.prank(keeper);
        (uint256 wethIn,) = router.processBurn(0);
        assertLt(wethIn, 5 ether, "partial fill");
        assertLe(_priceMoveBps(pre, _spot()), router.maxImpactBps(), "impact capped");
        assertEq(keeper.balance, router.rewardFor(wethIn), "reward sized on consumed");
        assertGt(IERC20(WETH).balanceOf(address(router)), 4 ether, "rest waits as weth");

        // the next block burns again
        vm.roll(block.number + 1);
        uint256 supply0 = IERC20(LAYER).totalSupply();
        router.processBurn(0);
        assertLt(IERC20(LAYER).totalSupply(), supply0);
    }

    function test_burnV2_onePerBlock_loopGetsOneBurn() public onlyFork {
        _fund(5 ether);
        BurnLooper looper = new BurnLooper();
        uint160 pre = _spot();
        uint256 successes = looper.loop(router, 10);
        assertEq(successes, 1, "one burn per block");
        assertLe(_priceMoveBps(pre, _spot()), router.maxImpactBps(), "impact capped per tx");

        vm.expectRevert(IBurnRouterV2.AlreadyBurnedThisBlock.selector);
        router.processBurn(0);
        vm.roll(block.number + 1);
        router.processBurn(0);
    }

    function test_burnV2_heldLayer_isBurnedToo() public onlyFork {
        deal(LAYER, address(router), 7e18);
        _fund(0.01 ether);
        uint256 supply0 = IERC20(LAYER).totalSupply();
        (, uint256 burned) = router.processBurn(0);
        assertGt(burned, 7e18);
        assertEq(IERC20(LAYER).totalSupply(), supply0 - burned);
        assertEq(IERC20(LAYER).balanceOf(address(router)), 0);
    }

    function test_burnV2_nothingToBurn_reverts() public onlyFork {
        vm.expectRevert(IBurnRouterV2.NothingToBurn.selector);
        router.processBurn(0);
        assertEq(router.lastBurnBlock(), 0, "a reverted call spends nothing");
        _fund(0.01 ether);
        router.processBurn(0);
        assertEq(router.lastBurnBlock(), block.number);
    }

    function test_burnV2_minOut_honoured() public onlyFork {
        _fund(0.01 ether);
        vm.expectPartialRevert(IBurnRouterV2.InsufficientOutput.selector);
        router.processBurn(type(uint128).max);
    }

    /// @notice The floor is the live spot output net of the live buy fee times
    ///         SPOT_FLOOR_BPS; a burn at the impact limit clears it.
    function test_burnV2_floor_liveSpotAndFee() public onlyFork {
        uint160 p = _spot();
        uint256 wethIn = 0.1 ether;
        // LAYER is currency0: price is weth per LAYER, out = weth / price
        uint256 raw = FullMath.mulDiv(FullMath.mulDiv(wethIn, 1 << 96, p), 1 << 96, p);
        uint256 netPpm = 1e6 - router.poolBuyFeePips();
        assertEq(
            router.floorFor(wethIn),
            FullMath.mulDiv(raw, netPpm * Constants.BURN_SPOT_FLOOR_BPS, 1e6 * 1e4)
        );
        assertEq(router.floorFor(0), 0);

        router.setMaxImpactBps(Constants.PRICE_IMPACT_MAX);
        _fund(5 ether);
        (uint256 consumed, uint256 burned) = router.processBurn(0);
        assertGe(
            burned, router.floorFor(consumed) * 99 / 100, "fill at max impact clears the floor"
        );
    }

    function test_burnV2_rejectingKeeper_rewardStays() public onlyFork {
        _fund(0.05 ether);
        address rej = address(new P1Rejector());
        vm.prank(rej);
        vm.expectEmit(true, false, false, false, address(router));
        emit IBurnRouterV2.KeeperRewardFailed(rej, 0);
        (uint256 wethIn,) = router.processBurn(0);
        uint256 reward = router.rewardFor(wethIn);
        assertEq(address(router).balance, reward, "unwrapped reward stays as eth");
        // and folds into the next burn together with the reserve dust
        vm.roll(block.number + 1);
        _fund(0.01 ether);
        uint256 total = address(router).balance + IERC20(WETH).balanceOf(address(router));
        assertGe(total, reward + 0.01 ether);
        assertEq(router.swapBudget(), total - router.rewardFor(total));
        (uint256 wethIn2,) = router.processBurn(0);
        assertEq(wethIn2, total - router.rewardFor(total), "everything held is the next budget");
    }

    // ── owner ────────────────────────────────────────────────────────────

    function test_burnV2_impact_bounds() public onlyFork {
        uint16 lo = Constants.PRICE_IMPACT_MIN;
        uint16 hi = Constants.PRICE_IMPACT_MAX;
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, lo - 1, lo, hi));
        router.setMaxImpactBps(lo - 1);
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, hi + 1, lo, hi));
        router.setMaxImpactBps(hi + 1);
        vm.expectEmit(false, false, false, true, address(router));
        emit IBurnRouterV2.MaxImpactBpsSet(Constants.PRICE_IMPACT_DEFAULT, lo);
        router.setMaxImpactBps(lo);
        router.setMaxImpactBps(hi);
        assertEq(router.maxImpactBps(), hi);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        router.setMaxImpactBps(100);
    }

    function test_burnV2_rescue_neverEthWethOrLayer() public onlyFork {
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.CannotRescue.selector, address(0)));
        router.rescue(address(0), address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.CannotRescue.selector, WETH));
        router.rescue(WETH, address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.CannotRescue.selector, LAYER));
        router.rescue(LAYER, address(this), 1);
        vm.expectRevert(IBurnRouterV2.ZeroAddress.selector);
        router.rescue(COIN_111, address(0), 1);

        P1Stray stray = new P1Stray();
        stray.transfer(address(router), 3e18);
        router.rescue(address(stray), keeper, 3e18);
        assertEq(stray.balanceOf(keeper), 3e18);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        router.rescue(address(stray), attacker, 0);
    }

    function test_burnV2_unlockCallback_onlyPoolManager() public onlyFork {
        vm.expectRevert(IBurnRouterV2.NotPoolManager.selector);
        router.unlockCallback(abi.encode(uint256(1), uint160(1)));
    }

    function test_burnV2_ownable2Step() public onlyFork {
        router.transferOwnership(attacker);
        assertEq(router.owner(), address(this), "pending only");
        vm.prank(attacker);
        router.acceptOwnership();
        assertEq(router.owner(), attacker);
    }
}
