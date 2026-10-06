// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// package i1, part 3: both tax modes end to end on factory launched coins.
// VENUE: canonical buy untaxed, a hookless side v4 pool buy taxed to the sink,
// a derived v3 venue listed and taxed, third party lp on the canonical pool
// closed after arming (D46). HARD: canonical buy and sell pass, side pool
// take and settle revert, listed venue transfer reverts, locker collect, fee
// swapper convert and burn router burn pass.

import {IntegrationV2Base} from "./IntegrationV2Base.sol";
import {I1EmptyTreasury, I1V3Actor, II1V3Pool} from "./mocks/I1Mocks.sol";

import {Constants} from "../../../src/Constants.sol";
import {ArtCoinsTokenV2} from "../../../src/v2/ArtCoinsTokenV2.sol";
import {FeeAutoSwapperV2} from "../../../src/v2/FeeAutoSwapperV2.sol";
import {ArtCoinsHookV2} from "../../../src/v2/hooks/ArtCoinsHookV2.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsTokenV2} from "../../../src/v2/interfaces/IArtCoinsTokenV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

interface II1V3Factory {
    function createPool(address a, address b, uint24 fee) external returns (address);
}

abstract contract TaxModesV2Helpers is IntegrationV2Base {
    int24 internal constant SIDE_TS = 60;

    // ── helpers ───────────────────────────────────────────────────────────

    function _sideKey(address coin) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: 3000,
            tickSpacing: SIDE_TS,
            hooks: IHooks(address(0))
        });
    }

    /// hookless side pool at the canonical pool's price.
    function _initSide(PoolKey memory canonical, address coin)
        internal
        returns (PoolKey memory side)
    {
        side = _sideKey(coin);
        (uint160 sp,,,) = readSlot0(canonical);
        pm.initialize(side, sp);
    }

    function _floorTick(int24 t) internal pure returns (int24) {
        int24 r = (t / SIDE_TS) * SIDE_TS;
        if (t < 0 && r != t) r -= SIDE_TS;
        return r;
    }

    /// a position entirely below the current price: holds only the coin.
    function _coinOnly(PoolKey memory side, uint256 coinAmt)
        internal
        view
        returns (IPoolManager.ModifyLiquidityParams memory p)
    {
        (, int24 tc,,) = readSlot0(side);
        int24 hi = _floorTick(tc) - SIDE_TS;
        int24 lo = hi - 6000;
        uint128 liq = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), coinAmt
        );
        p = IPoolManager.ModifyLiquidityParams({
            tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(liq)), salt: bytes32(0)
        });
    }

    /// a position entirely above the current price: holds only eth.
    function _ethOnly(PoolKey memory side, uint256 ethAmt)
        internal
        view
        returns (IPoolManager.ModifyLiquidityParams memory p)
    {
        (, int24 tc,,) = readSlot0(side);
        int24 lo = _floorTick(tc) + 2 * SIDE_TS;
        int24 hi = lo + 6000;
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), ethAmt
        );
        p = IPoolManager.ModifyLiquidityParams({
            tickLower: lo,
            tickUpper: hi,
            liquidityDelta: int256(uint256(liq)),
            salt: bytes32(uint256(1))
        });
    }

    function _settings(bool takeClaims) internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: takeClaims, settleUsingBurn: false});
    }

    function _sp(bool zeroForOne, int256 amount)
        internal
        pure
        returns (IPoolManager.SwapParams memory)
    {
        return IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _hardLaunch(address treasury, address slot)
        internal
        returns (address coin, PoolKey memory key)
    {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _hardConfig(treasury);
        c.locker.rewardRecipients[0] = slot;
        IArtCoinsFactoryV2.TaxVenue[] memory v = new IArtCoinsFactoryV2.TaxVenue[](1);
        v[0] = _v3Venue();
        c.tax.venues = v;
        coin = _ownerLaunch(c);
        key = _key(coin);
    }
}

