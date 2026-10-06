// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// package t1 unit tests: ArtCoinsTokenV2 and ArtCoinsDeployerV2.
// v4 is deployed from the pinned lib/v4-core source (D1). the canonical hook is
// a stub at a flagged address that grants HARD flows / attests VENUE budget from
// the real PoolManager deltas, so the token half of b1 and d2 is exercised
// against real PoolManager take and settle without depending on package h1.
// the test contract is the bound factory (launcher).
//
// note: forge runs a whole test function as one tx, so transient grants persist
// across calls inside one test. tests that need "no grant" assert
// `pendingCanonical() == 0` first.

import {Test} from "forge-std/Test.sol";

import {Base64 as SoladyBase64} from "solady/utils/Base64.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsTokenV2} from "../../src/v2/ArtCoinsTokenV2.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsTokenV2} from "../../src/v2/interfaces/IArtCoinsTokenV2.sol";
import {TaxVenues} from "../../src/v2/libraries/TaxVenues.sol";
import {ArtCoinsDeployerV2} from "../../src/v2/utils/ArtCoinsDeployerV2.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// ── mocks ─────────────────────────────────────────────────────────────────

/// @dev Canonical hook stand in. Flags: afterAddLiquidity, afterRemoveLiquidity,
///      afterSwap. Coin is always currency1 (native eth sorts first).
contract TV2StubHook {
    using PoolIdLibrary for PoolKey;

    address public token;
    bool public granting = true;

    function setToken(address t) external {
        token = t;
    }

    function setGranting(bool g) external {
        granting = g;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        _flow(key, delta.amount1());
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        _flow(key, delta.amount1());
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        _flow(key, delta.amount1());
        return (IHooks.afterSwap.selector, 0);
    }

    function _flow(PoolKey calldata key, int128 a) internal {
        if (!granting) return;
        bytes32 pid = PoolId.unwrap(key.toId());
        ArtCoinsTokenV2 t = ArtCoinsTokenV2(token);
        uint8 mode = t.taxMode();
        if (mode == Constants.TAX_MODE_HARD) {
            if (a > 0) t.grantCanonicalFlow(pid, uint128(a), 0);
            else if (a < 0) t.grantCanonicalFlow(pid, 0, uint128(-a));
        } else if (mode == Constants.TAX_MODE_VENUE && a > 0) {
            t.attestCanonicalBudget(pid, uint128(a));
        }
    }
}

/// @dev v3 style pool stand in: reports token0/token1 and can pay out.
contract TV2MockPool {
    address public token0;
    address public token1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function pay(address token, address to, uint256 amount) external {
        ArtCoinsTokenV2(token).transfer(to, amount);
    }
}

contract TV2Renderer {
    function contractURI(address) external pure returns (string memory) {
        return "custom";
    }
}

/// @dev Raw PoolManager actor for side pool paths (mint claims, burn claims, take).
contract TV2Actor is IUnlockCallback {
    IPoolManager public immutable pm;

    uint8 internal constant OP_CANON_BUY_TO_CLAIMS = 1;
    uint8 internal constant OP_ADD_WITH_CLAIMS = 2;
    uint8 internal constant OP_BUY_AND_TAKE = 3;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    receive() external payable {}

    function run(uint8 op, PoolKey calldata key, int256 amount) external {
        pm.unlock(abi.encode(op, key, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (uint8 op, PoolKey memory key, int256 amount) = abi.decode(data, (uint8, PoolKey, int256));
        Currency coin = key.currency1;
        if (op == OP_CANON_BUY_TO_CLAIMS || op == OP_BUY_AND_TAKE) {
            BalanceDelta d = pm.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: -amount,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            pm.settle{value: uint128(-d.amount0())}();
            uint256 out = uint128(d.amount1());
            if (op == OP_CANON_BUY_TO_CLAIMS) pm.mint(address(this), coin.toId(), out);
            else pm.take(coin, address(this), out);
        } else if (op == OP_ADD_WITH_CLAIMS) {
            (BalanceDelta d,) = pm.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: -887_220,
                    tickUpper: 887_220,
                    liquidityDelta: amount,
                    salt: 0
                }),
                ""
            );
            pm.settle{value: uint128(-d.amount0())}();
            pm.burn(address(this), coin.toId(), uint128(-d.amount1()));
        }
        return "";
    }
}

// ── base ──────────────────────────────────────────────────────────────────

