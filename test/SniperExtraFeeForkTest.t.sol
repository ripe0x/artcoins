// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {IArtCoinsHookStaticFee} from "../src/hooks/interfaces/IArtCoinsHookStaticFee.sol";
import {ArtCoinsHookStaticFeeV2} from "../src/hooks/legacy/ArtCoinsHookStaticFeeV2.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsMevSniperSteppedFees} from "../src/mev-modules/ArtCoinsMevSniperSteppedFees.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract MintBurnToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @notice Stub of `ArtCoinsToken` — exposes only `admin()` so the hook's
///         `onlyTokenAdmin` modifier resolves correctly in the test.
contract MockTokenWithAdmin is ERC20 {
    address public admin;

    constructor(string memory n, string memory s, address a) ERC20(n, s) {
        admin = a;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAdmin(address a) external {
        admin = a;
    }
}

/// @title SniperExtraFeeForkTest
/// @notice End-to-end fork test for the new sniper-extra fee path: deploys
///         the real `ArtCoinsHookStaticFeeV2` (bytecode unchanged for tests
///         vs. mainnet) at a mined CREATE2 address, initializes a pool with
///         the LAYER 12-position LP shape, binds the new sniper-stepped MEV
///         module, sets BurnRouter (a mock ERC20 holder) as the recipient,
///         and runs sequenced buys + sells across each schedule window.
///
///         Asserts at each step:
///           - The trader pays exactly `base + extra` of input
///           - The recipient receives exactly `extra` of input currency
///           - Pool's slot0 LP fee remains the configured base (1%)
///           - Swap does not revert
///           - Lazy-flush hands accrued amounts on the next swap
///
/// Run:
///   forge test --match-contract SniperExtraFeeForkTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract SniperExtraFeeForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    int24 constant TICK_SPACING = 200;
    uint24 constant BASE_FEE_PPM = 10_000; // 1%

    ArtCoinsHookStaticFeeV2 internal hook;
    ArtCoinsMevSniperSteppedFees internal sniperModule;
    ArtCoinsPoolExtensionAllowlist internal allowlist;
    PoolModifyLiquidityTest internal liqRouter;
    PoolSwapTest internal swapRouter;
    MockTokenWithAdmin internal layer;
    MintBurnToken internal recipient; // stand-in for BurnRouter for accounting
    address internal recipientAddr;

    PoolKey internal poolKey;
    bool internal _onFork;
    bool internal _layerIsToken0;
    address internal admin = address(this);

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: not on mainnet fork");
            return;
        }
        _onFork = true;

        // 1. Deploy a fresh allowlist + token + recipient placeholder. The
        //    "factory" address passed to the hook is just `address(this)` —
        //    we never invoke factory-only paths in this test.
        allowlist = new ArtCoinsPoolExtensionAllowlist(admin);
        layer = new MockTokenWithAdmin("Liquidity Layer", "LAYER", admin);
        recipient = new MintBurnToken("BurnRouterMock", "BR");
        recipientAddr = address(recipient);

        // 2. Mine a hook address whose bottom bits encode the v4 callbacks
        //    used by ArtCoinsHookStaticFeeV2. Mirrors `Deploy.s.sol`.
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs = abi.encode(POOL_MANAGER, address(this), address(allowlist), WETH);
        // We deploy via `new ... {salt: salt}(...)` from the test contract
        // itself, so the CREATE2 deployer for HookMiner is `address(this)`.
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), hookFlags, type(ArtCoinsHookStaticFeeV2).creationCode, ctorArgs
        );
        hook = new ArtCoinsHookStaticFeeV2{salt: salt}(
            POOL_MANAGER, address(this), address(allowlist), WETH
        );
        require(address(hook) == hookAddr, "Hook address mismatch");

        // 3. Deploy the new MEV module.
        sniperModule = new ArtCoinsMevSniperSteppedFees();

        // 4. Initialize the pool via the hook's factory-only path. The hook
        //    treats `msg.sender == factory == address(this)` as authorized.
        bytes memory feeData = abi.encode(BASE_FEE_PPM, BASE_FEE_PPM);
        bytes memory poolInit = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: address(0), extensionData: "", feeData: feeData
            })
        );
        // tickIfToken0IsArtCoins — mirrors LAYER's launch starting tick.
        int24 startingTick = -190_400;
        poolKey = IArtCoinsHook(address(hook))
            .initializePool(
                address(layer),
                WETH,
                startingTick,
                TICK_SPACING,
                address(0), // locker irrelevant for this test (no fee claims by locker)
                address(sniperModule),
                poolInit
            );
        _layerIsToken0 = address(layer) < WETH;

        // 5. Set + lock the per-pool sniper-fee recipient. We're the token
        //    admin (`layer.admin() == address(this)`). Done BEFORE MEV
        //    module init so the recipient is in place from the very first
        //    swap that may trigger an extra accrual.
        IArtCoinsHook(address(hook)).setSniperFeeRecipient(poolKey, recipientAddr);
        IArtCoinsHook(address(hook)).lockSniperFeeRecipient(poolKey);
        assertEq(hook.sniperFeeRecipient(poolKey.toId()), recipientAddr);
        assertTrue(hook.sniperFeeRecipientLocked(poolKey.toId()));
        assertEq(hook.protocolFeeNumerator(), 0, "hook protocolFeeNumerator must be 0");

        // 6. Seed liquidity BEFORE enabling the MEV module — the hook
        //    blocks `beforeAddLiquidity` while the module is operational.
        liqRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        uint256 lpAmount = 100_000_000e18;
        layer.mint(address(this), lpAmount);
        IERC20(address(layer)).approve(address(liqRouter), type(uint256).max);
        IERC20(address(layer)).approve(address(swapRouter), type(uint256).max);

        int24 lower;
        int24 upper;
        if (_layerIsToken0) {
            lower = startingTick;
            upper = startingTick + 60_000;
        } else {
            lower = -(startingTick + 60_000);
            upper = -startingTick;
        }
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        uint128 L = _layerIsToken0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, lpAmount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, lpAmount);
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

        // 7. Initialize the MEV module via the hook (factory-only path).
        //    Done AFTER LP seeding, since beforeAddLiquidity is gated by
        //    mevModuleOperational.
        ArtCoinsMevSniperSteppedFees.Step[] memory schedule =
            new ArtCoinsMevSniperSteppedFees.Step[](5);
        schedule[0] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 60, feePpm: 500_000});
        schedule[1] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 120, feePpm: 250_000});
        schedule[2] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 120, feePpm: 150_000});
        schedule[3] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 300, feePpm: 70_000});
        schedule[4] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 300, feePpm: 30_000});
        bytes memory mevData = abi.encode(schedule, BASE_FEE_PPM);
        IArtCoinsHook(address(hook)).initializeMevModule(poolKey, mevData);

        // 8. Trader balances.
        vm.deal(address(this), 50 ether);
        IWETH9(payable(WETH)).deposit{value: 50 ether}();
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);
    }

    receive() external payable {}

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _doExactInputBuy(uint256 wethIn)
        internal
        returns (uint256 wethSpent, uint256 layerOut)
    {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 layerBefore = IERC20(address(layer)).balanceOf(address(this));
        bool zeroForOne = !_layerIsToken0; // WETH in → LAYER out
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(wethIn),
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
        wethSpent = wethBefore - IERC20(WETH).balanceOf(address(this));
        layerOut = IERC20(address(layer)).balanceOf(address(this)) - layerBefore;
    }

    /// @dev exactOutput WETH→LAYER buy. amountSpecified is positive (LAYER
    ///      out). Trader pays a variable amount of WETH. The pool's
    ///      sniper-extra path takes its skim from the realized WETH input
    ///      in `_afterSwap`.
    function _doExactOutputBuy(uint256 layerOut)
        internal
        returns (uint256 wethSpent, uint256 actualLayerOut)
    {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 layerBefore = IERC20(address(layer)).balanceOf(address(this));
        bool zeroForOne = !_layerIsToken0;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(layerOut),
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
        wethSpent = wethBefore - IERC20(WETH).balanceOf(address(this));
        actualLayerOut = IERC20(address(layer)).balanceOf(address(this)) - layerBefore;
    }

    /// @dev exactOutput LAYER→WETH sell. amountSpecified is positive (WETH
    ///      out). Trader pays a variable amount of LAYER. Sniper-extra
    ///      skim is taken from the realized LAYER input in `_afterSwap`.
    function _doExactOutputSell(uint256 wethOut)
        internal
        returns (uint256 layerSpent, uint256 actualWethOut)
    {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 layerBefore = IERC20(address(layer)).balanceOf(address(this));
        bool zeroForOne = _layerIsToken0;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(wethOut),
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
        layerSpent = layerBefore - IERC20(address(layer)).balanceOf(address(this));
        actualWethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
    }

    function _doExactInputSell(uint256 layerIn)
        internal
        returns (uint256 layerSpent, uint256 wethOut)
    {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 layerBefore = IERC20(address(layer)).balanceOf(address(this));
        bool zeroForOne = _layerIsToken0; // LAYER in → WETH out
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(layerIn),
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
        layerSpent = layerBefore - IERC20(address(layer)).balanceOf(address(this));
        wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
    }

    /// @dev Read pool's current LP fee from slot0. With our architecture this
    ///      should remain at BASE_FEE_PPM throughout the sniper window.
    function _slot0LpFee() internal view returns (uint24 lpFee) {
        (,,, lpFee) = IPoolManager(POOL_MANAGER).getSlot0(poolKey.toId());
    }

    // ─── Test 1: pool LP fee stays at base across the schedule ────────

    function test_poolLpFeeStaysAtBase_acrossSchedule() public onlyFork {
        // Need to do a swap first to trigger _setFee. Then check slot0.
        _doExactInputBuy(0.05 ether); // step 0
        assertEq(_slot0LpFee(), BASE_FEE_PPM, "slot0 fee at minute 0 must equal base");

        skip(90); // → step 1
        _doExactInputBuy(0.05 ether);
        assertEq(_slot0LpFee(), BASE_FEE_PPM, "slot0 fee at step 1 must equal base");

        skip(610); // → step 4 (still > 600s in cumulative)
        _doExactInputBuy(0.05 ether);
        assertEq(_slot0LpFee(), BASE_FEE_PPM, "slot0 fee at step 4 must equal base");

        // After the sniper window: still base.
        skip(300);
        _doExactInputBuy(0.05 ether);
        assertEq(_slot0LpFee(), BASE_FEE_PPM, "slot0 fee post-window must equal base");
    }

    // ─── Test 2: trader pays base + extra, recipient receives extra ─────
    //
    // Mechanic: at minute 0, configured extra is 49% of input. The extra is
    // accrued as claim tokens during this swap; the actual currency lands at
    // the recipient on the NEXT swap (lazy flush). We do a first swap to
    // accrue, then a tiny second swap to trigger flush + recipient credit.

    function test_buyAtMinute0_recipientReceivesExtraOnNextSwap() public onlyFork {
        // Trade 1: minute 0 — accrues extra to claim tokens (no flush yet).
        uint256 buy1 = 1 ether;
        (uint256 spent1,) = _doExactInputBuy(buy1);
        assertApproxEqAbs(spent1, buy1, 1, "trader spends ~1 ETH at minute 0");

        // Recipient should not have received yet — extra is accrued in
        // claim tokens awaiting flush.
        assertEq(IERC20(WETH).balanceOf(recipientAddr), 0, "no flush yet on first swap");

        // Trade 2: still in step 0; flushes prior accrual on entry to
        // _beforeSwap, then accrues new extra.
        skip(30);
        uint256 buy2 = 0.05 ether;
        _doExactInputBuy(buy2);

        // Expected flush from trade 1: 49% of 1 ether = 0.49 ether
        uint256 expectedFlush = (buy1 * 490_000) / 1_000_000;
        uint256 recvBal = IERC20(WETH).balanceOf(recipientAddr);
        assertEq(recvBal, expectedFlush, "recipient WETH at minute 0 = 49% of trade1 input");
    }

    // ─── Test 3: sell at minute 0 — extra collected as LAYER ─────────

    function test_sellAtMinute0_recipientReceivesExtraInLAYER() public onlyFork {
        // Need some LAYER to sell. Buy first (this swap takes 49% of WETH
        // as extra; we get LAYER back).
        _doExactInputBuy(2 ether); // accrues 0.98 ether of WETH extra
        // Trigger flush of WETH accrual.
        skip(1);
        _doExactInputBuy(0.01 ether);
        uint256 wethRecv = IERC20(WETH).balanceOf(recipientAddr);
        assertGt(wethRecv, 0);

        // Now sell some LAYER. Still in step 0 (within first 60s).
        uint256 layerBal = IERC20(address(layer)).balanceOf(address(this));
        uint256 sellAmt = layerBal / 4;
        _doExactInputSell(sellAmt); // accrues LAYER extra in claim tokens

        // Trigger flush via another tiny trade.
        skip(1);
        _doExactInputBuy(0.001 ether);

        // Expected flush from the sell: 49% of sellAmt in LAYER.
        uint256 expectedSellFlush = (sellAmt * 490_000) / 1_000_000;
        uint256 layerRecv = IERC20(address(layer)).balanceOf(recipientAddr);
        assertEq(layerRecv, expectedSellFlush, "recipient LAYER from sell = 49% of input");
    }

    // ─── Test 4: schedule decay — extra at each window tier ───────────

    /// @dev The hook's MEV lifetime is 15 minutes, matching the full LAYER
    ///      stepped schedule. This walks every tier while accounting for the
    ///      hook's lazy-flush timing: each larger trade flushes the tiny prior
    ///      trigger trade, then the following tiny trade flushes the target tier.
    function test_extraAtEachWindowMatchesSchedule() public onlyFork {
        // Step 0: buy 0.1 ETH at t=0 — accrues 0.049 ETH (49% of 0.1).
        _doExactInputBuy(0.1 ether);

        // Trigger flush of step-0 accrual; second swap at t=30 also accrues
        // a small amount at step 0 still.
        skip(30);
        _doExactInputBuy(0.001 ether);
        uint256 step0Recv = IERC20(WETH).balanceOf(recipientAddr);
        assertEq(step0Recv, 0.1 ether * 490_000 / 1_000_000, "step 0 flush = 49% of 0.1 ETH");

        // Step 1: buy at t=70. The _beforeSwap of this trade flushes the
        // step-0 dust (0.001*49%) AND accrues new step-1 extra (0.2*24%).
        skip(40); // now at t=70
        uint256 buyStep1 = 0.2 ether;
        _doExactInputBuy(buyStep1);
        uint256 expectedPriorFlush = 0.001 ether * 490_000 / 1_000_000;
        uint256 step1RecvBal = IERC20(WETH).balanceOf(recipientAddr);
        assertEq(
            step1RecvBal, step0Recv + expectedPriorFlush, "step 0 dust flushed at step 1 entry"
        );

        // Trigger flush of the step-1 accrual.
        skip(10);
        _doExactInputBuy(0.001 ether);
        uint256 expectedStep1 = buyStep1 * 240_000 / 1_000_000; // 0.048
        assertEq(
            IERC20(WETH).balanceOf(recipientAddr),
            step1RecvBal + expectedStep1,
            "step 1 extra = 24% of step1 input"
        );

        // Step 2: t=240, total 15%, extra 14%.
        skip(160);
        uint256 buyStep2 = 0.2 ether;
        _doExactInputBuy(buyStep2);
        uint256 expectedStep1Dust = 0.001 ether * 240_000 / 1_000_000;
        uint256 step2RecvBal = IERC20(WETH).balanceOf(recipientAddr);
        assertEq(
            step2RecvBal,
            step1RecvBal + expectedStep1 + expectedStep1Dust,
            "step 1 dust flushed at step 2 entry"
        );
        skip(10);
        _doExactInputBuy(0.001 ether);
        uint256 expectedStep2 = buyStep2 * 140_000 / 1_000_000;
        assertEq(
            IERC20(WETH).balanceOf(recipientAddr),
            step2RecvBal + expectedStep2,
            "step 2 extra = 14% of step2 input"
        );

        // Step 3: t=450, total 7%, extra 6%.
        skip(200);
        uint256 buyStep3 = 0.2 ether;
        _doExactInputBuy(buyStep3);
        uint256 expectedStep2Dust = 0.001 ether * 140_000 / 1_000_000;
        uint256 step3RecvBal = IERC20(WETH).balanceOf(recipientAddr);
        assertEq(
            step3RecvBal,
            step2RecvBal + expectedStep2 + expectedStep2Dust,
            "step 2 dust flushed at step 3 entry"
        );
        skip(10);
        _doExactInputBuy(0.001 ether);
        uint256 expectedStep3 = buyStep3 * 60_000 / 1_000_000;
        assertEq(
            IERC20(WETH).balanceOf(recipientAddr),
            step3RecvBal + expectedStep3,
            "step 3 extra = 6% of step3 input"
        );

        // Step 4: t=750, total 3%, extra 2%.
        skip(290);
        uint256 buyStep4 = 0.2 ether;
        _doExactInputBuy(buyStep4);
        uint256 expectedStep3Dust = 0.001 ether * 60_000 / 1_000_000;
        uint256 step4RecvBal = IERC20(WETH).balanceOf(recipientAddr);
        assertEq(
            step4RecvBal,
            step3RecvBal + expectedStep3 + expectedStep3Dust,
            "step 3 dust flushed at step 4 entry"
        );
        skip(10);
        _doExactInputBuy(0.001 ether);
        uint256 expectedStep4 = buyStep4 * 20_000 / 1_000_000;
        assertEq(
            IERC20(WETH).balanceOf(recipientAddr),
            step4RecvBal + expectedStep4,
            "step 4 extra = 2% of step4 input"
        );
    }

    // ─── Test 5: post-window — no extra; trader pays base only ────────

    function test_postWindow_noExtraCharged() public onlyFork {
        // Run a swap pre-window to accrue + flush so recipient has a known
        // baseline.
        _doExactInputBuy(0.1 ether);
        skip(30);
        _doExactInputBuy(0.001 ether); // flush
        uint256 baselineRecv = IERC20(WETH).balanceOf(recipientAddr);

        // Skip past the schedule end. The MEV module's elapsed-window check
        // returns disable=true so no further extra is signaled. The 0.001
        // ETH buy at t=30 had accrued its own dust extra; that gets flushed
        // by the next swap and then no more extras follow.
        skip(1000);
        _doExactInputBuy(0.5 ether);
        skip(10);
        _doExactInputBuy(0.001 ether);

        // The dust accrued from the 0.001 ETH buy at t=30 (still in step 0,
        // 49% extra) gets flushed by the 0.5 ETH buy. After that, no more
        // extras are signaled or accrued.
        uint256 dustFromStep0Carry = 0.001 ether * 490_000 / 1_000_000;
        assertEq(
            IERC20(WETH).balanceOf(recipientAddr),
            baselineRecv + dustFromStep0Carry,
            "post-window swaps add no further extra"
        );
    }

    // ─── Test 6: protocolFeeNumerator stays 0 throughout ──────────────

    function test_protocolFeeNumeratorStaysZero() public onlyFork {
        assertEq(hook.protocolFeeNumerator(), 0);
        _doExactInputBuy(0.1 ether);
        skip(30);
        _doExactInputBuy(0.05 ether);
        skip(1000);
        _doExactInputBuy(0.05 ether);
        assertEq(hook.protocolFeeNumerator(), 0, "numerator must remain 0");
        assertEq(hook.protocolFee(), 0, "protocolFee must be 0");
    }

    // ─── ExactOutput coverage (the previously-bottable loophole) ────────

    /// @dev exactOutput WETH→LAYER buy at minute 0. The trader specifies
    ///      LAYER out; pays a variable amount of WETH. Sniper-extra must
    ///      be skimmed from the realized WETH input via `_afterSwap`
    ///      (otherwise the trader would pay only the base 1% LP fee — the
    ///      original bypass loophole).
    function test_exactOutputBuy_atMinute0_recipientReceivesExtraInWETH() public onlyFork {
        // First, do a tiny exactInput buy at step 0 to get past any "first
        // swap" overhead and prove the recipient starts at 0.
        assertEq(IERC20(WETH).balanceOf(recipientAddr), 0, "recipient starts empty");

        // ExactOutput buy: ask for ~10M LAYER. Trader pays whatever WETH
        // it costs at minute 0 — and the hook should add 49% to that on
        // the input side via the afterSwap skim.
        uint256 layerOut = 10_000_000e18;
        (uint256 wethSpent,) = _doExactOutputBuy(layerOut);
        assertGt(wethSpent, 0);

        // The skim was accrued during this swap. It hasn't been flushed
        // yet (lazy flush requires a NEXT swap). Verify the accrual is on
        // the correct side and amount roughly matches.
        PoolId pid = poolKey.toId();
        // WETH side accrual:
        bool wethIsToken0 = !_layerIsToken0;
        uint256 accrued =
            wethIsToken0 ? hook.sniperExtraAccruedToken0(pid) : hook.sniperExtraAccruedToken1(pid);
        // Decompose: total WETH spent = LP swap input + sniper skim
        //            sniper skim = LP swap input * 49% (extra on input)
        // So: total = LP + 0.49 * LP = 1.49 * LP → LP = total / 1.49
        // sniper skim = total * 0.49 / 1.49.
        uint256 expectedSkim = wethSpent * 49 / 149;
        assertApproxEqRel(accrued, expectedSkim, 1e15, "accrued ~= 49/149 of WETH spent");

        // Trigger flush via a tiny exactInput swap.
        skip(1);
        _doExactInputBuy(0.001 ether);

        // Recipient now has the exactOutput skim flushed.
        uint256 recvBal = IERC20(WETH).balanceOf(recipientAddr);
        assertGe(recvBal, accrued, "recipient received at least the exactOutput skim");
    }

    /// @dev exactOutput LAYER→WETH sell at minute 0. The trader specifies
    ///      WETH out; pays a variable amount of LAYER. Sniper-extra must
    ///      land on the recipient as LAYER (input currency).
    function test_exactOutputSell_atMinute0_recipientReceivesExtraInLAYER() public onlyFork {
        // Need LAYER to sell. Do an exactInput buy first.
        _doExactInputBuy(2 ether);
        // Skip forward + flush so the recipient is in a known state.
        skip(1);
        _doExactInputBuy(0.001 ether);
        uint256 layerRecvBefore = IERC20(address(layer)).balanceOf(recipientAddr);

        // ExactOutput sell: ask for 0.05 ETH out. Trader pays whatever
        // LAYER is needed plus the sniper extra in LAYER.
        uint256 wethOut = 0.05 ether;
        (uint256 layerSpent,) = _doExactOutputSell(wethOut);
        assertGt(layerSpent, 0);

        PoolId pid = poolKey.toId();
        bool layerIsT0 = _layerIsToken0;
        uint256 accrued =
            layerIsT0 ? hook.sniperExtraAccruedToken0(pid) : hook.sniperExtraAccruedToken1(pid);
        uint256 expectedSkim = layerSpent * 49 / 149;
        assertApproxEqRel(accrued, expectedSkim, 1e15, "accrued ~= 49/149 of LAYER spent");

        // Trigger flush.
        skip(1);
        _doExactInputBuy(0.001 ether);

        uint256 layerRecvAfter = IERC20(address(layer)).balanceOf(recipientAddr);
        assertGe(layerRecvAfter - layerRecvBefore, accrued, "recipient LAYER grew by skim");
    }

    /// @dev Belt-and-suspenders: confirm slot0 LP fee stays at base for
    ///      exactOutput swaps too, proving the elevated fee is a hook
    ///      skim and NOT a higher LP fee.
    function test_exactOutput_slot0LpFeeStaysAtBase() public onlyFork {
        _doExactOutputBuy(5_000_000e18);
        assertEq(_slot0LpFee(), BASE_FEE_PPM, "slot0 LP fee unchanged after exactOutput buy");

        // Need LAYER for the exactOutput sell.
        _doExactInputBuy(1 ether);
        skip(1);
        _doExactOutputSell(0.05 ether);
        assertEq(_slot0LpFee(), BASE_FEE_PPM, "slot0 LP fee unchanged after exactOutput sell");
    }

    /// @dev After the sniper window, exactOutput swaps must NOT incur any
    ///      sniper extra. The MEV module disables itself; the recipient
    ///      should not receive anything beyond what was already accrued.
    function test_exactOutput_postWindow_noSkim() public onlyFork {
        // Do an exactInput swap at step 0, flush, capture baseline.
        _doExactInputBuy(0.1 ether);
        skip(30);
        _doExactInputBuy(0.001 ether);
        uint256 baselineRecv = IERC20(WETH).balanceOf(recipientAddr);

        // Skip past the schedule end. MEV module no longer signals an
        // extra; the always-clear in afterSwap zeros the slot every swap.
        skip(1000);
        // ExactOutput buy post-window: trader pays only the base 1%.
        uint256 layerOut = 5_000_000e18;
        _doExactOutputBuy(layerOut);
        // Flush trigger.
        skip(1);
        _doExactInputBuy(0.001 ether);

        // Recipient delta is just the dust accrual from the t+30 step-0
        // swap (0.001 ETH * 49%). NO new accrual from the exactOutput buy.
        uint256 dustFromStep0 = 0.001 ether * 490_000 / 1_000_000;
        assertEq(
            IERC20(WETH).balanceOf(recipientAddr),
            baselineRecv + dustFromStep0,
            "no further skim post-window"
        );
    }
}