contract TaxModesV2ForkTest is TaxModesV2Helpers {
    // ══════════════════════════════════════════════════════════════════════
    // VENUE
    // ══════════════════════════════════════════════════════════════════════

    function test_i1_venue_canonicalUntaxed_sidePoolTaxed_v3VenueTaxed_thirdPartyAddClosed()
        public
        onlyFork
    {
        I1EmptyTreasury treasury = new I1EmptyTreasury();
        address coin = _ownerLaunch(_creditsConfig(address(treasury)));
        ArtCoinsTokenV2 tok = _token(coin);
        PoolKey memory key = _key(coin);
        _pastWindow();
        vm.prank(admin);
        tok.setTaxBps(1000); // the admin raises the rate under the frozen 10% cap
        assertEq(tok.taxSink(), address(treasury));
        IERC20 c = IERC20(coin);

        // canonical buy: untaxed (the hook attests the realized budget)
        uint256 sink0 = c.balanceOf(address(treasury));
        (BalanceDelta d, uint256 out) = swapExactIn(key, true, 1 ether, address(this), "");
        assertEq(out, uint256(int256(d.amount1())), "canonical buy untaxed");
        assertEq(c.balanceOf(address(treasury)), sink0, "no tax on the canonical buy");

        // third party lp on the canonical pool is closed after arming (D46)
        c.approve(address(liqRouter), type(uint256).max);
        try liqRouter.modifyLiquidity{value: 1 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_200, tickUpper: 887_200, liquidityDelta: 1e15, salt: bytes32(0)
            }),
            ""
        ) {
            fail("third party add on the canonical pool must revert");
        } catch (bytes memory err) {
            assertTrue(
                _contains(err, ArtCoinsHookV2.TaxedPoolLiquidityClosed.selector),
                "TaxedPoolLiquidityClosed"
            );
        }

        // a hookless side v4 pool: lp in is free, a buy out of it is taxed to the sink
        PoolKey memory side = _initSide(key, coin);
        liqRouter.modifyLiquidity(side, _coinOnly(side, out / 2), "");
        liqRouter.modifyLiquidity{value: 1 ether}(side, _ethOnly(side, 0.5 ether), "");
        sink0 = c.balanceOf(address(treasury));
        (d, out) = swapExactIn(side, true, 0.01 ether, address(this), "");
        uint256 gross = uint256(int256(d.amount1()));
        uint256 tax = (gross * 1000) / 10_000;
        assertGt(tax, 0);
        assertEq(out, gross - tax, "side pool buy taxed");
        assertEq(c.balanceOf(address(treasury)) - sink0, tax, "tax to the sink (the treasury)");

        // a derived v3 venue: listed by the venue admin, created, a buy out of it is taxed
        vm.prank(admin);
        address v3 = tok.addDerivedTaxVenue(_v3Venue());
        assertTrue(tok.isTaxVenue(v3), "listed");
        assertEq(
            II1V3Factory(V3_FACTORY).createPool(coin, WETH, 3000),
            v3,
            "derived address = v3 factory address"
        );
        II1V3Pool(v3).initialize(2 ** 96);
        I1V3Actor actor = new I1V3Actor();
        c.transfer(address(actor), 2e18); // holder to holder: untaxed
        dealWeth(address(actor), 2e18);
        actor.mint(v3, 1e18);
        address buyer = makeAddr("i1.v3buyer");
        sink0 = c.balanceOf(address(treasury));
        bool wethIs0 = II1V3Pool(v3).token0() == WETH;
        (int256 a0, int256 a1) = actor.swap(
            v3,
            buyer,
            wethIs0,
            -0.1e18,
            wethIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 v3Gross = uint256(-(wethIs0 ? a1 : a0));
        uint256 v3Tax = (v3Gross * 1000) / 10_000;
        assertEq(c.balanceOf(buyer), v3Gross - v3Tax, "v3 buy taxed");
        assertEq(c.balanceOf(address(treasury)) - sink0, v3Tax, "v3 tax to the sink");

        // the canonical pool still trades untaxed both ways
        sink0 = c.balanceOf(address(treasury));
        (d, out) = swapExactIn(key, true, 0.2 ether, address(this), "");
        assertEq(out, uint256(int256(d.amount1())));
        _sell(key, out);
        assertEq(c.balanceOf(address(treasury)), sink0, "canonical sell untaxed");
        _assertHookHoldsNothing(key);
    }

    // ══════════════════════════════════════════════════════════════════════
    // HARD
    // ══════════════════════════════════════════════════════════════════════

    function test_i1_hard_lockerCollect_feeSwapperConvert_burnRouterBurn_pass() public onlyFork {
        I1EmptyTreasury treasury = new I1EmptyTreasury();
        FeeAutoSwapperV2 sw = _newSwapper(address(treasury));
        (address coin, PoolKey memory key) = _hardLaunch(address(treasury), address(sw));
        sw.setup(coin);
        vm.prank(LIVE_OWNER);
        v2.burnRouter.initialize(coin, key);
        _pastWindow();
        for (uint256 i; i < 3; ++i) {
            _buyAndSell(key, 1 ether);
        }

        // locker collect passes (removal grant covers the take)
        vm.prank(keeperCaller);
        v2.locker.collectRewards(coin);
        assertGt(IERC20(coin).balanceOf(address(sw)), 0, "swapper got the coin side");
        assertGt(
            IERC20(coin).balanceOf(address(v2.controller)), 0, "protocol slot got the coin side"
        );

        // fee swapper convert passes (sell grant covers the settle)
        vm.roll(vm.getBlockNumber() + 1);
        uint256 t0 = address(treasury).balance;
        uint256 received = sw.convert(0);
        assertGt(received, 0, "converted");
        assertGt(address(treasury).balance, t0, "eth forwarded to the end recipient");

        // burn router burn passes (buy grant covers the take)
        (bool ok,) = address(v2.burnRouter).call{value: 1 ether}("");
        assertTrue(ok);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 supply0 = IERC20(coin).totalSupply();
        vm.prank(keeperCaller);
        (uint256 ethIn, uint256 burned) = v2.burnRouter.processBurn(0);
        assertGt(ethIn, 0);
        assertGt(burned, 0);
        assertEq(supply0 - IERC20(coin).totalSupply(), burned, "burned");

        // and the keeper path end to end
        _buyAndSell(key, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(keeperCaller);
        v2.keeper.collectAndForward(coin, true, 0);
        assertEq(IERC20(coin).balanceOf(address(v2.keeper)), 0, "keeper holds no coin");
        assertEq(address(v2.keeper).balance, 0, "keeper holds no eth");
        _assertHookHoldsNothing(key);
    }
}

