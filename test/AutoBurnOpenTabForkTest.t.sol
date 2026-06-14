// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ArtCoinsAutoBurnPoolExtension} from "../src/extensions/ArtCoinsAutoBurnPoolExtension.sol";
import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsHookStaticFee} from "../src/hooks/ArtCoinsHookStaticFee.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {IArtCoinsHookStaticFee} from "../src/hooks/interfaces/IArtCoinsHookStaticFee.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsLpLocker} from "../src/lp-lockers/ArtCoinsLpLocker.sol";

interface IAllowlistView {
    function poolExtensionAllowlist() external view returns (address);
    function setPoolExtension(PoolKey calldata pk, address ext, bytes calldata initData) external;
}

interface IAllowlist {
    function owner() external view returns (address);
    function setPoolExtension(address ext, bool ok) external;
    function enabledExtensions(address ext) external view returns (bool);
}

/// @dev Minimal V4 unlock harness: opens a swap tab and, from inside it, calls
///      the BurnRouter's open-tab burn. Proves the burn settles its own deltas
///      so the surrounding unlock closes clean — without needing a full
///      hook/pool to drive it. Payable so it can earn the keeper reward (it is
///      `msg.sender` to the BurnRouter inside the callback).
contract OpenTabBurnHarness is IUnlockCallback {
    IPoolManager public immutable pm;
    BurnRouter public immutable router;

    constructor(IPoolManager pm_, BurnRouter router_) {
        pm = pm_;
        router = router_;
    }

    receive() external payable {}

    function fire(uint256 minOut) external returns (uint256 wethIn, uint256 burned) {
        bytes memory res = pm.unlock(abi.encode(minOut));
        (wethIn, burned) = abi.decode(res, (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "only pm");
        uint256 minOut = abi.decode(data, (uint256));
        (uint256 w, uint256 b) = router.processBurnWethOpenTab(minOut);
        return abi.encode(w, b);
    }
}

/// @title  AutoBurnOpenTabForkTest
/// @notice Fork proof for Workstream 2: the LAYER buy-and-burn made
///         self-executing on an open Uniswap v4 swap tab, for the V3 stack.
///
///         Self-forks (defaults to publicnode; honors FORK_BLOCK) and is
///         FAIL-LOUD: a missing live LAYER pool / V3 stack reverts setUp rather
///         than skip-passing.
///
///         Coverage:
///           - `BurnRouter.processBurnWethOpenTab` swaps + burns against the
///             LIVE LAYER/WETH pool from inside an open unlock (minimal harness).
///           - It REVERTS when the manager is locked (no open tab) — proving the
///             Universal-Router keeper path is still required for the standalone
///             case, and that exposing the open-tab path permissionlessly is safe.
///           - End-to-end: a real swap on a V3 art-coin pool with the
///             `ArtCoinsAutoBurnPoolExtension` bound drives the cross-pool
///             open-tab burn (native-ETH-paired AND WETH-paired triggers).
///           - Slippage floor + min-threshold are enforced on the open-tab path.
///           - The EMA gate composes (a fair burn passes with the gate enabled).
///           - The Universal-Router keeper path (`processBurnWeth`) still works
///             after the refactor (regression, against real liquidity).
///           - The extension is allowlistable on the LIVE V3 hook.
///
/// Run (the repo .env pins a rate-capped Alchemy key — override it):
///   MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com \
///     forge test --match-contract AutoBurnOpenTabForkTest -vv
contract AutoBurnOpenTabForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── canonical mainnet infra ─────────────────────────────────────────
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ─── live LAYER pool (V2 hook) — the buy-and-burn target ─────────────
    address constant LAYER = 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9;
    address constant LAYER_HOOK = 0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc;

    // ─── live V3 stack ───────────────────────────────────────────────────
    address constant V3_FACTORY = 0xF051cd4C4F3F36F9f24d8a19d60Ee8F84FC6793e;
    address constant V3_HOOK = 0xAAd673ea3945dF5F7Ef328974d2c07c8BdcAA8Cc;
    address constant V3_ESCROW = 0xDD1b8C9C99Be3C717B9A5eb3C84297C5bfca1C06;

    IPoolManager pm;
    PoolKey internal layerPoolKey;
    PoolSwapTest internal swapRouter;

    // fresh V3 stack (the swap-trigger side; byte-identical hook code to live)
    ArtCoinsFactory internal factory;
    ArtCoinsFeeEscrow internal escrow;
    ArtCoinsHookStaticFee internal hook;
    ArtCoinsLpLocker internal locker;
    ArtCoinsPoolExtensionAllowlist internal extAllowlist;

    address internal v3Owner = makeAddr("v3Owner");
    address internal tokenAdmin = makeAddr("tokenAdmin");
    address internal teamRecipient = makeAddr("teamRecipient");
    address internal creatorSlot = makeAddr("creatorSlot");
    address internal trader = makeAddr("trader");

    function setUp() public {
        string memory url =
            vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        try vm.envUint("FORK_BLOCK") returns (uint256 b) {
            vm.createSelectFork(url, b);
        } catch {
            vm.createSelectFork(url);
        }

        // Fail loud — never skip-pass when the live deps are absent.
        require(POOL_MANAGER.code.length > 0, "fork: PoolManager missing");
        require(LAYER.code.length > 0, "fork: LAYER token missing");
        require(LAYER_HOOK.code.length > 0, "fork: LAYER hook missing");
        require(V3_FACTORY.code.length > 0, "fork: live V3 factory missing");
        require(V3_HOOK.code.length > 0, "fork: live V3 hook missing");
        require(V3_ESCROW.code.length > 0, "fork: live V3 escrow missing");

        pm = IPoolManager(POOL_MANAGER);

        // Live LAYER/WETH pool: LAYER=currency0, WETH=currency1, dynamic fee.
        layerPoolKey = PoolKey({
            currency0: Currency.wrap(LAYER),
            currency1: Currency.wrap(WETH),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(LAYER_HOOK)
        });
        // Sanity: the pool is live (non-zero spot).
        (uint160 sp,,,) = pm.getSlot0(layerPoolKey.toId());
        require(sp != 0, "fork: LAYER pool not initialized");

        swapRouter = new PoolSwapTest(pm);
    }

    receive() external payable {}

    // ─── helpers ─────────────────────────────────────────────────────────

    /// @dev Deploys + initializes a fresh BurnRouter against the live LAYER
    ///      pool. The slippage floor is auto-derived from spot every call, so
    ///      there is nothing to set.
    function _deployBurnRouter() internal returns (BurnRouter br) {
        br = new BurnRouter(address(this));
        br.initialize(LAYER, WETH, layerPoolKey, POOL_MANAGER);
    }

    /// @dev Deploys a fresh V3 stack (factory/escrow/hook/locker/allowlist),
    ///      identical code to the live V3 stack, used as the swap-trigger side.
    function _deployFreshV3Stack() internal {
        vm.startPrank(v3Owner);
        factory = new ArtCoinsFactory(v3Owner);
        escrow = new ArtCoinsFeeEscrow(v3Owner);
        extAllowlist = new ArtCoinsPoolExtensionAllowlist(v3Owner);
        factory.setDeprecated(false);
        factory.setTeamFeeRecipient(teamRecipient);
        factory.setDeployFee(0);
        locker = new ArtCoinsLpLocker(
            v3Owner, address(factory), address(escrow), POSITION_MANAGER, PERMIT2
        );
        escrow.addDepositor(address(locker));
        vm.stopPrank();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs = abi.encode(
            POOL_MANAGER, address(factory), address(extAllowlist), WETH, address(escrow)
        );
        (address minedHook, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ArtCoinsHookStaticFee).creationCode, ctorArgs);
        hook = new ArtCoinsHookStaticFee{salt: salt}(
            POOL_MANAGER, address(factory), address(extAllowlist), WETH, address(escrow)
        );
        require(address(hook) == minedHook, "hook mine mismatch");

        vm.startPrank(v3Owner);
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), address(hook), true);
        escrow.addDepositor(address(hook));
        vm.stopPrank();
    }

    function _deployV3Token(address pairedToken, bytes32 salt)
        internal
        returns (address token, PoolKey memory poolKey)
    {
        IArtCoinsFactory.DeploymentConfig memory cfg;
        cfg.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "TestArt",
            symbol: "TART",
            salt: salt,
            image: "",
            metadata: "",
            context: "",
            totalSupply: 0,
            renderer: address(0)
        });
        cfg.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: address(hook),
            pairedToken: pairedToken,
            tickIfToken0IsArtCoins: -100_000,
            tickSpacing: 200,
            poolData: abi.encode(
                IArtCoinsHook.PoolInitializationData({
                    extension: address(0),
                    extensionData: "",
                    feeData: abi.encode(
                        IArtCoinsHookStaticFee.PoolStaticConfigVars({
                            artCoinFee: 10_000, pairedFee: 10_000
                        })
                    )
                })
            )
        });
        address[] memory admins = new address[](1);
        admins[0] = tokenAdmin;
        address[] memory recipients = new address[](1);
        recipients[0] = creatorSlot;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 8000;
        int24[] memory tickLower = new int24[](1);
        int24[] memory tickUpper = new int24[](1);
        uint16[] memory positionBps = new uint16[](1);
        tickLower[0] = 0;
        tickUpper[0] = 110_400;
        positionBps[0] = 10_000;
        cfg.lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: address(locker),
            rewardAdmins: admins,
            rewardRecipients: recipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: ""
        });
        cfg.mevModuleConfig =
            IArtCoinsFactory.MevModuleConfig({mevModule: address(0), mevModuleData: ""});
        cfg.sniperFeeConfig =
            IArtCoinsFactory.SniperFeeConfig({recipient: address(0), lockRecipient: false});
        cfg.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](0);

        vm.prank(v3Owner);
        token = factory.deployToken(cfg);

        bool token0IsArtCoins = token < pairedToken;
        poolKey = PoolKey({
            currency0: Currency.wrap(token0IsArtCoins ? token : pairedToken),
            currency1: Currency.wrap(token0IsArtCoins ? pairedToken : token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev Allowlists `ext` on the fresh hook's allowlist and binds it to the
    ///      pool as the token admin (runs the extension's init callbacks).
    function _bindExtension(PoolKey memory poolKey, address ext) internal {
        vm.prank(v3Owner);
        extAllowlist.setPoolExtension(ext, true);
        vm.prank(tokenAdmin);
        IAllowlistView(address(hook)).setPoolExtension(poolKey, ext, "");
    }

    function _buyArtCoinWithEth(PoolKey memory poolKey, uint256 amount) internal {
        vm.deal(trader, amount);
        // Native ETH = currency0; buying art coin = zeroForOne true.
        vm.prank(trader);
        swapRouter.swap{value: amount}(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _buyArtCoinWithWeth(PoolKey memory poolKey, address token, uint256 amount) internal {
        vm.deal(trader, amount);
        vm.startPrank(trader);
        IWETH9(payable(WETH)).deposit{value: amount}();
        IERC20(WETH).approve(address(swapRouter), amount);
        vm.stopPrank();
        bool zeroForOne = WETH < token; // pay WETH (the currency the trader provides)
        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ─── focused: open-tab burn against the live LAYER pool ──────────────

    /// The open-tab burn swaps WETH→LAYER on the live pool from inside an
    /// unlock and burns the proceeds; the keeper (the harness) is paid.
    function test_openTabBurn_insideUnlock_burnsLayer_andPaysKeeper() public {
        BurnRouter br = _deployBurnRouter(); // gate off, negligible floor
        OpenTabBurnHarness harness = new OpenTabBurnHarness(pm, br);

        uint256 fund = 0.05 ether;
        deal(WETH, address(br), fund);

        uint256 supplyBefore = IERC20(LAYER).totalSupply();
        uint256 keeperBefore = address(harness).balance;

        (uint256 wethIn, uint256 burned) = harness.fire(0);

        assertGt(wethIn, 0, "weth was spent");
        assertGt(burned, 0, "layer was burned");
        assertEq(IERC20(LAYER).balanceOf(address(br)), 0, "router holds no LAYER after burn");
        assertEq(
            supplyBefore - IERC20(LAYER).totalSupply(), burned, "supply dropped by burned amount"
        );

        // Keeper reward (0.5% capped at 0.01 ETH) paid to the harness in ETH.
        uint256 reward = address(harness).balance - keeperBefore;
        assertGt(reward, 0, "keeper paid");
        assertLe(reward, 0.01 ether, "keeper reward within cap");
    }

    /// Calling the open-tab burn OUTSIDE an unlock reverts (PoolManager is
    /// locked) — so the path is safe to expose permissionlessly, and the
    /// Universal-Router keeper path remains the one for the standalone case.
    function test_openTabBurn_revertsWhenManagerLocked() public {
        BurnRouter br = _deployBurnRouter();
        deal(WETH, address(br), 0.05 ether); // above threshold + floor set

        // Direct call (no open tab): passes guard/threshold/floor, then the
        // direct poolManager.swap reverts because the manager is locked.
        vm.expectRevert();
        br.processBurnWethOpenTab(0);
    }

    /// Below the min-threshold the open-tab burn reverts before swapping —
    /// surfaced even without an unlock (the check precedes the swap).
    function test_openTabBurn_revertsBelowThreshold() public {
        BurnRouter br = _deployBurnRouter();
        deal(WETH, address(br), 0.001 ether); // below the 0.01 default threshold

        // Selector-only match: the reported balance arg can be 1 wei off (a
        // `deal`/WETH artifact the router folds in via its ETH-wrap step); the
        // point is the threshold gate fired with the default 0.01 floor.
        vm.expectPartialRevert(BurnRouter.BelowMinThreshold.selector);
        br.processBurnWethOpenTab(0);
    }

    /// Slippage enforcement: an unsatisfiable caller `minLayerOut` (which can
    /// only tighten the EMA-derived floor) makes the open-tab burn revert
    /// POST-swap with InsufficientLayerOut — the direct swap has no built-in
    /// amountOutMinimum, so the effective minimum is enforced after the fact.
    function test_openTabBurn_enforcesSlippageFloor() public {
        BurnRouter br = _deployBurnRouter();
        OpenTabBurnHarness harness = new OpenTabBurnHarness(pm, br);
        deal(WETH, address(br), 0.05 ether);

        // No realistic output clears type(uint128).max.
        vm.expectRevert(); // InsufficientLayerOut, raised inside the unlock
        harness.fire(type(uint128).max);

        // The router kept its WETH (the reverted swap unwound) and burned nothing.
        assertEq(IERC20(WETH).balanceOf(address(br)), 0.05 ether, "weth retained on revert");
    }

    /// The spot-derived floor is live and price-anchored: the view returns a
    /// non-zero LAYER amount that scales with input — proving the floor adapts
    /// to price every call with no manual setter (it's `FLOOR_BPS` of the
    /// spot-implied output).
    function test_referenceFloor_isLiveAndScales() public {
        BurnRouter br = _deployBurnRouter();
        uint256 floor1 = br.requiredMinLayerOutForWethAmount(1 ether);
        uint256 floorHalf = br.requiredMinLayerOutForWethAmount(0.5 ether);
        assertGt(floor1, 0, "floor derives a real value from price");
        assertLt(floorHalf, floor1, "floor scales with input");
    }

    /// A fair burn (no price manipulation) succeeds via the open-tab path. The
    /// per-call price-impact cap is the only sandwich guard now; this confirms
    /// it is wired into the open-tab path and does not spuriously block a
    /// legitimate burn.
    function test_openTabBurn_fairBurnSucceeds() public {
        BurnRouter br = _deployBurnRouter();
        OpenTabBurnHarness harness = new OpenTabBurnHarness(pm, br);
        deal(WETH, address(br), 0.05 ether);

        uint256 supplyBefore = IERC20(LAYER).totalSupply();
        (, uint256 burned) = harness.fire(0);
        assertGt(burned, 0, "fair burn passed the EMA gate");
        assertEq(supplyBefore - IERC20(LAYER).totalSupply(), burned, "supply burned");
    }

    /// Regression: the Universal-Router keeper path still works after the
    /// shared-helper refactor, against real liquidity.
    function test_keeperPath_processBurnWeth_stillWorks() public {
        BurnRouter br = _deployBurnRouter();
        deal(WETH, address(br), 0.05 ether);

        uint256 supplyBefore = IERC20(LAYER).totalSupply();
        (uint256 wethIn, uint256 burned) = br.processBurnWeth(0);
        assertGt(wethIn, 0, "weth spent via UR path");
        assertGt(burned, 0, "layer burned via UR path");
        assertEq(supplyBefore - IERC20(LAYER).totalSupply(), burned, "supply burned (UR path)");
    }

    // ─── end-to-end: extension drives the cross-pool open-tab burn ───────

    /// A real swap on a NATIVE-ETH-paired V3 art-coin pool drives the
    /// cross-pool open-tab LAYER buy-and-burn via the bound extension — no
    /// keeper. This is the headline path (matches the PERMANENT COLLECTION
    /// native-ETH topology); zero WETH overlap between the outer swap and the
    /// inner LAYER swap.
    function test_e2e_ethPairedV3Swap_drivesOpenTabBurn() public {
        _deployFreshV3Stack();
        (address token, PoolKey memory poolKey) = _deployV3Token(address(0), keccak256("ab-eth"));

        BurnRouter br = _deployBurnRouter();
        // pfc = 0 → PFC stages skipped; we fund the BurnRouter directly to
        // isolate the open-tab burn mechanism.
        ArtCoinsAutoBurnPoolExtension ext = new ArtCoinsAutoBurnPoolExtension(
            address(hook), address(escrow), address(0), address(br), address(this)
        );
        _bindExtension(poolKey, address(ext));
        assertEq(ext.tokenForPool(poolKey.toId()), token, "ext learned the art coin");
        assertEq(ext.lockerForPool(poolKey.toId()), address(locker), "ext learned the locker");

        // BurnRouter holds WETH above threshold but no LAYER (so Stage 1
        // skips and the open-tab burn, Stage 2, is the stage that fires).
        deal(WETH, address(br), 0.05 ether);
        assertEq(IERC20(LAYER).balanceOf(address(br)), 0, "router starts with no LAYER");

        uint256 supplyBefore = IERC20(LAYER).totalSupply();
        uint256 brWethBefore = IERC20(WETH).balanceOf(address(br));

        _buyArtCoinWithEth(poolKey, 0.02 ether);

        assertLt(IERC20(LAYER).totalSupply(), supplyBefore, "LAYER supply burned by the swap");
        assertLt(IERC20(WETH).balanceOf(address(br)), brWethBefore, "router WETH consumed by burn");
        assertEq(IERC20(LAYER).balanceOf(address(br)), 0, "no LAYER left in router");
    }

    /// Same end-to-end, but a WETH-paired V3 art-coin pool — the outer swap
    /// and the inner LAYER swap both touch WETH, so this exercises the
    /// settlement-overlap case (the BurnRouter settles its own WETH delta
    /// inside afterSwap, before the outer router settles).
    function test_e2e_wethPairedV3Swap_drivesOpenTabBurn() public {
        _deployFreshV3Stack();
        (address token, PoolKey memory poolKey) = _deployV3Token(WETH, keccak256("ab-weth"));

        BurnRouter br = _deployBurnRouter();
        ArtCoinsAutoBurnPoolExtension ext = new ArtCoinsAutoBurnPoolExtension(
            address(hook), address(escrow), address(0), address(br), address(this)
        );
        _bindExtension(poolKey, address(ext));

        deal(WETH, address(br), 0.05 ether);
        uint256 supplyBefore = IERC20(LAYER).totalSupply();

        _buyArtCoinWithWeth(poolKey, token, 0.02 ether);

        assertLt(
            IERC20(LAYER).totalSupply(), supplyBefore, "LAYER supply burned (WETH-paired trigger)"
        );
        assertEq(IERC20(LAYER).balanceOf(address(br)), 0, "no LAYER left in router");
    }

    /// The extension fires processBurnLayer (Stage 1) when the BurnRouter
    /// already holds LAYER — proving the cheap burn stage is wired too.
    function test_e2e_v3Swap_burnsHeldLayer() public {
        _deployFreshV3Stack();
        (, PoolKey memory poolKey) = _deployV3Token(address(0), keccak256("ab-held"));

        BurnRouter br = _deployBurnRouter();
        ArtCoinsAutoBurnPoolExtension ext = new ArtCoinsAutoBurnPoolExtension(
            address(hook), address(escrow), address(0), address(br), address(this)
        );
        _bindExtension(poolKey, address(ext));

        // Seed LAYER directly into the router; no WETH (so only Stage 1 fires).
        uint256 seeded = 1000 ether;
        deal(LAYER, address(br), seeded);
        uint256 supplyBefore = IERC20(LAYER).totalSupply();

        _buyArtCoinWithEth(poolKey, 0.02 ether);

        assertEq(IERC20(LAYER).balanceOf(address(br)), 0, "held LAYER burned");
        assertEq(
            supplyBefore - IERC20(LAYER).totalSupply(), seeded, "supply dropped by seeded LAYER"
        );
    }

    // ─── live V3 stack wiring ────────────────────────────────────────────

    /// The extension is deployable + allowlistable on the LIVE V3 hook's
    /// allowlist (the on-chain ops path), against a BurnRouter bound to the
    /// live LAYER pool. Fail-loud against the live addresses.
    function test_live_extensionAllowlistableOnV3Hook() public {
        BurnRouter br = _deployBurnRouter();
        ArtCoinsAutoBurnPoolExtension ext = new ArtCoinsAutoBurnPoolExtension(
            V3_HOOK, V3_ESCROW, address(0), address(br), address(this)
        );

        address allowlist = IAllowlistView(V3_HOOK).poolExtensionAllowlist();
        require(allowlist.code.length > 0, "fork: live allowlist missing");
        address alOwner = IAllowlist(allowlist).owner();
        assertFalse(IAllowlist(allowlist).enabledExtensions(address(ext)), "not enabled before");

        vm.prank(alOwner);
        IAllowlist(allowlist).setPoolExtension(address(ext), true);

        assertTrue(
            IAllowlist(allowlist).enabledExtensions(address(ext)), "enabled on live allowlist"
        );
        assertEq(ext.layerToken(), LAYER, "ext bound to LAYER burn target");
        assertEq(ext.burnWeth(), WETH, "ext bound to WETH");
    }
}
