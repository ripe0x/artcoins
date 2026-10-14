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
        vm.fee(0.5 gwei); // under REWARD_MAX_BASEFEE: burns pay a keeper reward
        vm.label(address(router), "layerBurnRouter");
        vm.label(LAYER, "LAYER");
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(router).call{value: amount}("");
        assertTrue(ok);
    }

    /// @dev REWARD_MAX_BPS of `bal`, the reserve the budget leaves for the reward.
    function _reserve(uint256 bal) internal view returns (uint256) {
        return bal * router.rewardMaxBps() / Constants.BPS;
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
        assertEq(router.spotFloorBps(), Constants.BURN_SPOT_FLOOR_BPS);
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
        assertEq(budget, 0.05 ether - _reserve(0.05 ether));
        uint256 floor = router.floorFor(budget);
        assertGt(floor, 0);

        vm.prank(keeper);
        (uint256 wethIn, uint256 burned) = router.processBurn(floor);

        assertEq(wethIn, budget, "small budget fills fully");
        assertGe(burned, floor, "floor enforced on the fill");
        assertEq(IERC20(LAYER).totalSupply(), supply0 - burned, "LAYER supply burned");
        assertEq(IERC20(LAYER).balanceOf(address(router)), 0, "no LAYER left");
        uint256 reward = keeper.balance;
        assertGe(reward, router.keeperTip(), "tip plus gas, in eth");
        assertLe(reward, wethIn * router.rewardMaxBps() / Constants.BPS, "under the cap");
        assertEq(address(router).balance, 0, "eth wrapped");
        // the reserve is sized on the balance, the reward on the burn; the
        // difference is weth that folds into the next burn
        assertEq(
            IERC20(WETH).balanceOf(address(router)),
            _reserve(0.05 ether) - reward,
            "budget spent, reward paid, the rest of the reserve stays"
        );
        assertEq(router.lastBurnBlock(), block.number);
    }

    /// @notice Weth sent directly (the v1 routers held weth) is part of the budget.
    function test_burnV2_wethFunded_burns() public onlyFork {
        dealWeth(address(router), 0.02 ether);
        _fund(0.01 ether);
        assertEq(router.swapBudget(), 0.03 ether - _reserve(0.03 ether));
        uint256 supply0 = IERC20(LAYER).totalSupply();
        (uint256 wethIn, uint256 burned) = router.processBurn(0);
        assertEq(wethIn, 0.03 ether - _reserve(0.03 ether));
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
        assertLe(keeper.balance, wethIn * router.rewardMaxBps() / Constants.BPS, "reward capped");
        assertGe(keeper.balance, router.keeperTip(), "reward paid");
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
        router.processBurn(0);
        uint256 reward = address(router).balance;
        assertGe(reward, router.keeperTip(), "unwrapped reward stays as eth");
        // and folds into the next burn together with the rest of the reserve
        vm.roll(block.number + 1);
        _fund(0.01 ether);
        uint256 total = address(router).balance + IERC20(WETH).balanceOf(address(router));
        assertGe(total, reward + 0.01 ether);
        assertEq(router.swapBudget(), total - _reserve(total));
        (uint256 wethIn2,) = router.processBurn(0);
        assertEq(wethIn2, total - _reserve(total), "everything held is the next budget");
    }

    // ── keeper reward ────────────────────────────────────────────────────

    function test_burnV2_rewardFor_math() public view {
        uint256 tip = router.keeperTip();
        assertEq(router.rewardFor(1 ether, 800_000, 1 gwei), tip + 800_000 * 1 gwei, "tip plus gas");
        assertEq(router.rewardFor(1 ether, 800_000, 1 gwei + 1), 0, "zero above the gate");
        assertEq(router.rewardFor(0.001 ether, 800_000, 1 gwei), 0.0001 ether, "capped at 10%");
        assertEq(router.rewardFor(1 ether, 0, 0), tip, "tip alone at zero basefee");
    }

    /// @notice Above REWARD_MAX_BASEFEE the burn runs and pays nothing.
    function test_burnV2_reward_zeroAboveBasefeeGate() public onlyFork {
        vm.fee(router.rewardMaxBaseFee() + 1);
        _fund(0.05 ether);
        vm.prank(keeper);
        vm.expectEmit(true, false, false, false, address(router));
        emit IBurnRouterV2.Burned(keeper, 0, 0, 0);
        (uint256 wethIn,) = router.processBurn(0);
        assertEq(keeper.balance, 0, "no reward above the gate");
        assertEq(wethIn, 0.05 ether - _reserve(0.05 ether), "budget unchanged");
        assertEq(IERC20(WETH).balanceOf(address(router)), _reserve(0.05 ether), "reserve kept");
    }

    /// @notice A small budget pays at most REWARD_MAX_BPS of what it burned.
    function test_burnV2_reward_cappedByConsumed() public onlyFork {
        _fund(0.002 ether);
        vm.prank(keeper);
        (uint256 wethIn,) = router.processBurn(0);
        assertEq(keeper.balance, wethIn * router.rewardMaxBps() / Constants.BPS, "cap binds");
        assertLt(keeper.balance, router.keeperTip(), "below the tip: not worth a keeper's gas");
    }

    // ── owner ────────────────────────────────────────────────────────────

    function test_burnV2_setSpotFloorBps_boundsAndEffect() public onlyFork {
        uint256 lo = Constants.SPOT_FLOOR_MIN_BPS;
        uint256 hi = Constants.SPOT_FLOOR_MAX_BPS;
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, lo - 1, lo, hi));
        router.setSpotFloorBps(uint16(lo - 1));
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, hi + 1, lo, hi));
        router.setSpotFloorBps(uint16(hi + 1));

        uint256 before = router.floorFor(1 ether);
        vm.expectEmit(false, false, false, true, address(router));
        emit IBurnRouterV2.SpotFloorBpsSet(Constants.BURN_SPOT_FLOOR_BPS, hi);
        router.setSpotFloorBps(uint16(hi));
        assertEq(router.spotFloorBps(), hi);
        assertEq(
            router.floorFor(1 ether), before * hi / Constants.BURN_SPOT_FLOOR_BPS, "floor scales"
        );

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        router.setSpotFloorBps(uint16(lo));
    }

    function test_burnV2_setRewardConfig_boundsAndEffect() public onlyFork {
        assertEq(router.keeperTip(), Constants.BURN_TIP_DEFAULT);
        assertEq(router.keeperGasOverhead(), Constants.BURN_GAS_OVERHEAD_DEFAULT);
        assertEq(router.rewardMaxBaseFee(), Constants.BURN_BASEFEE_GATE_DEFAULT);
        assertEq(router.rewardMaxBps(), Constants.BURN_REWARD_BPS_DEFAULT);

        uint256 tipMax = Constants.BURN_TIP_MAX;
        vm.expectRevert(
            abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, tipMax + 1, 0, tipMax)
        );
        router.setRewardConfig(tipMax + 1, 0, 0, 0);
        uint256 ohMax = Constants.BURN_GAS_OVERHEAD_MAX;
        vm.expectRevert(
            abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, ohMax + 1, 0, ohMax)
        );
        router.setRewardConfig(0, ohMax + 1, 0, 0);
        uint256 gateMax = Constants.BURN_BASEFEE_GATE_MAX;
        vm.expectRevert(
            abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, gateMax + 1, 0, gateMax)
        );
        router.setRewardConfig(0, 0, gateMax + 1, 0);
        uint16 bpsMax = Constants.BURN_REWARD_BPS_MAX;
        vm.expectRevert(
            abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, bpsMax + 1, 0, bpsMax)
        );
        router.setRewardConfig(0, 0, 0, bpsMax + 1);

        // a higher gate and tip: the same block now pays, and the reserve follows the cap
        vm.expectEmit(false, false, false, true, address(router));
        emit IBurnRouterV2.RewardConfigSet(0.001 ether, 100_000, 30 gwei, 2000);
        router.setRewardConfig(0.001 ether, 100_000, 30 gwei, 2000);
        assertEq(router.rewardFor(1 ether, 800_000, 20 gwei), 0.001 ether + 800_000 * 20 gwei);
        assertEq(router.rewardFor(1 ether, 800_000, 31 gwei), 0);
        _fund(1 ether);
        assertEq(router.swapBudget(), 1 ether - 0.2 ether, "reserve is the new cap");

        // all zero turns the reward off and frees the whole balance
        router.setRewardConfig(0, 0, 0, 0);
        assertEq(router.swapBudget(), 1 ether);
        vm.fee(0);
        assertEq(router.rewardFor(1 ether, 800_000, 0), 0);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        router.setRewardConfig(0, 0, 0, 0);
    }

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
