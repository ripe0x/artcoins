// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {P1Base, P1Rejector, P1Stray} from "./p1/P1Base.sol";

import {Constants} from "../../src/Constants.sol";
import {IBurnRouterV2} from "../../src/v2/interfaces/IBurnRouterV2.sol";
import {BurnRouterV2} from "../../src/v2/protocol-fee/BurnRouterV2.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Calls `processBurn` repeatedly inside one transaction (LF-03).
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

/// @notice Opens a PoolManager unlock and drives the open tab burn inside it,
///         as a pool extension would.
contract OpenTabCaller is IUnlockCallback {
    IPoolManager internal immutable pm;
    BurnRouterV2 internal immutable router;
    uint256 public lastEthIn;

    constructor(IPoolManager pm_, BurnRouterV2 router_) {
        pm = pm_;
        router = router_;
    }

    function go() external {
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        (lastEthIn,) = router.processBurnOpenTab(0);
        return "";
    }

    receive() external payable {}
}

/// @title  BurnRouterV2ForkTest
/// @notice DESIGN b6, review LF-03, LF-04, LF-09, LF-12.
/// Run: /tmp/claude-0/forge.sh test --match-path test/v2/BurnRouterV2.fork.t.sol -vv
contract BurnRouterV2ForkTest is P1Base {
    BurnRouterV2 internal router;
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        _setUpChain();
        router = new BurnRouterV2(address(this), address(pm), address(escrow));
        router.initialize(address(coin), key);
        escrow.addDepositor(address(this), false);
    }

    function _fund(uint256 amount) internal {
        (bool ok,) = address(router).call{value: amount}("");
        assertTrue(ok);
    }

    // ── b6 pacing ─────────────────────────────────────────────────────────

    function test_burnV2_secondCallSameBlock_reverts() public {
        _fund(2 ether);
        router.processBurn(0);
        assertEq(router.lastBurnBlock(), block.number);

        vm.expectRevert(IBurnRouterV2.AlreadyBurnedThisBlock.selector);
        router.processBurn(0);

        vm.roll(block.number + 1);
        router.processBurn(0);
    }

    /// @notice v1 let a contract loop the per call impact clamp in one tx and
    ///         spend the whole balance at a price it moved (LF-03). v2: one burn
    ///         per block, so the loop gets one burn and the price moves at most
    ///         `maxImpactBps`.
    function test_burnV2_loopingContract_cannotExceedImpact() public {
        _fund(50 ether); // half the pool's eth side
        BurnLooper looper = new BurnLooper();
        uint160 pre = _spot();

        uint256 successes = looper.loop(router, 25);

        assertEq(successes, 1, "one burn per block");
        uint256 moved = _priceMoveBps(pre, _spot());
        assertLe(moved, router.maxImpactBps(), "impact capped for the whole tx");
        assertGt(address(router).balance, 45 ether, "most of the balance waits");
    }

    function test_burnV2_openTab_sharesPacing() public {
        _fund(2 ether);
        OpenTabCaller caller = new OpenTabCaller(pm, router);
        router.setOpenTabCaller(address(caller));
        caller.go();
        assertGt(caller.lastEthIn(), 0, "open tab burn ran");
        assertEq(address(router).balance > 0, true);

        vm.expectRevert(IBurnRouterV2.AlreadyBurnedThisBlock.selector);
        router.processBurn(0);
    }

    function test_burnV2_openTab_outsideUnlock_reverts() public {
        _fund(2 ether);
        router.setOpenTabCaller(address(this));
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        router.processBurnOpenTab(0);
    }

    // ── D31 open tab gate ────────────────────────────────────────────────

    function test_burnV2_openTab_disabledByDefault_reverts() public {
        _fund(2 ether);
        assertEq(router.openTabCaller(), address(0));
        OpenTabCaller caller = new OpenTabCaller(pm, router);
        vm.expectRevert(IBurnRouterV2.NotOpenTabCaller.selector);
        caller.go();
        vm.expectRevert(IBurnRouterV2.NotOpenTabCaller.selector);
        router.processBurnOpenTab(0);
    }

    function test_burnV2_openTab_setCaller_passes() public {
        _fund(2 ether);
        OpenTabCaller caller = new OpenTabCaller(pm, router);
        vm.expectEmit(true, true, false, false, address(router));
        emit IBurnRouterV2.OpenTabCallerSet(address(0), address(caller));
        router.setOpenTabCaller(address(caller));
        caller.go();
        assertGt(caller.lastEthIn(), 0, "gated caller burns");
    }

    function test_burnV2_openTab_otherCaller_reverts() public {
        _fund(2 ether);
        OpenTabCaller allowed = new OpenTabCaller(pm, router);
        OpenTabCaller other = new OpenTabCaller(pm, router);
        router.setOpenTabCaller(address(allowed));
        vm.expectRevert(IBurnRouterV2.NotOpenTabCaller.selector);
        other.go();
        vm.prank(attacker);
        vm.expectRevert(IBurnRouterV2.NotOpenTabCaller.selector);
        router.processBurnOpenTab(0);

        // owner only, and zero disables again
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        router.setOpenTabCaller(attacker);
        router.setOpenTabCaller(address(0));
        vm.expectRevert(IBurnRouterV2.NotOpenTabCaller.selector);
        allowed.go();
    }

    // ── D32 spot floor ───────────────────────────────────────────────────

    function _expectedFloor(uint256 ethIn, uint256 bps) internal view returns (uint256) {
        uint160 p = _spot();
        uint256 step = FullMath.mulDiv(ethIn, p, 1 << 96);
        return FullMath.mulDiv(step, p, 1 << 96) * bps / Constants.BPS;
    }

    function test_burnV2_spotFloor_bounds() public {
        assertEq(router.spotFloorBps(), Constants.BURN_SPOT_FLOOR_DEFAULT_BPS, "default 80%");
        uint256 lo = Constants.SPOT_FLOOR_MIN_BPS;
        uint256 hi = Constants.SPOT_FLOOR_MAX_BPS;
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, lo - 1, lo, hi));
        router.setSpotFloorBps(lo - 1);
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, hi + 1, lo, hi));
        router.setSpotFloorBps(hi + 1);
        vm.expectEmit(false, false, false, true, address(router));
        emit IBurnRouterV2.SpotFloorBpsSet(Constants.BURN_SPOT_FLOOR_DEFAULT_BPS, lo);
        router.setSpotFloorBps(lo);
        assertEq(router.spotFloorBps(), lo);
        router.setSpotFloorBps(hi);
        assertEq(router.spotFloorBps(), hi);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        router.setSpotFloorBps(9000);
    }

    /// @notice D50: a hookless pool has no known fees, so the floor is raw spot.
    function test_burnV2_hooklessPool_rawSpotFloor() public {
        assertEq(router.poolBaselineSkimBps(), 0);
        assertEq(router.poolLpFee(), 0);
        assertEq(
            router.floorFor(1 ether), _expectedFloor(1 ether, Constants.BURN_SPOT_FLOOR_DEFAULT_BPS)
        );
        router.syncPoolFees();
        BurnRouterV2 r = new BurnRouterV2(address(this), address(pm), address(escrow));
        vm.expectRevert(IBurnRouterV2.NotInitialized.selector);
        r.syncPoolFees();
    }

    /// @notice The floor the view reports and the burn enforces uses the stored bps.
    function test_burnV2_spotFloor_usesStoredValue() public {
        assertEq(
            router.floorFor(1 ether), _expectedFloor(1 ether, Constants.BURN_SPOT_FLOOR_DEFAULT_BPS)
        );
        router.setSpotFloorBps(Constants.SPOT_FLOOR_MAX_BPS);
        assertEq(router.floorFor(1 ether), _expectedFloor(1 ether, Constants.SPOT_FLOOR_MAX_BPS));
        router.setSpotFloorBps(Constants.SPOT_FLOOR_MIN_BPS);
        assertEq(router.floorFor(1 ether), _expectedFloor(1 ether, Constants.SPOT_FLOOR_MIN_BPS));

        // at the 95% floor a small burn (1% lp fee, tiny impact) still clears it
        router.setSpotFloorBps(Constants.SPOT_FLOOR_MAX_BPS);
        _fund(0.2 ether);
        uint256 budget = router.swapBudget();
        uint256 floor = router.floorFor(budget);
        (, uint256 burned) = router.processBurn(0);
        assertGe(burned, floor, "enforced floor is the stored one");
    }

    // ── b6 reward (LF-04) ─────────────────────────────────────────────────

    function test_burnV2_partialFill_rewardOnConsumed() public {
        _fund(50 ether);
        uint256 supplyBefore = coin.totalSupply();

        vm.prank(keeper);
        (uint256 ethIn, uint256 burned) = router.processBurn(0);

        assertLt(ethIn, 50 ether, "partial fill");
        uint256 expected = ethIn * Constants.KEEPER_REWARD_BPS / Constants.BPS;
        if (expected > Constants.KEEPER_REWARD_CAP) expected = Constants.KEEPER_REWARD_CAP;
        assertEq(keeper.balance, expected, "reward on consumed");
        assertEq(keeper.balance, router.rewardFor(ethIn));
        // v1 paid min(0.5% of the whole balance, cap) = 0.01 eth here
        assertLt(keeper.balance, Constants.KEEPER_REWARD_CAP, "not sized on the whole balance");
        assertEq(address(router).balance, 50 ether - ethIn - expected, "rest stays");
        assertEq(coin.totalSupply(), supplyBefore - burned, "burned via token burn");
        assertEq(coin.balanceOf(address(router)), 0);
    }

    function test_burnV2_rejectingKeeper_rewardStays() public {
        _fund(1 ether);
        address rej = address(new P1Rejector());
        vm.prank(rej);
        (uint256 ethIn,) = router.processBurn(0);
        assertEq(address(router).balance, 1 ether - ethIn, "reward kept");
    }

    // ── output guards ─────────────────────────────────────────────────────

    function test_burnV2_minOut_honoured() public {
        _fund(1 ether);
        vm.expectPartialRevert(IBurnRouterV2.InsufficientOutput.selector);
        router.processBurn(1e40);
    }

    function test_burnV2_floorView_matchesEnforcement() public {
        _fund(0.2 ether);
        uint256 budget = router.swapBudget();
        uint256 floor = router.floorFor(budget);
        (uint256 ethIn, uint256 burned) = router.processBurn(floor);
        assertEq(ethIn, budget, "small balance fills fully");
        assertGe(burned, floor);
    }

    function test_burnV2_heldCoin_isBurnedToo() public {
        coin.transfer(address(router), 7e18);
        _fund(1 ether);
        uint256 supplyBefore = coin.totalSupply();
        (, uint256 burned) = router.processBurn(0);
        assertGt(burned, 7e18);
        assertEq(coin.totalSupply(), supplyBefore - burned);
    }

    // ── threshold and impact bounds ──────────────────────────────────────

    function test_burnV2_threshold_bounds() public {
        _fund(0.005 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBurnRouterV2.BelowMinThreshold.selector, 0.005 ether, 0.01 ether
            )
        );
        router.processBurn(0);

        uint256 floor = Constants.BURN_THRESHOLD_FLOOR;
        vm.expectRevert(
            abi.encodeWithSelector(
                IBurnRouterV2.OutOfBounds.selector, floor - 1, floor, type(uint96).max
            )
        );
        router.setMinProcessThreshold(uint96(floor - 1));

        router.setMinProcessThreshold(uint96(floor));
        assertEq(router.minProcessThreshold(), floor);
        router.processBurn(0);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        router.setMinProcessThreshold(1 ether);
    }

    function test_burnV2_impact_bounds() public {
        assertEq(router.maxImpactBps(), Constants.PRICE_IMPACT_DEFAULT);
        uint16 lo = Constants.PRICE_IMPACT_MIN;
        uint16 hi = Constants.PRICE_IMPACT_MAX;
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, lo - 1, lo, hi));
        router.setMaxImpactBps(lo - 1);
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, hi + 1, lo, hi));
        router.setMaxImpactBps(hi + 1);
        router.setMaxImpactBps(lo);
        router.setMaxImpactBps(hi);

        _fund(80 ether);
        uint160 pre = _spot();
        router.processBurn(0);
        assertLe(_priceMoveBps(pre, _spot()), hi, "max impact respected");

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        router.setMaxImpactBps(100);
    }

    // ── init ──────────────────────────────────────────────────────────────

    function test_burnV2_initialize_onceAndValidated() public {
        vm.expectRevert(IBurnRouterV2.AlreadyInitialized.selector);
        router.initialize(address(coin), key);

        BurnRouterV2 r = new BurnRouterV2(address(this), address(pm), address(escrow));
        vm.expectRevert(IBurnRouterV2.NotInitialized.selector);
        r.processBurn(0);

        PoolKey memory bad = key;
        bad.currency1 = Currency.wrap(address(0xBEEF));
        vm.expectRevert(IBurnRouterV2.InvalidPoolKey.selector);
        r.initialize(address(coin), bad);

        bad = key;
        bad.fee = 3000; // not initialized
        vm.expectRevert(IBurnRouterV2.InvalidPoolKey.selector);
        r.initialize(address(coin), bad);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        r.initialize(address(coin), key);

        r.initialize(address(coin), key);
        assertEq(r.coin(), address(coin));
        assertEq(keccak256(abi.encode(r.poolKey())), keccak256(abi.encode(key)));
    }

    // ── refunds and rescue ───────────────────────────────────────────────

    function test_burnV2_claimRefund_pullsEscrowCredit() public {
        assertEq(router.claimRefund(), 0, "nothing to claim is not an error");
        escrow.storeFeesNative{value: 0.4 ether}(address(router));
        assertEq(router.claimRefund(), 0.4 ether);
        assertEq(address(router).balance, 0.4 ether);
        assertEq(escrow.balances(address(router), address(0)), 0);
    }

    function test_burnV2_processBurn_pullsRefundFirst() public {
        escrow.storeFeesNative{value: 0.5 ether}(address(router));
        // below threshold without the refund
        router.processBurn(0);
        assertEq(escrow.balances(address(router), address(0)), 0);
    }

    function test_burnV2_rescue_cannotTouchCoinOrEth() public {
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.CannotRescue.selector, address(coin)));
        router.rescue(address(coin), address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.CannotRescue.selector, address(0)));
        router.rescue(address(0), address(this), 1);

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

    /// @notice View accuracy: the budget counts escrow refunds the burn claims first.
    function test_burnV2_swapBudget_includesPendingRefund() public {
        assertEq(router.swapBudget(), 0, "below threshold");
        escrow.storeFeesNative{value: 0.3 ether}(address(router));
        _fund(0.2 ether);
        uint256 budget = router.swapBudget();
        assertEq(budget, 0.5 ether - router.rewardFor(0.5 ether));
        (uint256 ethIn,) = router.processBurn(router.floorFor(budget));
        assertEq(ethIn, budget, "view matches the burn");
    }

    // ── D40 per burn cap ─────────────────────────────────────────────────

    function test_burnV2_maxBurnPerCall_capsBudget_andBounds() public {
        assertEq(router.maxBurnPerCall(), 5 ether, "default");
        uint256 lo = router.MAX_BURN_PER_CALL_MIN();
        uint256 hi = router.MAX_BURN_PER_CALL_MAX();
        assertEq(lo, 0.1 ether);
        assertEq(hi, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, lo - 1, lo, hi));
        router.setMaxBurnPerCall(lo - 1);
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.OutOfBounds.selector, hi + 1, lo, hi));
        router.setMaxBurnPerCall(hi + 1);
        vm.expectEmit(false, false, false, true, address(router));
        emit IBurnRouterV2.MaxBurnPerCallSet(5 ether, lo);
        router.setMaxBurnPerCall(lo);

        _fund(1 ether);
        assertEq(router.swapBudget(), lo, "view capped");
        (uint256 ethIn,) = router.processBurn(0);
        assertEq(ethIn, lo, "burn capped, fills fully");
        assertEq(address(router).balance, 1 ether - lo - router.rewardFor(lo));

        router.setMaxBurnPerCall(hi);
        assertEq(router.maxBurnPerCall(), hi);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        router.setMaxBurnPerCall(1 ether);
    }

    function test_burnV2_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(IBurnRouterV2.NotPoolManager.selector);
        router.unlockCallback(abi.encode(uint256(1), uint160(1)));
    }
}