/// HARD side pool. setUp seeds the hookless side pool with coin through
/// erc6909 claims (the documented D24 residual: a canonical buy taken as
/// claims, burned into a side position). setUp runs as its own transaction,
/// so the canonical out grant that buy left unused is gone when the test
/// starts, as it would be on chain.
contract TaxModesHardSideV2ForkTest is TaxModesV2Helpers {
    I1EmptyTreasury internal treasury;
    address internal coin;
    PoolKey internal key;
    PoolKey internal side;

    function setUp() public override {
        super.setUp();
        if (!onFork) return;
        treasury = new I1EmptyTreasury();
        (coin, key) = _hardLaunch(address(treasury), address(treasury));
        _pastWindow();
        side = _initSide(key, coin);
        swapRouter.swap{value: 1 ether}(key, _sp(true, -1 ether), _settings(true), "");
        uint256 claims = pm.balanceOf(address(this), uint256(uint160(coin)));
        require(claims > 0, "claims");
        pm.setOperator(address(liqRouter), true);
        liqRouter.modifyLiquidity(side, _coinOnly(side, claims / 2), "", true, false);
        liqRouter.modifyLiquidity{value: 2 ether}(side, _ethOnly(side, 1 ether), "");
    }

    function test_i1_hard_canonicalPasses_sidePoolTakeAndSettleRevert_venueTransferReverts()
        public
        onlyFork
    {
        ArtCoinsTokenV2 tok = _token(coin);
        IERC20 c = IERC20(coin);
        assertEq(tok.taxMode(), Constants.TAX_MODE_HARD);
        (, uint256 out0, uint256 in0) = tok.pendingCanonical();
        assertEq(out0 + in0, 0, "no grant survives a transaction");

        // canonical buy and sell pass
        uint256 got = _buy(key, 1 ether);
        assertGt(got, 0, "canonical buy");
        assertGt(_sell(key, got / 4), 0, "canonical sell");
        (, out0, in0) = tok.pendingCanonical();
        assertEq(out0 + in0, 0, "grants consumed exactly");

        // a prepaid settle (coin straight into the PoolManager) has no grant
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsTokenV2.CanonicalFlowRequired.selector, address(this), POOL_MANAGER, 1
            )
        );
        c.transfer(POOL_MANAGER, 1);

        // side pool settle of coin reverts: lp add and sell
        c.approve(address(liqRouter), type(uint256).max);
        c.approve(address(swapRouter), type(uint256).max);
        IPoolManager.ModifyLiquidityParams memory add = _coinOnly(side, got / 8);
        add.salt = bytes32(uint256(7));
        try liqRouter.modifyLiquidity(side, add, "") {
            fail("side pool coin settle must revert");
        } catch (bytes memory err) {
            assertTrue(
                _contains(err, IArtCoinsTokenV2.CanonicalFlowRequired.selector), "lp settle blocked"
            );
        }
        try swapRouter.swap(side, _sp(false, -int256(got / 8)), _settings(false), "") {
            fail("side pool sell settle must revert");
        } catch (bytes memory err) {
            assertTrue(
                _contains(err, IArtCoinsTokenV2.CanonicalFlowRequired.selector),
                "sell settle blocked"
            );
        }

        // side pool take of coin as erc20 reverts
        try swapRouter.swap{value: 0.01 ether}(side, _sp(true, -0.01 ether), _settings(false), "") {
            fail("side pool take must revert");
        } catch (bytes memory err) {
            assertTrue(
                _contains(err, IArtCoinsTokenV2.CanonicalFlowRequired.selector), "take blocked"
            );
        }
        // residual (D24): the same buy taken as erc6909 claims stays inside the PoolManager
        uint256 cl0 = pm.balanceOf(address(this), uint256(uint160(coin)));
        swapRouter.swap{value: 0.01 ether}(side, _sp(true, -0.01 ether), _settings(true), "");
        assertGt(pm.balanceOf(address(this), uint256(uint160(coin))), cl0, "claims only");

        // listed venue (derived v3 pool) is walled off both ways
        address v3 = tok.taxVenues()[0];
        assertTrue(tok.isTaxVenue(v3));
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.VenueTransferBlocked.selector, v3));
        c.transfer(v3, 1);

        // the canonical pool is unaffected
        assertGt(_buy(key, 0.1 ether), 0);
        _assertHookHoldsNothing(key);
    }
}