abstract contract TokenV2Base is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant STUB_FLAGS = uint160(
        Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    int24 internal constant TS = 60;
    int24 internal constant FULL_LO = -887_220;
    int24 internal constant FULL_HI = 887_220;
    uint160 internal constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint16 internal constant BPS = 1500;
    uint16 internal constant BPS_MAX = 2000;

    ArtCoinsDeployerV2 internal deployer;
    IPoolManager internal pm;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;
    TV2StubHook internal hook;
    ArtCoinsTokenV2 internal token;

    address internal admin = makeAddr("admin");
    address payable internal bounty = payable(makeAddr("bounty"));
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal saltNonce;

    receive() external payable {}

    /// @dev Override to fork. Default: fresh PoolManager from source.
    function _poolManager() internal virtual returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(this))));
    }

    function setUp() public virtual {
        pm = _poolManager();
        swapRouter = new PoolSwapTest(pm);
        liqRouter = new PoolModifyLiquidityTest(pm);
        address at = address(uint160(0x4444_0000_0000_0000_0000_0000_0000_0000_0000_0000) | STUB_FLAGS);
        vm.etch(at, address(new TV2StubHook()).code);
        hook = TV2StubHook(at);
        hook.setGranting(true);
        deployer = new ArtCoinsDeployerV2(address(this));
        vm.deal(address(this), 1_000_000 ether);
    }

    // ── config helpers ────────────────────────────────────────────────────

    function _tokenCfg(string memory name_) internal view returns (IArtCoinsFactoryV2.TokenConfigV2 memory t) {
        t.tokenAdmin = admin;
        t.name = name_;
        t.symbol = "ART";
        t.image = "ipfs://img";
        t.metadata = "meta";
        t.context = "ctx";
    }

    function _taxCfg(uint8 mode) internal view returns (IArtCoinsFactoryV2.TaxConfigV2 memory x) {
        x.mode = mode;
        if (mode == Constants.TAX_MODE_VENUE) {
            x.taxBps = BPS;
            x.taxBpsMax = BPS_MAX;
            x.taxSink = Constants.DEAD;
        }
        x.exempt = new address[](0);
        x.venues = new IArtCoinsFactoryV2.TaxVenue[](0);
    }

    function _canon() internal view returns (ArtCoinsTokenV2.CanonicalPool memory) {
        return ArtCoinsTokenV2.CanonicalPool({
            hook: address(hook), poolManager: address(pm), tickSpacing: TS, bountyRecipient: bounty
        });
    }

    function _deploy(IArtCoinsFactoryV2.TokenConfigV2 memory t, IArtCoinsFactoryV2.TaxConfigV2 memory x)
        internal
        returns (ArtCoinsTokenV2 tk)
    {
        tk = ArtCoinsTokenV2(
            deployer.deploy(t, Constants.DEFAULT_TOKEN_SUPPLY, x, _canon(), address(this), bytes32(++saltNonce))
        );
    }

    function _deployMode(uint8 mode) internal returns (ArtCoinsTokenV2 tk) {
        tk = _deploy(_tokenCfg("Art"), _taxCfg(mode));
        token = tk;
        hook.setToken(address(tk));
    }

    // ── pool helpers ──────────────────────────────────────────────────────

    function _canonKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TS,
            hooks: IHooks(address(hook))
        });
    }

    function _sideKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: TS,
            hooks: IHooks(address(0))
        });
    }

    function _initCanonWithLiquidity(int256 liq) internal {
        PoolKey memory k = _canonKey();
        pm.initialize(k, SQRT_1_1);
        token.approve(address(liqRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        liqRouter.modifyLiquidity{value: uint256(liq) + 1 ether}(k, _liq(liq), "");
    }

    function _liq(int256 liq) internal pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams({
            tickLower: FULL_LO, tickUpper: FULL_HI, liquidityDelta: liq, salt: 0
        });
    }

    function _buy(PoolKey memory k, uint256 ethIn) internal returns (BalanceDelta) {
        return swapRouter.swap{value: ethIn}(
            k,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sell(PoolKey memory k, uint256 coinIn) internal returns (BalanceDelta) {
        return swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(coinIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _pending() internal view returns (uint256 b, uint256 o, uint256 i) {
        return token.pendingCanonical();
    }

    function _assertNoPending() internal view {
        (uint256 b, uint256 o, uint256 i) = _pending();
        assertEq(b + o + i, 0, "pending grant");
    }
}

// ── tests ─────────────────────────────────────────────────────────────────

contract TokenV2Test is TokenV2Base {
    using PoolIdLibrary for PoolKey;

    // ── HARD: canonical pool through the real PoolManager ────────────────

    function test_hard_canonicalBuyAndSell_pass() public {
        _deployMode(Constants.TAX_MODE_HARD);
        _initCanonWithLiquidity(100e18);
        _assertNoPending();

        uint256 before = token.balanceOf(address(this));
        BalanceDelta d = _buy(_canonKey(), 1 ether);
        assertEq(token.balanceOf(address(this)) - before, uint128(d.amount1()), "buy out");
        _assertNoPending(); // consumed exactly

        before = token.balanceOf(address(this));
        _sell(_canonKey(), 1000e18);
        assertEq(before - token.balanceOf(address(this)), 1000e18, "sell in");
        _assertNoPending();
    }

    function test_hard_canonicalLpRemove_pass() public {
        _deployMode(Constants.TAX_MODE_HARD);
        _initCanonWithLiquidity(100e18);
        uint256 before = token.balanceOf(address(this));
        liqRouter.modifyLiquidity(_canonKey(), _liq(-50e18), "");
        assertGt(token.balanceOf(address(this)), before, "lp exit");
        _assertNoPending();
    }

    function test_hard_launchLiquidityPlacement_pass() public {
        _deployMode(Constants.TAX_MODE_HARD);
        _initCanonWithLiquidity(100e18);
        assertGt(token.balanceOf(address(pm)), 0, "placed");
        _assertNoPending();
    }

    function test_hard_sideV4PoolSettle_reverts() public {
        _deployMode(Constants.TAX_MODE_HARD);
        _initCanonWithLiquidity(100e18);
        _assertNoPending();
        PoolKey memory side = _sideKey();
        pm.initialize(side, SQRT_1_1);
        vm.expectRevert(IArtCoinsTokenV2.CanonicalFlowRequired.selector);
        liqRouter.modifyLiquidity{value: 11 ether}(side, _liq(10e18), "");
    }

    /// @dev Coin claims (the D24 residual) can fund a side pool inside the
    ///      PoolManager, but nothing can take erc20 out of it.
    function test_hard_sideV4PoolTake_reverts() public {
        _deployMode(Constants.TAX_MODE_HARD);
        _initCanonWithLiquidity(1000e18);
        TV2Actor actor = new TV2Actor(pm);
        vm.deal(address(actor), 100 ether);

        // coin claims obtained in an earlier tx (stub models it by not granting).
        hook.setGranting(false);
        actor.run(1, _canonKey(), 20 ether);
        hook.setGranting(true);
        _assertNoPending();

        PoolKey memory side = _sideKey();
        pm.initialize(side, SQRT_1_1);
        actor.run(2, side, 5e18); // side liquidity paid with claims, no erc20 moved
        assertGt(pm.balanceOf(address(actor), side.currency1.toId()), 0, "claims left");

        vm.expectRevert(IArtCoinsTokenV2.CanonicalFlowRequired.selector);
        actor.run(3, side, 0.1 ether);
    }

    function test_hard_prepaySettle_reverts() public {
        _deployMode(Constants.TAX_MODE_HARD);
        _assertNoPending();
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsTokenV2.CanonicalFlowRequired.selector, address(this), address(pm), 1
            )
        );
        token.transfer(address(pm), 1);
    }

    function test_hard_grantConsumedExactly() public {
        _deployMode(Constants.TAX_MODE_HARD);
        bytes32 pid = token.canonicalPoolId();
        vm.prank(address(hook));
        token.grantCanonicalFlow(pid, 0, 100);
        token.transfer(address(pm), 60);
        token.transfer(address(pm), 40);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsTokenV2.CanonicalFlowRequired.selector, address(this), address(pm), 1
            )
        );
        token.transfer(address(pm), 1);

        vm.prank(address(hook));
        token.grantCanonicalFlow(pid, 50, 0);
        vm.prank(address(pm));
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsTokenV2.CanonicalFlowRequired.selector, address(pm), alice, 51)
        );
        token.transfer(alice, 51);
        vm.prank(address(pm));
        token.transfer(alice, 50);
        assertEq(token.balanceOf(alice), 50);
        _assertNoPending();
    }

    function test_hard_grantForOtherPoolIsNoop() public {
        _deployMode(Constants.TAX_MODE_HARD);
        vm.prank(address(hook));
        token.grantCanonicalFlow(bytes32(uint256(1)), 100, 100);
        _assertNoPending();
        vm.prank(address(hook));
        token.attestCanonicalBudget(token.canonicalPoolId(), 100); // wrong mode, no op
        _assertNoPending();
    }

    function test_hard_walletTransfersUnaffected() public {
        _deployMode(Constants.TAX_MODE_HARD);
        token.transfer(alice, 1000e18);
        vm.prank(alice);
        token.transfer(bob, 400e18);
        assertEq(token.balanceOf(bob), 400e18);
        token.transfer(address(pm), 0); // zero amount needs no grant
    }

    function test_hard_v3VenueTransfer_reverts() public {
        _deployMode(Constants.TAX_MODE_HARD);
        TV2MockPool pool = new TV2MockPool(address(token), makeAddr("weth"));
        token.transfer(address(pool), 100e18); // before listing: plain holder
        vm.prank(admin);
        token.addTaxVenue(address(pool));
        assertTrue(token.isTaxVenue(address(pool)));

        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.VenueTransferBlocked.selector, address(pool)));
        token.transfer(address(pool), 1);
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.VenueTransferBlocked.selector, address(pool)));
        pool.pay(address(token), alice, 1);
    }

    function test_hard_derivedVenue_blocked() public {
        _deployMode(Constants.TAX_MODE_HARD);
        IArtCoinsFactoryV2.TaxVenue memory v = IArtCoinsFactoryV2.TaxVenue({
            kind: 2,
            factory: makeAddr("v3factory"),
            initCodeHash: keccak256("init"),
            counterToken: makeAddr("weth"),
            v3Fee: 3000
        });
        vm.prank(admin);
        address pool = token.addDerivedTaxVenue(v);
        assertEq(pool, TaxVenues.derive(v, address(token)));
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.VenueTransferBlocked.selector, pool));
        token.transfer(pool, 1);
    }

    // ── VENUE ─────────────────────────────────────────────────────────────

    function test_venue_canonicalBuyUntaxed_sideV4BuyTaxed() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        _initCanonWithLiquidity(100e18);
        PoolKey memory side = _sideKey();
        pm.initialize(side, SQRT_1_1);
        liqRouter.modifyLiquidity{value: 101 ether}(side, _liq(100e18), "");

        uint256 before = token.balanceOf(address(this));
        BalanceDelta d = _buy(_canonKey(), 1 ether);
        assertEq(token.balanceOf(address(this)) - before, uint128(d.amount1()), "canonical untaxed");
        _assertNoPending();

        before = token.balanceOf(address(this));
        uint256 deadBefore = token.balanceOf(Constants.DEAD);
        d = _buy(side, 1 ether);
        uint256 gross = uint128(d.amount1());
        uint256 tax = gross * BPS / 10_000;
        assertEq(token.balanceOf(address(this)) - before, gross - tax, "side taxed");
        assertEq(token.balanceOf(Constants.DEAD) - deadBefore, tax, "sink");
    }

    function test_venue_sideV3Buy_taxed() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        TV2MockPool pool = new TV2MockPool(address(token), makeAddr("weth"));
        vm.prank(admin);
        token.addTaxVenue(address(pool));
        token.transfer(address(pool), 1000e18); // inflow (a sell or lp add) is untaxed
        assertEq(token.balanceOf(address(pool)), 1000e18);

        pool.pay(address(token), alice, 100e18);
        assertEq(token.balanceOf(alice), 85e18);
        assertEq(token.balanceOf(Constants.DEAD), 15e18);
    }

    function test_tax_budgetNotSpendableOnV3Venue() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        TV2MockPool pool = new TV2MockPool(address(token), makeAddr("weth"));
        vm.prank(admin);
        token.addTaxVenue(address(pool));
        token.transfer(address(pool), 1000e18);

        vm.prank(address(hook));
        token.attestCanonicalBudget(token.canonicalPoolId(), 1000e18);
        pool.pay(address(token), alice, 100e18);
        assertEq(token.balanceOf(alice), 85e18, "venue still taxed");
        (uint256 b,,) = _pending();
        assertEq(b, 1000e18, "budget untouched");
    }

    function test_venue_budgetOnlyFromPoolManager() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        token.transfer(address(pm), 10_000e18); // inflow untaxed
        token.transfer(alice, 1000e18);
        vm.prank(address(hook));
        token.attestCanonicalBudget(token.canonicalPoolId(), 1000e18);

        // wallet to wallet: no tax, no budget draw
        vm.prank(alice);
        token.transfer(bob, 500e18);
        (uint256 b,,) = _pending();
        assertEq(b, 1000e18);

        // PoolManager outflow: exempt up to the budget, the rest taxed
        vm.prank(address(pm));
        token.transfer(bob, 600e18);
        assertEq(token.balanceOf(bob), 1100e18, "exempt");
        vm.prank(address(pm));
        token.transfer(bob, 600e18);
        // 400 exempt, 200 taxed at 15% = 30
        assertEq(token.balanceOf(bob), 1100e18 + 570e18, "partial");
        _assertNoPending();
        vm.prank(address(pm));
        token.transfer(bob, 100e18);
        assertEq(token.balanceOf(bob), 1670e18 + 85e18, "fully taxed");
    }

    function test_venue_exemptRecipientStillDrawsBudget() public {
        address locker = address(new TV2Renderer()); // any contract
        IArtCoinsFactoryV2.TaxConfigV2 memory x = _taxCfg(Constants.TAX_MODE_VENUE);
        x.exempt = new address[](1);
        x.exempt[0] = locker;
        token = _deploy(_tokenCfg("Art"), x);
        assertTrue(token.isTaxExempt(locker));
        token.transfer(address(pm), 1000e18);
        vm.prank(address(hook));
        token.attestCanonicalBudget(token.canonicalPoolId(), 100e18);
        vm.prank(address(pm));
        token.transfer(locker, 100e18);
        assertEq(token.balanceOf(locker), 100e18);
        _assertNoPending(); // budget cannot outlive an exempt outflow
    }

    function test_venue_attestOtherPoolOrZeroIsNoop() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        vm.startPrank(address(hook));
        token.attestCanonicalBudget(bytes32(uint256(1)), 100);
        token.attestCanonicalBudget(token.canonicalPoolId(), 0);
        token.grantCanonicalFlow(token.canonicalPoolId(), 100, 100); // wrong mode
        vm.stopPrank();
        _assertNoPending();
    }

    function test_canonicalCalls_onlyHook() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        bytes32 pid = token.canonicalPoolId();
        vm.expectRevert(IArtCoinsTokenV2.NotCanonicalHook.selector);
        token.attestCanonicalBudget(pid, 1);
        vm.expectRevert(IArtCoinsTokenV2.NotCanonicalHook.selector);
        token.grantCanonicalFlow(pid, 1, 1);
    }

    function test_canonicalPoolId_matchesKey() public {
        _deployMode(Constants.TAX_MODE_HARD);
        assertEq(token.canonicalPoolId(), PoolId.unwrap(_canonKey().toId()));
        assertEq(token.canonicalHook(), address(hook));
        assertEq(token.poolManager(), address(pm));
    }

    // ── venue list ────────────────────────────────────────────────────────

    function test_venue_addOnly_noRemovePath() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        TV2MockPool pool = new TV2MockPool(address(token), makeAddr("weth"));
        vm.startPrank(admin);
        token.addTaxVenue(address(pool));
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.InvalidTaxVenue.selector, address(pool)));
        token.addTaxVenue(address(pool));
        vm.stopPrank();
        assertEq(token.taxVenues().length, 1);
        (bool ok,) = address(token).call(abi.encodeWithSignature("removeTaxVenue(address)", address(pool)));
        assertFalse(ok, "remove path exists");
        (ok,) = address(token).call(abi.encodeWithSignature("setTaxVenue(address,bool)", address(pool), false));
        assertFalse(ok, "setter exists");
    }

    function test_venue_renounce_freezesList() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        assertEq(token.venueAdmin(), admin, "defaults to token admin");
        vm.prank(admin);
        token.renounceVenueAdmin();
        assertEq(token.venueAdmin(), address(0));
        TV2MockPool pool = new TV2MockPool(address(token), makeAddr("weth"));
        vm.prank(admin);
        vm.expectRevert(IArtCoinsTokenV2.NotVenueAdmin.selector);
        token.addTaxVenue(address(pool));
        vm.prank(address(0));
        vm.expectRevert(IArtCoinsTokenV2.NotVenueAdmin.selector);
        token.addTaxVenue(address(pool));
        assertEq(token.taxVenues().length, 0);
    }

    function test_venue_nonAdmin_reverts() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        TV2MockPool pool = new TV2MockPool(address(token), makeAddr("weth"));
        vm.prank(alice);
        vm.expectRevert(IArtCoinsTokenV2.NotVenueAdmin.selector);
        token.addTaxVenue(address(pool));
        vm.prank(alice);
        vm.expectRevert(IArtCoinsTokenV2.NotVenueAdmin.selector);
        token.renounceVenueAdmin();
    }

    function test_venue_separateVenueAdmin() public {
        address va = makeAddr("venueAdmin");
        IArtCoinsFactoryV2.TaxConfigV2 memory x = _taxCfg(Constants.TAX_MODE_VENUE);
        x.venueAdmin = va;
        token = _deploy(_tokenCfg("Art"), x);
        assertEq(token.venueAdmin(), va);
        TV2MockPool pool = new TV2MockPool(address(token), makeAddr("weth"));
        vm.prank(admin);
        vm.expectRevert(IArtCoinsTokenV2.NotVenueAdmin.selector);
        token.addTaxVenue(address(pool));
        vm.prank(va);
        token.addTaxVenue(address(pool));
        // renouncing the token admin leaves the venue admin in place
        vm.prank(admin);
        token.renounceAdmin();
        assertEq(token.venueAdmin(), va);
    }

    function test_venue_addRejectsNonPools() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.InvalidTaxVenue.selector, alice));
        token.addTaxVenue(alice); // a wallet cannot be listed
        TV2MockPool other = new TV2MockPool(makeAddr("x"), makeAddr("y"));
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.InvalidTaxVenue.selector, address(other)));
        token.addTaxVenue(address(other));
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsTokenV2.InvalidTaxVenue.selector, address(pm)));
        token.addTaxVenue(address(pm));
        vm.stopPrank();
    }

    function test_venue_capEnforced() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        IArtCoinsFactoryV2.TaxVenue memory v = IArtCoinsFactoryV2.TaxVenue({
            kind: 1, factory: makeAddr("v2factory"), initCodeHash: keccak256("i"), counterToken: address(0), v3Fee: 0
        });
        vm.startPrank(admin);
        for (uint256 i = 1; i <= Constants.MAX_TAX_VENUES; ++i) {
            v.counterToken = address(uint160(0x1000 + i));
            token.addDerivedTaxVenue(v);
        }
        v.counterToken = address(uint160(0x9999));
        vm.expectRevert(IArtCoinsTokenV2.TooManyTaxVenues.selector);
        token.addDerivedTaxVenue(v);
        vm.stopPrank();
    }

    function test_venue_ctorCapEnforced() public {
        IArtCoinsFactoryV2.TaxConfigV2 memory x = _taxCfg(Constants.TAX_MODE_VENUE);
        x.venues = new IArtCoinsFactoryV2.TaxVenue[](Constants.MAX_TAX_VENUES + 1);
        for (uint256 i; i < x.venues.length; ++i) {
            x.venues[i] = IArtCoinsFactoryV2.TaxVenue({
                kind: 1,
                factory: makeAddr("v2factory"),
                initCodeHash: keccak256("i"),
                counterToken: address(uint160(0x1000 + i)),
                v3Fee: 0
            });
        }
        vm.expectRevert(ArtCoinsDeployerV2.DeployFailed.selector);
        _deploy(_tokenCfg("Art"), x);
    }

    function test_noneMode_venueAdminDisabled() public {
        _deployMode(Constants.TAX_MODE_NONE);
        assertEq(token.venueAdmin(), address(0));
        vm.prank(admin);
        vm.expectRevert(IArtCoinsTokenV2.TaxNotEnabled.selector);
        token.addTaxVenue(alice);
        assertFalse(token.isTaxVenue(address(pm)));
        token.transfer(address(pm), 5); // plain erc20
        vm.prank(address(pm));
        token.transfer(alice, 5);
        assertEq(token.balanceOf(alice), 5);
    }

    // ── constructor constraints (d4) ──────────────────────────────────────

    function test_sink_mustBeDeadOrBounty() public {
        IArtCoinsFactoryV2.TaxConfigV2 memory x = _taxCfg(Constants.TAX_MODE_VENUE);
        x.taxSink = alice;
        vm.expectRevert(ArtCoinsDeployerV2.DeployFailed.selector);
        _deploy(_tokenCfg("Art"), x);
        x.taxSink = address(0);
        vm.expectRevert(ArtCoinsDeployerV2.DeployFailed.selector);
        _deploy(_tokenCfg("Art"), x);
        x.taxSink = bounty;
        assertEq(_deploy(_tokenCfg("Art"), x).taxSink(), bounty);
        x.taxSink = Constants.DEAD;
        assertEq(_deploy(_tokenCfg("Art"), x).taxSink(), Constants.DEAD);

        IArtCoinsFactoryV2.TaxConfigV2 memory h = _taxCfg(Constants.TAX_MODE_HARD);
        h.taxSink = alice;
        vm.expectRevert(ArtCoinsDeployerV2.DeployFailed.selector);
        _deploy(_tokenCfg("Art"), h);
    }

    /// @dev The ctor reverts inside CREATE2, so the deployer surfaces DeployFailed;
    ///      the direct constructor shows the real error.
    function test_sink_directCtorError() public {
        IArtCoinsFactoryV2.TaxConfigV2 memory x = _taxCfg(Constants.TAX_MODE_VENUE);
        x.taxSink = alice;
        vm.expectRevert(IArtCoinsTokenV2.TaxConfigInvalid.selector);
        new ArtCoinsTokenV2(_tokenCfg("Art"), 1e18, x, _canon(), address(this));
    }

    function test_exempt_capAndContractsOnly() public {
        IArtCoinsFactoryV2.TaxConfigV2 memory x = _taxCfg(Constants.TAX_MODE_VENUE);
        x.exempt = new address[](Constants.MAX_TAX_EXEMPT);
        for (uint256 i; i < x.exempt.length; ++i) {
            x.exempt[i] = address(new TV2Renderer());
        }
        ArtCoinsTokenV2 tk = _deploy(_tokenCfg("Art"), x);
        assertEq(tk.taxExemptList().length, Constants.MAX_TAX_EXEMPT);

        address[] memory over = new address[](Constants.MAX_TAX_EXEMPT + 1);
        for (uint256 i; i < over.length; ++i) {
            over[i] = address(new TV2Renderer());
        }
        x.exempt = over;
        vm.expectRevert(IArtCoinsTokenV2.TaxConfigInvalid.selector);
        new ArtCoinsTokenV2(_tokenCfg("Art"), 1e18, x, _canon(), address(this));

        // an eoa (the deployer's own wallet) cannot be exempt
        x.exempt = new address[](1);
        x.exempt[0] = alice;
        vm.expectRevert(IArtCoinsTokenV2.TaxConfigInvalid.selector);
        new ArtCoinsTokenV2(_tokenCfg("Art"), 1e18, x, _canon(), address(this));

        // duplicates rejected
        address c = address(new TV2Renderer());
        x.exempt = new address[](2);
        x.exempt[0] = c;
        x.exempt[1] = c;
        vm.expectRevert(IArtCoinsTokenV2.TaxConfigInvalid.selector);
        new ArtCoinsTokenV2(_tokenCfg("Art"), 1e18, x, _canon(), address(this));

        // HARD has no exempt set
        IArtCoinsFactoryV2.TaxConfigV2 memory h = _taxCfg(Constants.TAX_MODE_HARD);
        h.exempt = new address[](1);
        h.exempt[0] = c;
        vm.expectRevert(IArtCoinsTokenV2.TaxConfigInvalid.selector);
        new ArtCoinsTokenV2(_tokenCfg("Art"), 1e18, h, _canon(), address(this));
    }

    function test_ctor_rateAndModeBounds() public {
        IArtCoinsTokenV2 tk;
        IArtCoinsFactoryV2.TaxConfigV2 memory x = _taxCfg(Constants.TAX_MODE_VENUE);
        x.taxBpsMax = Constants.TAX_BPS_ABSOLUTE_MAX + 1;
        vm.expectRevert(IArtCoinsTokenV2.TaxConfigInvalid.selector);
        tk = new ArtCoinsTokenV2(_tokenCfg("Art"), 1e18, x, _canon(), address(this));
        x.taxBpsMax = 1000;
        x.taxBps = 1001;
        vm.expectRevert(IArtCoinsTokenV2.TaxConfigInvalid.selector);
        tk = new ArtCoinsTokenV2(_tokenCfg("Art"), 1e18, x, _canon(), address(this));
        x.taxBps = 0;
        x.taxBpsMax = 0;
        vm.expectRevert(IArtCoinsTokenV2.TaxConfigInvalid.selector);
        tk = new ArtCoinsTokenV2(_tokenCfg("Art"), 1e18, x, _canon(), address(this));

        IArtCoinsFactoryV2.TaxConfigV2 memory n = _taxCfg(Constants.TAX_MODE_NONE);
        n.taxSink = Constants.DEAD; // a dormant config may not hide a sink
        vm.expectRevert(IArtCoinsTokenV2.TaxConfigInvalid.selector);
        tk = new ArtCoinsTokenV2(_tokenCfg("Art"), 1e18, n, _canon(), address(this));
        n.taxSink = address(0);
        n.mode = 3;
        vm.expectRevert(IArtCoinsTokenV2.TaxConfigInvalid.selector);
        tk = new ArtCoinsTokenV2(_tokenCfg("Art"), 1e18, n, _canon(), address(this));

        IArtCoinsFactoryV2.TaxConfigV2 memory h = _taxCfg(Constants.TAX_MODE_HARD);
        h.taxBps = 1;
        h.taxBpsMax = 1;
        vm.expectRevert(IArtCoinsTokenV2.TaxConfigInvalid.selector);
        tk = new ArtCoinsTokenV2(_tokenCfg("Art"), 1e18, h, _canon(), address(this));
    }

    // ── setTaxBps (d4, D8) ────────────────────────────────────────────────

    function test_setTaxBps_withinCap() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        vm.prank(admin);
        vm.expectEmit(address(token));
        emit IArtCoinsTokenV2.TaxBpsUpdated(BPS, BPS_MAX);
        token.setTaxBps(BPS_MAX);
        assertEq(token.taxBps(), BPS_MAX);
        vm.prank(admin);
        token.setTaxBps(0);
        assertEq(token.taxBps(), 0);
    }

    function test_setTaxBps_aboveCap_reverts() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        vm.prank(admin);
        vm.expectRevert(IArtCoinsTokenV2.TaxBpsTooHigh.selector);
        token.setTaxBps(BPS_MAX + 1);
    }

    function test_setTaxBps_nonAdmin_reverts() public {
        _deployMode(Constants.TAX_MODE_VENUE);
        vm.prank(alice);
        vm.expectRevert(IArtCoinsTokenV2.NotAdmin.selector);
        token.setTaxBps(1);
        vm.prank(admin);
        token.renounceAdmin();
        vm.prank(admin);
        vm.expectRevert(IArtCoinsTokenV2.NotAdmin.selector);
        token.setTaxBps(1);
    }

    function test_setTaxBps_hardOrNone_reverts() public {
        _deployMode(Constants.TAX_MODE_HARD);
        vm.prank(admin);
        vm.expectRevert(IArtCoinsTokenV2.TaxNotEnabled.selector);
        token.setTaxBps(1);
    }

    // ── version tag, metadata, misc (d6) ──────────────────────────────────

    function test_launcherVersion_is2() public {
        _deployMode(Constants.TAX_MODE_NONE);
        assertEq(token.launcherVersion(), 2);
        assertEq(token.launcherVersion(), Constants.STACK_VERSION);
        assertEq(token.launcher(), address(this));
        assertEq(token.constantsHash(), Constants.hash());
        assertEq(token.balanceOf(address(this)), Constants.DEFAULT_TOKEN_SUPPLY);
    }

    function test_contractURI_hostileNameEscaped() public {
        string memory hostile = string(
            abi.encodePacked('a"b\\c', bytes1(0x0a), bytes1(0x01), '</script>{"x":1}', unicode"é")
        );
        IArtCoinsFactoryV2.TokenConfigV2 memory t = _tokenCfg(hostile);
        t.symbol = '"}],';
        t.image = 'ipfs://"\\';
        t.metadata = string(abi.encodePacked(bytes1(0x09), '","image":"evil'));
        ArtCoinsTokenV2 tk = _deploy(t, _taxCfg(Constants.TAX_MODE_NONE));

        string memory uri = tk.contractURI();
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory u = bytes(uri);
        bytes memory b64 = new bytes(u.length - prefix.length);
        for (uint256 i; i < b64.length; ++i) {
            b64[i] = u[i + prefix.length];
        }
        string memory json = string(SoladyBase64.decode(string(b64)));
        assertEq(vm.parseJsonString(json, ".name"), hostile, "name");
        assertEq(vm.parseJsonString(json, ".symbol"), t.symbol, "symbol");
        assertEq(vm.parseJsonString(json, ".image"), t.image, "image");
        assertEq(vm.parseJsonString(json, ".description"), t.metadata, "description");
        assertEq(tk.tokenURI(), uri);
        assertEq(tk.name(), hostile);
    }

    function test_renderer_rules() public {
        _deployMode(Constants.TAX_MODE_NONE);
        vm.prank(admin);
        vm.expectRevert(IArtCoinsTokenV2.InvalidRenderer.selector);
        token.setMetadataRenderer(alice);
        TV2Renderer r = new TV2Renderer();
        vm.prank(admin);
        token.setMetadataRenderer(address(r));
        assertEq(token.contractURI(), "custom");
        vm.prank(alice);
        vm.expectRevert(IArtCoinsTokenV2.NotAdmin.selector);
        token.setMetadataRenderer(address(0));
    }

    function test_admin_verifyAndTransfer() public {
        _deployMode(Constants.TAX_MODE_NONE);
        vm.prank(alice);
        vm.expectRevert(IArtCoinsTokenV2.NotOriginalAdmin.selector);
        token.verify();
        vm.prank(admin);
        token.verify();
        assertTrue(token.isVerified());
        vm.prank(admin);
        vm.expectRevert(IArtCoinsTokenV2.AlreadyVerified.selector);
        token.verify();

        vm.prank(admin);
        vm.expectRevert(IArtCoinsTokenV2.ZeroAddress.selector);
        token.updateAdmin(address(0));
        vm.prank(admin);
        token.updateAdmin(bob);
        assertEq(token.admin(), bob);
        assertEq(token.originalAdmin(), admin);
        vm.prank(bob);
        token.updateImage("new");
        assertEq(token.imageUrl(), "new");
    }

    function test_permit2InfiniteAndNoVotes() public {
        _deployMode(Constants.TAX_MODE_NONE);
        assertEq(token.allowance(alice, 0x000000000022D473030F116dDEE9F6B43aC78BA3), type(uint256).max);
        (bool ok,) = address(token).call(abi.encodeWithSignature("getVotes(address)", alice));
        assertFalse(ok, "no votes extension");
        (ok,) = address(token).call(abi.encodeWithSignature("delegate(address)", alice));
        assertFalse(ok, "no delegate");
        assertTrue(token.supportsInterface(type(IArtCoinsTokenV2).interfaceId));
    }

    function test_burnAndBurnFrom() public {
        _deployMode(Constants.TAX_MODE_HARD);
        uint256 s = token.totalSupply();
        token.burn(10);
        token.approve(alice, 5);
        vm.prank(alice);
        token.burnFrom(address(this), 5);
        assertEq(token.totalSupply(), s - 15);
    }

    // ── deployer (b4) ─────────────────────────────────────────────────────

    function _salt(address sender, bytes32 cfgHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(sender, cfgHash));
    }

    function test_launch_predictTokenMatches() public {
        IArtCoinsFactoryV2.TokenConfigV2 memory t = _tokenCfg("Art");
        IArtCoinsFactoryV2.TaxConfigV2 memory x = _taxCfg(Constants.TAX_MODE_VENUE);
        bytes32 salt = _salt(alice, keccak256(abi.encode(t, x)));
        address predicted =
            deployer.predict(t, Constants.DEFAULT_TOKEN_SUPPLY, x, _canon(), address(this), salt);
        address got = deployer.deploy(t, Constants.DEFAULT_TOKEN_SUPPLY, x, _canon(), address(this), salt);
        assertEq(got, predicted);
        assertGt(got.code.length, 0);
    }

    /// @dev A front runner copies the victim's full config. The factory salts with
    ///      the sender, so the copy lands elsewhere and the victim's launch still
    ///      lands at its predicted address.
    function test_launch_frontrunCopiedConfig_differentAddress() public {
        address victim = makeAddr("victim");
        address attacker = makeAddr("attacker");
        IArtCoinsFactoryV2.TokenConfigV2 memory t = _tokenCfg("Art");
        IArtCoinsFactoryV2.TaxConfigV2 memory x = _taxCfg(Constants.TAX_MODE_VENUE);
        bytes32 h = keccak256(abi.encode(t, x));
        uint256 s = Constants.DEFAULT_TOKEN_SUPPLY;

        address victimAddr = deployer.predict(t, s, x, _canon(), address(this), _salt(victim, h));
        address attackerAddr = deployer.deploy(t, s, x, _canon(), address(this), _salt(attacker, h));
        assertTrue(attackerAddr != victimAddr, "copy collides");

        address landed = deployer.deploy(t, s, x, _canon(), address(this), _salt(victim, h));
        assertEq(landed, victimAddr, "victim blocked");

        // same sender, any changed field: different address
        x.taxSink = bounty;
        assertTrue(
            deployer.predict(t, s, x, _canon(), address(this), _salt(victim, keccak256(abi.encode(t, x))))
                != victimAddr
        );
    }

    function test_deployer_onlyFactory() public {
        IArtCoinsFactoryV2.TokenConfigV2 memory t = _tokenCfg("Art");
        IArtCoinsFactoryV2.TaxConfigV2 memory x = _taxCfg(Constants.TAX_MODE_NONE);
        vm.prank(alice);
        vm.expectRevert(ArtCoinsDeployerV2.NotFactory.selector);
        deployer.deploy(t, 1e18, x, _canon(), address(this), bytes32(0));

        vm.expectRevert(ArtCoinsDeployerV2.LauncherMismatch.selector);
        deployer.deploy(t, 1e18, x, _canon(), alice, bytes32(0));

        deployer.deploy(t, 1e18, x, _canon(), address(this), bytes32(0));
        vm.expectRevert(ArtCoinsDeployerV2.DeployFailed.selector);
        deployer.deploy(t, 1e18, x, _canon(), address(this), bytes32(0));

        assertEq(deployer.factory(), address(this));
        assertEq(deployer.constantsHash(), Constants.hash());
        vm.expectRevert(ArtCoinsDeployerV2.ZeroAddress.selector);
        new ArtCoinsDeployerV2(address(0));
    }
}
