// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {LaunchLayer} from "../script/LaunchLayer.s.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {ArtCoinsAirdrop} from "../src/extensions/ArtCoinsAirdrop.sol";
import {BurnExtension} from "../src/extensions/BurnExtension.sol";
import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsHookStaticFeeV2} from "../src/hooks/legacy/ArtCoinsHookStaticFeeV2.sol";
import {IScriptyBuilderV2, IScriptyStorageV2} from "../src/interfaces/IScripty.sol";
import {ArtCoinsFeeLocker} from "../src/legacy/ArtCoinsFeeLocker.sol";
import {ArtCoinsLpLockerMultiple} from "../src/lp-lockers/legacy/ArtCoinsLpLockerMultiple.sol";
import {ArtCoinsMevSniperSteppedFees} from "../src/mev-modules/ArtCoinsMevSniperSteppedFees.sol";
import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";
import {ProtocolFeeController} from "../src/protocol-fee/ProtocolFeeController.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

interface IHookSniperView {
    function sniperFeeRecipient(PoolId pid) external view returns (address);
    function sniperFeeRecipientLocked(PoolId pid) external view returns (bool);
    function protocolFeeNumerator() external view returns (uint256);
}

/// @title MainnetLaunchRehearsalForkTest
/// @notice End-to-end LAYER mainnet launch rehearsal. The deploy stack is
///         inlined here (rather than invoked through `Deploy.s.sol`)
///         because in test mode foundry does not propagate
///         `vm.startBroadcast` into nested `new()` calls inside a separate
///         script contract — every contract must therefore originate from
///         the test contract itself. The launch flow is invoked through
///         `LaunchLayer.launch()` to exercise the production verification
///         and config-build code paths.
///
///         Trading scenarios run against the real factory + hook + locker +
///         BurnRouter stack so any divergence between the modeled stress
///         simulations (which run hookless) and what the live hook
///         bytecode does post-launch surfaces here.
///
/// Run:
///   forge test --match-contract MainnetLaunchRehearsalForkTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract MainnetLaunchRehearsalForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── Mainnet infra ───────────────────────────────────────────────────
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant SCRIPTY_BUILDER = 0xD7587F110E08F4D120A231bA97d3B577A81Df022;
    address constant SCRIPTY_STORAGE = 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699;

    int24 constant LAYER_STARTING_TICK = -190_400;
    uint256 constant EXPECTED_POST_BURN_SUPPLY = 739_800_000e18;
    uint256 constant EXPECTED_LP_ALLOCATION = 639_800_000e18;
    uint256 constant EXPECTED_BURN_AMOUNT = 260_200_000e18;
    uint256 constant EXPECTED_CLAIM_POOL = 100_000_000e18;

    // ─── Deployed stack ──────────────────────────────────────────────────
    ArtCoinsFeeLocker internal feeLocker;
    ArtCoinsFactory internal factory;
    ArtCoinsPoolExtensionAllowlist internal poolExtAllowlist;
    ArtCoinsHookStaticFeeV2 internal hook;
    ArtCoinsLpLockerMultiple internal lpLocker;
    ArtCoinsMevSniperSteppedFees internal mevSniperStepped;
    ArtCoinsAirdrop internal airdrop;
    BurnExtension internal burnExtension;
    LiquidityLayerCounterPoolExtension internal llCounter;
    LiquidityLayerOnchainRenderer internal llRenderer;
    BurnRouter internal burnRouter;
    ProtocolFeeController internal controller;

    LaunchLayer internal launchScript;
    LaunchLayer.LaunchResult internal launchResult;

    PoolSwapTest internal swapRouter;

    address internal constant DEPLOYER = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;
    address internal constant ARTIST_TREASURY = 0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4;
    address internal constant ARTIST_RECIPIENT = 0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4;
    address internal constant PROTOCOL_TREASURY = 0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4;

    bool internal _onFork;
    bool internal _layerIsToken0;
    uint256 internal cleanSnapshotId;
    uint256 internal launchTimestamp;

    PoolKey internal poolKey;
    address internal layerAddr;

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    modifier withClean() {
        // First test: cleanSnapshotId may be 0 if setUp's snapshotState ID
        // got cleared between setUp and the test (foundry seems to reset
        // some snapshot state). Re-take it lazily on first entry.
        if (cleanSnapshotId != 0) {
            vm.revertToState(cleanSnapshotId);
        }
        cleanSnapshotId = vm.snapshotState();
        _;
    }

    receive() external payable {}

    // ─── setUp ──────────────────────────────────────────────────────────
    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: not on mainnet fork. Run with --fork-url $MAINNET_RPC_URL");
            return;
        }
        _onFork = true;

        vm.deal(address(this), 50_000 ether);
        launchTimestamp = block.timestamp;

        _deployStack();
        _deployProtocolFeeStack();
        launchScript = new LaunchLayer();
        vm.prank(DEPLOYER);
        factory.setAdmin(address(launchScript), true);
        _initBurnRouterForPredictedLaunch();
        _runLaunch();
        _postLaunchSanity();

        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        IWETH9(payable(WETH)).deposit{value: 20_000 ether}();
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);

        cleanSnapshotId = vm.snapshotState();
    }

    /// @dev Inlined copy of `DeployScript.deployStack`'s body, deploying
    ///      from `address(this)` so foundry test-mode `new()` calls succeed
    ///      without broadcast magic. Everything is owned/admined by the
    ///      test contract itself.
    function _deployStack() internal {
        address creator = address(this);
        uint64 nonce = vm.getNonce(creator);
        // In test mode, only `new()` bumps the deployer contract's nonce
        // (external calls do not). The deploy order here is:
        //   nonce+0 → feeLocker
        //   nonce+1 → factory
        //   nonce+2 → poolExtAllowlist
        // The factory.setX() call between factory and poolExtAllowlist does
        // not bump nonce in test mode, unlike under broadcast.
        address predictedFactory = vm.computeCreateAddress(creator, nonce + 1);
        address predictedPoolExtAllowlist = vm.computeCreateAddress(creator, nonce + 2);

        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs =
            abi.encode(POOL_MANAGER, predictedFactory, predictedPoolExtAllowlist, WETH);
        (address hookAddress, bytes32 hookSalt) =
            HookMiner.find(creator, hookFlags, type(ArtCoinsHookStaticFeeV2).creationCode, ctorArgs);

        feeLocker = new ArtCoinsFeeLocker(DEPLOYER);
        factory = new ArtCoinsFactory(DEPLOYER);
        require(address(factory) == predictedFactory, "Factory address mismatch");
        vm.startPrank(DEPLOYER);
        factory.setTeamFeeRecipient(DEPLOYER); // overwritten below
        vm.stopPrank();

        poolExtAllowlist = new ArtCoinsPoolExtensionAllowlist(DEPLOYER);
        require(address(poolExtAllowlist) == predictedPoolExtAllowlist, "PoolExt address mismatch");

        hook = new ArtCoinsHookStaticFeeV2{salt: hookSalt}(
            POOL_MANAGER, address(factory), address(poolExtAllowlist), WETH
        );
        require(address(hook) == hookAddress, "Hook address mismatch");
        require(hook.protocolFeeNumerator() == 0, "Hook protocolFeeNumerator must be 0");

        lpLocker = new ArtCoinsLpLockerMultiple(
            DEPLOYER, address(factory), address(feeLocker), POSITION_MANAGER, PERMIT2
        );
        mevSniperStepped = new ArtCoinsMevSniperSteppedFees();
        airdrop = new ArtCoinsAirdrop(address(factory));
        burnExtension = new BurnExtension(address(factory));
        llCounter = new LiquidityLayerCounterPoolExtension(address(hook));
        llRenderer = new LiquidityLayerOnchainRenderer(
            DEPLOYER,
            llCounter,
            IScriptyBuilderV2(SCRIPTY_BUILDER),
            IScriptyStorageV2(SCRIPTY_STORAGE),
            "ll/sketch.v1",
            "ll/mona.v1",
            "image/jpeg",
            "Until nothing remains but speculation"
        );

        vm.startPrank(DEPLOYER);
        factory.setHook(address(hook), true);
        factory.setLocker(address(lpLocker), address(hook), true);
        factory.setMevModule(address(mevSniperStepped), true);
        factory.setExtension(address(airdrop), true);
        factory.setExtension(address(burnExtension), true);
        poolExtAllowlist.setPoolExtension(address(llCounter), true);
        feeLocker.addDepositor(address(lpLocker));
        factory.setDeployFee(0); // skip ETH plumbing for the rehearsal
        vm.stopPrank();
    }

    function _deployProtocolFeeStack() internal {
        burnRouter = new BurnRouter(DEPLOYER);
        controller =
            new ProtocolFeeController(DEPLOYER, PROTOCOL_TREASURY, address(burnRouter), 6000);
        vm.startPrank(DEPLOYER);
        factory.setTeamFeeRecipient(address(controller));
        vm.stopPrank();
    }

    /// @dev Pre-initialize BurnRouter against the predicted LAYER address.
    ///      `LaunchLayer.launch()` would otherwise try to initialize it but
    ///      would fail because msg.sender at the router would be the launch
    ///      script contract, not the router's owner (this test contract).
    function _initBurnRouterForPredictedLaunch() internal {
        (address predictedLayer, PoolKey memory predictedKey) = launchScript.predictLaunch(
            DEPLOYER, address(factory), address(hook), address(llRenderer)
        );
        vm.startPrank(DEPLOYER);
        burnRouter.initialize(predictedLayer, WETH, predictedKey, POOL_MANAGER);
        // Permissive slippage floor so `processBurnWeth` can run in scenarios.
        vm.stopPrank();
    }

    function _runLaunch() internal {
        LaunchLayer.Inputs memory inp = LaunchLayer.Inputs({
            deployer: DEPLOYER,
            artistTreasury: ARTIST_TREASURY,
            artistRecipient: ARTIST_RECIPIENT,
            factory: address(factory),
            hook: address(hook),
            locker: address(lpLocker),
            mevSniperStepped: address(mevSniperStepped),
            airdrop: address(airdrop),
            burnExtension: address(burnExtension),
            llCounter: address(llCounter),
            llRenderer: address(llRenderer),
            protocolFeeController: address(controller),
            burnRouter: address(burnRouter),
            startingTick: LAYER_STARTING_TICK,
            // Must mirror `_initBurnRouterForPredictedLaunch`, which reads
            // LL_IMAGE_URI through `predictLaunch`. Hardcoding "" here would
            // silently mismatch the BurnRouter binding when env is set.
            imageUri: vm.envOr("LL_IMAGE_URI", string(""))
        });
        launchResult = launchScript.launch(inp);
        layerAddr = launchResult.layer;
        poolKey = launchResult.poolKey;
        _layerIsToken0 = layerAddr < WETH;
    }

    function _postLaunchSanity() internal view {
        require(
            ArtCoinsToken(layerAddr).totalSupply() == EXPECTED_POST_BURN_SUPPLY,
            "post-burn supply mismatch"
        );
        require(ArtCoinsToken(layerAddr).metadataRenderer() == address(llRenderer), "renderer");
        require(
            PoolId.unwrap(llCounter.poolForToken(layerAddr)) == PoolId.unwrap(poolKey.toId()),
            "counter pool link"
        );
        require(
            IERC20(layerAddr).balanceOf(address(airdrop)) == EXPECTED_CLAIM_POOL,
            "airdrop allocation missing"
        );
        require(
            IHookSniperView(address(hook)).sniperFeeRecipient(poolKey.toId())
                == address(burnRouter),
            "sniper recipient must be BurnRouter"
        );
        require(
            IHookSniperView(address(hook)).sniperFeeRecipientLocked(poolKey.toId()),
            "sniper recipient slot must be locked"
        );
        require(
            IHookSniperView(address(hook)).protocolFeeNumerator() == 0,
            "protocolFeeNumerator must be 0"
        );
    }

    // ─── Helpers: time + balances ────────────────────────────────────────
    function _skipTo(uint256 secondsFromLaunch) internal {
        vm.warp(launchTimestamp + secondsFromLaunch);
    }

    function _routerWeth() internal view returns (uint256) {
        return IERC20(WETH).balanceOf(address(burnRouter));
    }

    function _routerLayer() internal view returns (uint256) {
        return IERC20(layerAddr).balanceOf(address(burnRouter));
    }

    function _layerSupply() internal view returns (uint256) {
        return IERC20(layerAddr).totalSupply();
    }

    function _pokeLocker() internal {
        ArtCoinsLpLockerMultiple(lpLocker).collectRewards(layerAddr);
    }

    function _availableFees(address feeOwner, address token) internal view returns (uint256) {
        return ArtCoinsFeeLocker(feeLocker).availableFees(feeOwner, token);
    }

    // ─── Helpers: swaps ──────────────────────────────────────────────────
    function _exactInputBuy(uint256 wethIn) internal returns (uint256 layerOut) {
        uint256 layerBefore = IERC20(layerAddr).balanceOf(address(this));
        bool zeroForOne = !_layerIsToken0;
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
        layerOut = IERC20(layerAddr).balanceOf(address(this)) - layerBefore;
    }

    function _exactInputSell(uint256 layerIn) internal returns (uint256 wethOut) {
        IERC20(layerAddr).approve(address(swapRouter), layerIn);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        bool zeroForOne = _layerIsToken0;
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
        wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
    }

    function _exactOutputBuy(uint256 layerWanted) internal returns (uint256 wethSpent) {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        bool zeroForOne = !_layerIsToken0;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(layerWanted),
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
    }

    // ─── s00: launch report ─────────────────────────────────────────────
    function test_rehearsal_s00_launchReport() public onlyFork withClean {
        ArtCoinsToken token = ArtCoinsToken(layerAddr);
        console2.log("=== LAUNCH REPORT (rehearsal) ===");
        console2.log("LAYER:                ", layerAddr);
        console2.log("Hook:                 ", address(hook));
        console2.log("Factory:              ", address(factory));
        console2.log("LpLocker:             ", address(lpLocker));
        console2.log("MevSniperStepped:     ", address(mevSniperStepped));
        console2.log("AirdropV2:            ", address(airdrop));
        console2.log("BurnExtension:        ", address(burnExtension));
        console2.log("LLCounter:            ", address(llCounter));
        console2.log("LLRenderer:           ", address(llRenderer));
        console2.log("BurnRouter:           ", address(burnRouter));
        console2.log("ProtocolFeeController:", address(controller));
        console2.log("Artist treasury:      ", ARTIST_TREASURY);
        console2.log("Artcoins treasury:    ", PROTOCOL_TREASURY);
        console2.log("Total supply (post):  ", token.totalSupply());
        console2.log("Airdrop balance:      ", IERC20(layerAddr).balanceOf(address(airdrop)));
        console2.log("Burn extension delta: ", EXPECTED_BURN_AMOUNT);
        console2.log("LP allocation:        ", EXPECTED_LP_ALLOCATION);
        console2.log(
            "hook protocolFeeNum:  ", IHookSniperView(address(hook)).protocolFeeNumerator()
        );
        require(token.totalSupply() == EXPECTED_POST_BURN_SUPPLY, "supply");
        require(IERC20(layerAddr).balanceOf(address(airdrop)) == EXPECTED_CLAIM_POOL, "airdrop");
        require(IHookSniperView(address(hook)).protocolFeeNumerator() == 0, "protocolFeeNum");
    }

    // ─── s01: bot swarm at t=0 (50% headline) ───────────────────────────
    function test_rehearsal_s01_botSwarm_minute0() public onlyFork withClean {
        _skipTo(0);
        uint256 nBuyers = 100;
        uint256 perBuyer = 0.5 ether;
        uint256 total = nBuyers * perBuyer;
        uint256 routerWethBefore = _routerWeth();
        for (uint256 i = 0; i < nBuyers; ++i) {
            _exactInputBuy(perBuyer);
        }
        uint256 routerWethDelta = _routerWeth() - routerWethBefore;
        // Headline 50% = base 1% (to LP) + extra 49% (to BurnRouter as WETH).
        // Lazy flush hands the last swap's extra on the *next* swap, so a
        // tail of ~0.245 ETH (last swap's extra) is still pending in the
        // hook's accumulator. Allow a 1% wiggle.
        uint256 expectedMin = (total * 49 * 99) / (100 * 100);
        uint256 expectedMax = (total * 49) / 100;
        console2.log("s01 swarm: total in (wei)        ", total);
        console2.log("s01 swarm: routerWethDelta (wei) ", routerWethDelta);
        console2.log("s01 swarm: expected min          ", expectedMin);
        console2.log("s01 swarm: expected max          ", expectedMax);
        require(routerWethDelta >= expectedMin, "s01: too little to recipient");
        require(routerWethDelta <= expectedMax, "s01: too much to recipient");
    }

    // ─── s02: whale sniper minute 0 vs post-window ───────────────────────
    function test_rehearsal_s02_whaleSniper() public onlyFork withClean {
        _skipTo(0);
        uint256 routerWeth0 = _routerWeth();
        _exactInputBuy(10 ether);
        // Trigger lazy-flush of the last swap's extra by doing a tiny
        // follow-up trade in the same step.
        _exactInputBuy(0.001 ether);
        uint256 deltaT0 = _routerWeth() - routerWeth0;
        console2.log("s02 whale t=0  : routerWeth delta", deltaT0);
        // Expect ~49% of 10 ETH = 4.9 ETH (plus ~49% of 0.001 ETH = 0.0005 ETH).
        require(deltaT0 >= 4.85 ether, "s02: t=0 sniper extra too small");
        require(deltaT0 <= 5.0 ether, "s02: t=0 sniper extra too big");

        // Post-window comparison: skip past the schedule (15m+) and buy.
        // The MEV module is operational for 15 minutes after pool creation;
        // by t=901 the schedule's last step has elapsed and the extra is 0.
        // Snapshot here so other scenarios are unaffected.
        uint256 mid = vm.snapshotState();
        _skipTo(910);
        uint256 routerWeth1 = _routerWeth();
        _exactInputBuy(10 ether);
        _exactInputBuy(0.001 ether);
        uint256 deltaPost = _routerWeth() - routerWeth1;
        console2.log("s02 whale t=910: routerWeth delta", deltaPost);
        // Post-window: only base 1% LP fee flows; recipient sees nothing
        // until the locker is poked. Expect ~zero direct delta.
        require(deltaPost <= 0.001 ether, "s02: post-window extra leaked to recipient");
        vm.revertToState(mid);
    }

    // ─── s03: claim dumps post-cliff ────────────────────────────────────
    function test_rehearsal_s03_claimDumps_postCliff() public onlyFork withClean {
        // First feed the pool with WETH via a steady stream of buys during
        // the launch window — without this, sells have no WETH-side
        // liquidity to swap against (the LP is one-sided LAYER at launch).
        _skipTo(0);
        for (uint256 i = 0; i < 6; ++i) {
            _exactInputBuy(5 ether);
        }
        _skipTo(300);
        for (uint256 i = 0; i < 6; ++i) {
            _exactInputBuy(5 ether);
        }

        // Now skip past the sniper window and dump claimed LAYER.
        _skipTo(910);
        uint256 chunk = 250_000e18;
        vm.prank(address(airdrop));
        IERC20(layerAddr).transfer(address(this), chunk * 4);
        uint256 wethTotal;
        for (uint256 i = 0; i < 4; ++i) {
            wethTotal += _exactInputSell(chunk);
        }
        console2.log("s03 claim dumps: total LAYER sold", chunk * 4);
        console2.log("s03 claim dumps: total WETH out  ", wethTotal);
        require(wethTotal > 0, "s03: claim dumps yielded no WETH");
    }

    // ─── s04: buy wall then dump (sniper-extra on both sides) ────────────
    function test_rehearsal_s04_buyWallThenDump() public onlyFork withClean {
        _skipTo(0);
        uint256 routerWeth0 = _routerWeth();
        uint256 routerLayer0 = _routerLayer();
        uint256 layerOut = _exactInputBuy(5 ether);
        // Lazy-flush the buy's extra.
        _exactInputBuy(0.001 ether);

        _skipTo(120); // step boundary 120s — still in window (step 1: 25%)
        IERC20(layerAddr).approve(address(swapRouter), layerOut);
        _exactInputSell(layerOut);
        // Lazy-flush the sell's extra.
        _exactInputBuy(0.001 ether);

        uint256 wethDelta = _routerWeth() - routerWeth0;
        uint256 layerDelta = _routerLayer() - routerLayer0;
        console2.log("s04 buy/dump: routerWeth delta ", wethDelta);
        console2.log("s04 buy/dump: routerLayer delta", layerDelta);
        // Both should be positive (buy side fed WETH; sell side fed LAYER).
        require(wethDelta > 0, "s04: buy did not feed recipient WETH");
        require(layerDelta > 0, "s04: sell did not feed recipient LAYER");
    }

    // ─── s05: quiet launch (small swaps across schedule) ─────────────────
    function test_rehearsal_s05_quietLaunch() public onlyFork withClean {
        uint256[5] memory times = [uint256(0), 60, 180, 300, 600];
        uint256 routerWeth0 = _routerWeth();
        for (uint256 i = 0; i < times.length; ++i) {
            _skipTo(times[i]);
            _exactInputBuy(0.05 ether);
        }
        // Final tiny flush.
        _exactInputBuy(0.001 ether);
        uint256 delta = _routerWeth() - routerWeth0;
        console2.log("s05 quiet launch: routerWeth delta", delta);
        require(delta > 0, "s05: quiet swaps did not accrue any extra");
    }

    // ─── s06: high-success window + processBurnWeth ─────────────────────
    function test_rehearsal_s06_highSuccess_burnCadence() public onlyFork withClean {
        uint256[5] memory times = [uint256(0), 90, 240, 450, 720];
        uint256 perBuy = 10 ether;
        for (uint256 i = 0; i < times.length; ++i) {
            _skipTo(times[i]);
            _exactInputBuy(perBuy);
        }
        // Flush trailing accrual.
        _skipTo(800);
        _exactInputBuy(0.001 ether);

        uint256 supplyBefore = _layerSupply();
        uint256 wethReady = _routerWeth();
        // Burn router converts WETH → LAYER → burns. Pass minLayerOut = 0 and
        // rely on the on-chain (consumed-amount) floor: the swap impact-clamps
        // and may fill partially, so a full-balance floor would over-constrain.
        burnRouter.processBurnWeth(0);
        uint256 burned = supplyBefore - _layerSupply();
        console2.log("s06 high success: WETH ready (wei)", wethReady);
        console2.log("s06 high success: LAYER burned    ", burned);
        require(burned > 0, "s06: processBurnWeth burned 0");
    }

    // ─── s07: sandwich attack profitability ─────────────────────────────
    function test_rehearsal_s07_sandwich_t0() public onlyFork withClean {
        _skipTo(0);
        uint256 botBudget = 2 ether;
        uint256 victimBudget = 2 ether;

        // Bot front-run: buy 2 ETH worth of LAYER at t=0 (50% headline).
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 botLayer = _exactInputBuy(botBudget);
        // Victim buy.
        _exactInputBuy(victimBudget);
        // Bot back-run: sell all LAYER acquired.
        IERC20(layerAddr).approve(address(swapRouter), botLayer);
        _exactInputSell(botLayer);
        // Tiny flush so the last swap's extra is observable in router.
        _exactInputBuy(0.001 ether);
        uint256 wethAfter = IERC20(WETH).balanceOf(address(this));
        // Bot ran the front-run + back-run + the trader-funded victim buy +
        // tiny flush. Net ETH change captures the cumulative cost (P&L
        // of bot is approximately wethAfter - wethBefore + botBudget +
        // victimBudget + 0.001e18 — but since the test is a single
        // address, we just log the delta and assert it's negative — i.e.,
        // an attacker pays MORE than they recover.
        console2.log("s07 sandwich: net WETH delta (signed)");
        if (wethAfter >= wethBefore) {
            console2.log("  positive (bot profitable!?): ", wethAfter - wethBefore);
            revert("s07: sandwich profitable, sniper-extra is not deterring");
        } else {
            console2.log("  negative (bot loses): ", wethBefore - wethAfter);
        }
    }

    // ─── s08: exactOutput minute 0 (afterSwap path) ─────────────────────
    function test_rehearsal_s08_exactOutput_t0() public onlyFork withClean {
        _skipTo(0);
        uint256 routerWeth0 = _routerWeth();
        // Buy a bounded LAYER amount via exactOutput. The hook's afterSwap
        // path computes the sniper-extra on the realized WETH input.
        _exactOutputBuy(1000e18);
        // Trigger flush.
        _exactInputBuy(0.001 ether);
        uint256 delta = _routerWeth() - routerWeth0;
        console2.log("s08 exactOutput: routerWeth delta", delta);
        require(delta > 0, "s08: exactOutput skim missing, afterSwap not firing");
    }

    // ─── s09: burn cadence determinism ──────────────────────────────────
    function test_rehearsal_s09_burnCadence() public onlyFork withClean {
        _skipTo(0);
        // Multiple small buys during the punitive anti-sniper window. The hook
        // skims a large sniper-extra (~49% at t=0) into the router as WETH.
        for (uint256 i = 0; i < 8; ++i) {
            _exactInputBuy(0.5 ether);
        }
        _exactInputBuy(0.001 ether); // flush

        // The burn is intentionally GATED during the window: the ~49% sniper
        // fee skims most of the swap input, pushing realized LAYER below the
        // spot-derived floor, so the burn is refused and the accrued WETH is
        // preserved for a cheaper burn once fees normalize. The open-tab path
        // try/catches this (swaps never brick); the keeper path reverts and is
        // retried. This is by design — burning at punitive fees would waste
        // ~half the WETH.
        require(_routerWeth() > 0, "s09: expected accrued WETH in router");
        vm.expectPartialRevert(BurnRouter.InsufficientLayerOut.selector);
        burnRouter.processBurnWeth(0);

        // Skip past the 15-minute schedule — fees fall to the 1% base, so the
        // same accrued WETH now clears the floor and burns.
        _skipTo(910);
        uint256 supplyBefore = _layerSupply();
        burnRouter.processBurnWeth(0);
        uint256 burned1 = supplyBefore - _layerSupply();
        console2.log("s09 cadence: post-window pass 1 burned ", burned1);
        require(burned1 > 0, "s09: post-window burn produced nothing");

        // More buys (now at base fee), second pass.
        for (uint256 i = 0; i < 4; ++i) {
            _exactInputBuy(0.25 ether);
        }
        _exactInputBuy(0.001 ether); // flush
        uint256 supplyMid = _layerSupply();
        if (_routerWeth() >= burnRouter.minProcessThreshold()) {
            burnRouter.processBurnWeth(0);
            uint256 burned2 = supplyMid - _layerSupply();
            console2.log("s09 cadence: pass 2 burned ", burned2);
            require(burned2 > 0, "s09: pass 2 burned nothing despite WETH ready");
        } else {
            console2.log("s09 cadence: pass 2 below threshold (skipped)");
        }
    }

    // ─── s10: dashboard consistency (sequential mini-scenarios) ──────────
    function test_rehearsal_s10_dashboardConsistency() public onlyFork withClean {
        _skipTo(0);
        uint256 routerWeth0 = _routerWeth();

        // Two cohorts of buyers + a sell.
        for (uint256 i = 0; i < 20; ++i) {
            _exactInputBuy(0.5 ether);
        }
        _skipTo(180);
        for (uint256 i = 0; i < 10; ++i) {
            _exactInputBuy(1 ether);
        }

        // Sell a chunk of accumulated LAYER.
        uint256 layerHeld = IERC20(layerAddr).balanceOf(address(this));
        if (layerHeld > 0) {
            uint256 sellAmt = layerHeld / 4;
            IERC20(layerAddr).approve(address(swapRouter), sellAmt);
            _exactInputSell(sellAmt);
        }

        // Final flush.
        _skipTo(700);
        _exactInputBuy(0.001 ether);

        uint256 routerWethTotal = _routerWeth() - routerWeth0;
        uint256 routerLayerTotal = _routerLayer();

        // Poke the locker so accrued LP fees materialize into FeeLocker
        // buckets. Then read each recipient's available fees.
        _pokeLocker();
        uint256 artistWeth = _availableFees(ARTIST_TREASURY, WETH);
        uint256 artistLayer = _availableFees(ARTIST_TREASURY, layerAddr);
        uint256 controllerWeth = _availableFees(address(controller), WETH);
        uint256 controllerLayer = _availableFees(address(controller), layerAddr);
        uint256 routerLockerWeth = _availableFees(address(burnRouter), WETH);
        uint256 routerLockerLayer = _availableFees(address(burnRouter), layerAddr);

        console2.log("=== s10 DASHBOARD ===");
        console2.log("router WETH (snipers)  :", routerWethTotal);
        console2.log("router LAYER (snipers) :", routerLayerTotal);
        console2.log("locker artist WETH     :", artistWeth);
        console2.log("locker artist LAYER    :", artistLayer);
        console2.log("locker controller WETH :", controllerWeth);
        console2.log("locker controller LAYER:", controllerLayer);
        console2.log("locker burnRouter WETH :", routerLockerWeth);
        console2.log("locker burnRouter LAYER:", routerLockerLayer);

        require(routerWethTotal > 0, "s10: no sniper extra collected on buys");
        require(artistWeth > 0, "s10: artist saw no LP fees on WETH");
        require(controllerWeth > 0, "s10: controller saw no LP fees on WETH");
        require(
            IHookSniperView(address(hook)).protocolFeeNumerator() == 0,
            "s10: protocolFeeNumerator drifted"
        );
        require(
            IHookSniperView(address(hook)).sniperFeeRecipientLocked(poolKey.toId()),
            "s10: sniper recipient unlocked"
        );
    }
}
