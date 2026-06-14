// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {TaxConfig} from "../src/interfaces/IArtCoinsTaxable.sol";
import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {ArtCoinsMevSniperSteppedFees} from "../src/mev-modules/ArtCoinsMevSniperSteppedFees.sol";
import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";
import {ProtocolFeeController} from "../src/protocol-fee/ProtocolFeeController.sol";

import {IArtCoinsAirdrop} from "../src/extensions/interfaces/IArtCoinsAirdrop.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";

import {LaunchDefaults} from "./LaunchDefaults.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IArtCoinsHookProtocolFeeView {
    function protocolFeeNumerator() external view returns (uint256);
}

/// @dev Inline view of the public mappings on the hook used by post-deploy
///      preflight checks (the public-mapping getters aren't in the interface).
interface IArtCoinsHookSniperView {
    function sniperFeeRecipient(PoolId pid) external view returns (address);
    function sniperFeeRecipientLocked(PoolId pid) external view returns (bool);
}

/// @title LaunchLayer
/// @notice Launch script for the Liquidity Layer (LAYER) token. Same code path
///         on every supported chain — only network infra (WETH, Universal
///         Router, Permit2) varies. Allocation, bps splits, anti-sniper
///         schedule, and the migrator merkle root are identical across chains
///         so a Sepolia dry-run is a true rehearsal of the mainnet path.
///
/// Supported chains: ETH mainnet (1), Sepolia (11155111).
///
/// Required env vars:
///   PRIVATE_KEY              Deployer key.
///   ARTIST_TREASURY          Project artist treasury (locker reward slot 1).
///   FACTORY                  ArtCoinsFactory on this chain.
///   HOOK                     Hook on this chain.
///   LOCKER                   ArtCoinsLpLockerMultiple on this chain.
///   MEV_SNIPER_STEPPED       ArtCoinsMevSniperSteppedFees on this chain.
///   AIRDROP                  ArtCoinsAirdrop on this chain.
///   BURN_EXTENSION           BurnExtension on this chain.
///   LL_COUNTER               LiquidityLayerCounterPoolExtension on this chain.
///   LL_RENDERER              LiquidityLayerOnchainRenderer on this chain.
///   PROTOCOL_FEE_CONTROLLER  Stable ProtocolFeeController address.
///   BURN_ROUTER              BurnRouter address. Pre-initialize with
///                            PrepareLayerLaunch, or this script initializes
///                            it if the signer owns the router.
///   STARTING_TICK            Aligned-to-200 starting tick (computed off-chain).
///
/// LIQUIDITY_SUPPORT is intentionally NOT required — LAYER's spec is 0%.
/// WETH / UNIVERSAL_ROUTER / PERMIT2 are chain-detected, not env vars.
contract LaunchLayer is Script {
    // ─── Chain-aware infra ────────────────────────────────────────────
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant MAINNET_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant SEPOLIA_UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    struct Network {
        address weth;
        address universalRouter;
        string name;
        address poolManager;
    }

    /// @notice Canonical V4 PoolManager. Same address on mainnet + Sepolia
    ///         (deterministic V4 deploy).
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function _getNetwork() internal view returns (Network memory) {
        if (block.chainid == 1) {
            return Network(MAINNET_WETH, MAINNET_UNIVERSAL_ROUTER, "ETH Mainnet", V4_POOL_MANAGER);
        } else if (block.chainid == 11_155_111) {
            return Network(SEPOLIA_WETH, SEPOLIA_UNIVERSAL_ROUTER, "Sepolia", V4_POOL_MANAGER);
        } else {
            revert("Unsupported chain. Use mainnet (1) or Sepolia (11155111)");
        }
    }

    /// @notice Final merkle root for the 100M LAYER migrator claim allowlist.
    bytes32 internal constant MERKLE_ROOT =
        0x67e99df6795c55652274e25884dca33c9198a49c34f5854faab1fefb5e297239;

    /// @notice 1B LAYER total supply.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Burn extension allocation: 26.02% of supply = 260,200,000 LAYER.
    /// @dev Rounded up from the historical Base burn of 260,112,158.179...
    ///      LAYER to a clean basis-point boundary (favors more deflation).
    uint16 internal constant BURN_EXTENSION_BPS = 2602;
    uint256 internal constant EXPECTED_BURN_AMOUNT = 260_200_000e18;

    /// @notice Migrator claim pool: 10% of supply = 100,000,000 LAYER.
    uint16 internal constant AIRDROP_EXTENSION_BPS = 1000;
    uint256 internal constant EXPECTED_CLAIM_POOL = 100_000_000e18;

    /// @notice Net circulating supply after the burn (= 1B − 260.2M = 739.8M).
    uint256 internal constant EXPECTED_TOTAL_SUPPLY_POST_BURN = 739_800_000e18;
    /// @notice LP allocation: remainder = 1B − 260.2M − 100M = 639.8M LAYER.
    uint256 internal constant EXPECTED_LP_ALLOCATION = 639_800_000e18;

    /// @notice LAYER project-side locker reward bps (sum to 8000 = 80%; the
    ///         factory injects the protocol slot at 2000 bps to reach 10000).
    /// @dev Updated split: 50% of total fee → buy-and-burn (project 0.42% +
    ///      protocol 0.08%); 50% → treasury (artist 0.38% + artcoins 0.12%).
    ///      LiquiditySupportReceiver is omitted entirely from LAYER's locker
    ///      array — the locker rejects 0-bps slots, and LAYER's spec is now
    ///      0% to liquidity support. The contract still exists and can be
    ///      used by future artcoins.
    uint16 internal constant ARTIST_BPS = 3800; // 38% of fee → artist treasury
    uint16 internal constant PROJECT_BURN_BPS = 4200; // 42% of fee → BurnRouter (project side)

    /// @notice LAYER ships with the 12-position thin-floor taper LP shape
    ///         (Preset L from the simulator). Constants asserted post-deploy.
    uint256 internal constant EXPECTED_LP_POSITIONS = 12;
    int24 internal constant EXPECTED_LP_LOWEST_TICK = -190_400;
    int24 internal constant EXPECTED_LP_HIGHEST_TICK = -130_400;
    uint256 internal constant EXPECTED_LP_TICK_WIDTH = 60_000;

    /// @notice Inputs to `launch`. Mirrors the env-var set used by `run()`,
    ///         plus the artistRecipient default fallback. Returned by the
    ///         script as `LaunchResult` so a test harness (the launch-day
    ///         rehearsal) can drive the same flow without touching env.
    struct Inputs {
        address deployer;
        address artistTreasury;
        address artistRecipient;
        address factory;
        address hook;
        address locker;
        address mevSniperStepped;
        address airdrop;
        address burnExtension;
        address llCounter;
        address llRenderer;
        address protocolFeeController;
        address burnRouter;
        int24 startingTick;
        // Optional IPFS / HTTPS URI baked into LAYER's `_image` storage at
        // construction. Empty string preserves prior behavior (token's image
        // is "", LL renderer's overlay handles the image field). When set,
        // the same URI should ALSO be passed to the renderer (via
        // LL_IMAGE_URI when running Deploy.s.sol) so renderer.imageOverrideUri
        // and token.imageUrl agree.
        string imageUri;
    }

    struct LaunchResult {
        address layer;
        PoolKey poolKey;
    }

    /// @notice The deploy + verify body, parameterised on `deployer` and
    ///         `inp` so it can be invoked from `run()` (env-driven script
    ///         broadcast) or from a test harness (rehearsal).
    ///         Caller is responsible for `vm.startBroadcast(deployer)` /
    ///         `vm.stopBroadcast()` around the call.
    function launch(Inputs memory inp) public returns (LaunchResult memory result) {
        _preflightInputs(inp);
        Network memory net = _getNetwork();
        ArtCoinsFactory factory = ArtCoinsFactory(inp.factory);
        IArtCoinsFactory.DeploymentConfig memory config = _buildConfig(
            inp.deployer,
            inp.artistTreasury,
            inp.artistRecipient,
            inp.hook,
            inp.locker,
            inp.mevSniperStepped,
            inp.airdrop,
            inp.burnExtension,
            inp.llCounter,
            inp.llRenderer,
            net.weth,
            inp.burnRouter,
            inp.startingTick,
            inp.imageUri
        );
        (address predictedLayer, PoolKey memory canonicalKey) =
            _preflightAndInit(inp, net, config.tokenConfig);

        address layer = factory.deployToken{value: factory.deployFee()}(config);
        require(layer == predictedLayer, "predicted LAYER mismatch");

        _verifyBurnRouterInitialized(inp.burnRouter, layer, net.weth, canonicalKey);
        _verifyAllocation(layer, factory, inp.startingTick);
        _verifySniperWiring(inp.hook, canonicalKey, inp.burnRouter);

        result.layer = layer;
        result.poolKey = canonicalKey;
    }

    /// @dev Hoisted out of `launch()` to keep its local-variable count under
    ///      the yul stack-too-deep ceiling. Predicts the LAYER address, derives
    ///      the canonical pool key, and initializes the BurnRouter if the
    ///      preflight says it isn't already wired for this LAYER/pool.
    function _preflightAndInit(
        Inputs memory inp,
        Network memory net,
        IArtCoinsFactory.TokenConfig memory tokenConfig
    ) internal returns (address predictedLayer, PoolKey memory canonicalKey) {
        predictedLayer = _predictTokenAddress(inp.factory, tokenConfig, TOTAL_SUPPLY);
        canonicalKey = _canonicalPoolKey(predictedLayer, net.weth, inp.hook);
        bool needInit = _preflightBurnRouter(
            inp.burnRouter, predictedLayer, net.weth, canonicalKey, inp.deployer
        );

        if (needInit) {
            BurnRouter(payable(inp.burnRouter))
                .initialize(predictedLayer, net.weth, canonicalKey, net.poolManager);
        }
    }

    /// @dev Hoisted to keep `launch()`'s local-variable count under the yul
    ///      stack-too-deep ceiling.
    function _preflightInputs(Inputs memory inp) internal view {
        // Every required address must be non-zero.
        _requireNonZero(inp.artistTreasury, "ARTIST_TREASURY");
        _requireNonZero(inp.artistRecipient, "ARTIST_RECIPIENT");
        _requireNonZero(inp.factory, "FACTORY");
        _requireNonZero(inp.hook, "HOOK");
        _requireNonZero(inp.locker, "LOCKER");
        _requireNonZero(inp.mevSniperStepped, "MEV_SNIPER_STEPPED");
        _requireNonZero(inp.airdrop, "AIRDROP");
        _requireNonZero(inp.burnExtension, "BURN_EXTENSION");
        _requireNonZero(inp.llCounter, "LL_COUNTER");
        _requireNonZero(inp.llRenderer, "LL_RENDERER");
        _requireNonZero(inp.protocolFeeController, "PROTOCOL_FEE_CONTROLLER");
        _requireNonZero(inp.burnRouter, "BURN_ROUTER");
        require(inp.startingTick % 200 == 0, "STARTING_TICK not aligned to 200");
        require(
            inp.startingTick == EXPECTED_LP_LOWEST_TICK, "STARTING_TICK must equal LAYER preset"
        );

        ArtCoinsFactory factory = ArtCoinsFactory(inp.factory);
        require(
            factory.teamFeeRecipient() == inp.protocolFeeController,
            "factory.teamFeeRecipient must be ProtocolFeeController"
        );
        require(
            factory.defaultProtocolFeeBps() == 2000, "factory.defaultProtocolFeeBps must be 2000"
        );
        // Hard preflight: hook must NOT take an extra protocol fee on top
        // of the pool fee. Artcoins v1 routes the protocol's share through
        // the locker's protocol reward slot only — the trader pays exactly
        // the configured pool fee.
        require(
            IArtCoinsHookProtocolFeeView(inp.hook).protocolFeeNumerator() == 0,
            "hook.protocolFeeNumerator must be 0 - extra hook-level fee detected"
        );
    }

    function run() public {
        Network memory net = _getNetwork();

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        Inputs memory inp;
        inp.deployer = deployer;
        inp.artistTreasury = vm.envAddress("ARTIST_TREASURY");
        // Optional: where artist fees actually land. Defaults to artistTreasury
        // (admin == recipient, the v1 behavior). When set to a different
        // address (e.g. a 0xSplits contract), admin stays with the treasury
        // EOA so the slot can be re-pointed later, while fees flow to the
        // splits address from day one.
        inp.artistRecipient = vm.envOr("ARTIST_RECIPIENT", inp.artistTreasury);
        inp.factory = vm.envAddress("FACTORY");
        inp.hook = vm.envAddress("HOOK");
        inp.locker = vm.envAddress("LOCKER");
        inp.mevSniperStepped = vm.envAddress("MEV_SNIPER_STEPPED");
        inp.airdrop = vm.envAddress("AIRDROP");
        inp.burnExtension = vm.envAddress("BURN_EXTENSION");
        inp.llCounter = vm.envAddress("LL_COUNTER");
        inp.llRenderer = vm.envAddress("LL_RENDERER");
        inp.protocolFeeController = vm.envAddress("PROTOCOL_FEE_CONTROLLER");
        inp.burnRouter = vm.envAddress("BURN_ROUTER");
        inp.startingTick = int24(vm.envInt("STARTING_TICK"));
        // Same env var as Deploy.s.sol — the IPFS CID lives in BOTH the
        // token's `_image` field (this) and the renderer's
        // `imageOverrideUri` (set by Deploy.s.sol). Empty default keeps
        // prior behavior.
        inp.imageUri = vm.envOr("LL_IMAGE_URI", string(""));

        console2.log("=== Launch Liquidity Layer (LAYER) ===");
        console2.log("Network:                ", net.name);
        console2.log("Chain ID:               ", block.chainid);
        console2.log("Deployer:               ", deployer);
        console2.log("Artist treasury (admin):", inp.artistTreasury);
        console2.log("Artist recipient:       ", inp.artistRecipient);
        console2.log("Factory:                ", inp.factory);
        console2.log("ProtocolFeeController:  ", inp.protocolFeeController);
        console2.log("BurnRouter:             ", inp.burnRouter);

        vm.startBroadcast(pk);
        LaunchResult memory result = launch(inp);
        vm.stopBroadcast();

        _printReport(
            result.layer,
            ArtCoinsFactory(inp.factory),
            inp.hook,
            inp.locker,
            inp.mevSniperStepped,
            inp.airdrop,
            inp.burnExtension,
            inp.llCounter,
            inp.llRenderer,
            net.weth,
            inp.protocolFeeController,
            inp.burnRouter,
            inp.startingTick
        );
    }

    function _buildConfig(
        address deployer,
        address artistTreasury,
        address artistRecipient,
        address hook,
        address locker,
        address mevSniperStepped,
        address airdrop,
        address burnExtension,
        address llCounter,
        address llRenderer,
        address weth,
        address burnRouter,
        int24 startingTick,
        string memory imageUri
    ) internal pure returns (IArtCoinsFactory.DeploymentConfig memory config) {
        config.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: deployer,
            name: "Liquidity Layer",
            symbol: "LAYER",
            salt: bytes32(0),
            image: imageUri,
            metadata: "Liquidity Layer mainnet -- first artcoin, continuation of Base LL",
            context: "layer-mainnet",
            totalSupply: TOTAL_SUPPLY,
            renderer: llRenderer
        });

        bytes memory feeData = abi.encode(LaunchDefaults.BUY_FEE, LaunchDefaults.SELL_FEE);
        bytes memory poolData = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: llCounter, extensionData: "", feeData: feeData
            })
        );
        config.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: hook,
            pairedToken: weth,
            tickIfToken0IsArtCoins: startingTick,
            tickSpacing: LaunchDefaults.TICK_SPACING,
            poolData: poolData
        });

        // Locker config: 2 project-side slots summing to 8000 (factory injects
        // protocol slot for the remaining 2000). LiquiditySupportReceiver is
        // omitted entirely — LAYER's spec is 0% to liquidity support, and the
        // locker rejects 0-bps slots.
        address[] memory rewardAdmins = new address[](2);
        rewardAdmins[0] = artistTreasury; // artist controls own slot
        rewardAdmins[1] = deployer; // deployer admins the project burn slot (transferable later)
        address[] memory rewardRecipients = new address[](2);
        rewardRecipients[0] = artistRecipient; // can be a splits contract; admin still updateable
        rewardRecipients[1] = burnRouter;
        uint16[] memory rewardBps = new uint16[](2);
        rewardBps[0] = ARTIST_BPS; // 3800
        rewardBps[1] = PROJECT_BURN_BPS; // 4200

        (int24[] memory tickLower, int24[] memory tickUpper, uint16[] memory positionBps) =
            LaunchDefaults.buildLayerThinFloor12Positions(startingTick);

        config.lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: locker,
            rewardAdmins: rewardAdmins,
            rewardRecipients: rewardRecipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: ""
        });

        // MEV: stepped 50/25/15/7/3 over 15 minutes. Schedule entries are
        // TOTAL trader-paid fees; the module subtracts `basePpm` (1% = 10_000)
        // and signals only the EXTRA via `mevModuleSetSniperFee`. The pool's
        // LP fee stays at the base, so the locker normal split keeps
        // receiving only the base 1%; the extra routes 100% to the per-pool
        // sniper recipient (BurnRouter).
        ArtCoinsMevSniperSteppedFees.Step[] memory schedule =
            new ArtCoinsMevSniperSteppedFees.Step[](5);
        schedule[0] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 60, feePpm: 500_000});
        schedule[1] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 120, feePpm: 250_000});
        schedule[2] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 120, feePpm: 150_000});
        schedule[3] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 300, feePpm: 70_000});
        schedule[4] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 300, feePpm: 30_000});
        uint24 basePpm = 10_000; // 1% — must match LaunchDefaults.BUY_FEE / SELL_FEE
        config.mevModuleConfig = IArtCoinsFactory.MevModuleConfig({
            mevModule: mevSniperStepped, mevModuleData: abi.encode(schedule, basePpm)
        });
        config.sniperFeeConfig =
            IArtCoinsFactory.SniperFeeConfig({recipient: burnRouter, lockRecipient: true});

        // Extensions: burn (260.2M) + airdrop (100M).
        IArtCoinsFactory.ExtensionConfig[] memory extensions =
            new IArtCoinsFactory.ExtensionConfig[](2);
        extensions[0] = IArtCoinsFactory.ExtensionConfig({
            extension: burnExtension,
            msgValue: 0,
            extensionBps: BURN_EXTENSION_BPS,
            extensionData: ""
        });
        extensions[1] = IArtCoinsFactory.ExtensionConfig({
            extension: airdrop,
            msgValue: 0,
            extensionBps: AIRDROP_EXTENSION_BPS,
            extensionData: abi.encode(
                IArtCoinsAirdrop.AirdropV2ExtensionData({
                    admin: deployer, merkleRoot: MERKLE_ROOT, lockupDuration: 0, vestingDuration: 0
                })
            )
        });
        config.extensionConfigs = extensions;
    }

    /// @notice Public prediction of the LAYER token address + canonical pool
    ///         key for a given deployer + factory. Used by the rehearsal test
    ///         to pre-initialize the BurnRouter before calling `launch()`
    ///         (which would otherwise try to initialize it itself, with the
    ///         wrong msg.sender).
    function predictLaunch(address deployer, address factoryAddr, address hook)
        public
        view
        returns (address layer, PoolKey memory poolKey)
    {
        return predictLaunch(deployer, factoryAddr, hook, address(0));
    }

    function predictLaunch(address deployer, address factoryAddr, address hook, address renderer)
        public
        view
        returns (address layer, PoolKey memory poolKey)
    {
        IArtCoinsFactory.TokenConfig memory tk;
        tk.tokenAdmin = deployer;
        tk.name = "Liquidity Layer";
        tk.symbol = "LAYER";
        tk.salt = bytes32(0);
        // Must match `_buildConfig` exactly — image is part of the token's
        // constructor args and therefore part of the CREATE2 salt.
        tk.image = vm.envOr("LL_IMAGE_URI", string(""));
        tk.metadata = "Liquidity Layer mainnet -- first artcoin, continuation of Base LL";
        tk.context = "layer-mainnet";
        tk.totalSupply = TOTAL_SUPPLY;
        tk.renderer = renderer;

        layer = _predictTokenAddress(factoryAddr, tk, TOTAL_SUPPLY);
        Network memory net = _getNetwork();
        poolKey = _canonicalPoolKey(layer, net.weth, hook);
    }

    function _predictTokenAddress(
        address factoryAddr,
        IArtCoinsFactory.TokenConfig memory tokenConfig,
        uint256 totalSupply
    ) internal pure returns (address) {
        // ArtCoinsToken's constructor takes a 9th arg, the venue-scoped
        // TaxConfig. The standard (non-tax) deploy path the factory uses
        // (`ArtCoinsDeployer.deployToken` → `_emptyTaxConfig()`) passes a
        // fully-dormant, default-initialized TaxConfig, so the prediction
        // must encode the same empty struct to match the real init code.
        TaxConfig memory emptyTax;
        bytes memory ctorArgs = abi.encode(
            tokenConfig.name,
            tokenConfig.symbol,
            totalSupply,
            tokenConfig.tokenAdmin,
            tokenConfig.image,
            tokenConfig.metadata,
            tokenConfig.context,
            tokenConfig.renderer,
            emptyTax
        );
        bytes32 salt = keccak256(abi.encode(tokenConfig.tokenAdmin, tokenConfig.salt));
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(ArtCoinsToken).creationCode, ctorArgs));
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), factoryAddr, salt, initCodeHash)))
            )
        );
    }

    function _canonicalPoolKey(address layer, address weth, address hook)
        internal
        pure
        returns (PoolKey memory key)
    {
        (address c0, address c1) = layer < weth ? (layer, weth) : (weth, layer);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000, // dynamic fee flag
            tickSpacing: LaunchDefaults.TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    function _preflightBurnRouter(
        address burnRouter,
        address layer,
        address weth,
        PoolKey memory canonicalKey,
        address deployer
    ) internal view returns (bool initializeBurnRouter) {
        BurnRouter router = BurnRouter(payable(burnRouter));
        if (!router.initialized()) {
            require(
                router.owner() == deployer, "BurnRouter must be initialized or signer must own it"
            );
            return true;
        }
        _verifyBurnRouterInitialized(burnRouter, layer, weth, canonicalKey);
        return false;
    }

    function _verifyBurnRouterInitialized(
        address burnRouter,
        address layer,
        address weth,
        PoolKey memory canonicalKey
    ) internal view {
        BurnRouter router = BurnRouter(payable(burnRouter));
        require(router.initialized(), "BurnRouter not initialized");
        require(router.layerToken() == layer, "BurnRouter LAYER mismatch");
        require(router.weth() == weth, "BurnRouter WETH mismatch");
        require(
            _samePoolKey(_burnRouterPoolKey(router), canonicalKey), "BurnRouter pool key mismatch"
        );
    }

    function _burnRouterPoolKey(BurnRouter router) internal view returns (PoolKey memory key) {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            router.canonicalPoolKey();
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    function _samePoolKey(PoolKey memory a, PoolKey memory b) internal pure returns (bool) {
        return Currency.unwrap(a.currency0) == Currency.unwrap(b.currency0)
            && Currency.unwrap(a.currency1) == Currency.unwrap(b.currency1) && a.fee == b.fee
            && a.tickSpacing == b.tickSpacing && address(a.hooks) == address(b.hooks);
    }

    function _verifyAllocation(address layer, ArtCoinsFactory factory, int24 startingTick)
        internal
        view
    {
        ArtCoinsToken token = ArtCoinsToken(layer);
        uint256 totalSupply = token.totalSupply();
        require(
            totalSupply == EXPECTED_TOTAL_SUPPLY_POST_BURN,
            "totalSupply mismatch (burn did not execute)"
        );

        // Allocation reconciliation: 1B initial − 260.2M burn − 100M airdrop − 639.8M LP = 0.
        // (Burn already removed; remaining 739.8M = 100M airdrop pool + 639.8M LP.)
        require(
            uint256(BURN_EXTENSION_BPS) + uint256(AIRDROP_EXTENSION_BPS)
                    + ((EXPECTED_LP_ALLOCATION * 10_000) / TOTAL_SUPPLY) == 10_000,
            "Allocation does not sum to 100% (unallocated supply > 0)"
        );
        require(EXPECTED_BURN_AMOUNT == 260_200_000e18, "Burn amount drifted");
        require(EXPECTED_CLAIM_POOL == 100_000_000e18, "Claim pool drifted");
        require(EXPECTED_LP_ALLOCATION == 639_800_000e18, "LP allocation drifted");

        // LP shape: must be the 12-position thin-floor taper at the
        // expected tick boundaries, summing to exactly LP_ALLOCATION.
        _verifyLpShape(startingTick);

        // Sanity: factory snapshot view confirms recipient at deploy time.
        IArtCoinsFactory.DeploymentInfo memory info = factory.tokenDeploymentInfo(layer);
        require(info.token == layer, "factory deploymentInfo mismatch");
        require(info.locker != address(0), "factory deploymentInfo locker missing");
    }

    /// @dev Reproduces the LP shape arrays that this launch will pass to the
    ///      factory and asserts they match the 12-position Preset L spec
    ///      exactly. Caught at script time, before broadcast, so a regression
    ///      in `LaunchDefaults` never silently changes the launch shape.
    function _verifyLpShape(int24 startingTick) internal pure {
        (int24[] memory tl, int24[] memory tu, uint16[] memory bps) =
            LaunchDefaults.buildLayerThinFloor12Positions(startingTick);

        require(tl.length == EXPECTED_LP_POSITIONS, "LP positions != 12");
        require(tu.length == EXPECTED_LP_POSITIONS, "LP positions tu mismatch");
        require(bps.length == EXPECTED_LP_POSITIONS, "LP positions bps mismatch");

        // Boundary ticks.
        require(tl[0] == EXPECTED_LP_LOWEST_TICK, "LP first tickLower mismatch");
        require(tu[11] == EXPECTED_LP_HIGHEST_TICK, "LP last tickUpper mismatch");
        require(
            uint256(int256(tu[11] - tl[0])) == EXPECTED_LP_TICK_WIDTH, "LP total width != 60000"
        );

        // bps sums to 10000 + LAYER amounts sum to LP_ALLOCATION.
        uint256 bpsSum = 0;
        uint256 layerSum = 0;
        for (uint256 i = 0; i < EXPECTED_LP_POSITIONS; i++) {
            bpsSum += bps[i];
            layerSum += (EXPECTED_LP_ALLOCATION * bps[i]) / 10_000;
            // Each tick aligned to spacing.
            require(tl[i] % LaunchDefaults.TICK_SPACING == 0, "tickLower not aligned");
            require(tu[i] % LaunchDefaults.TICK_SPACING == 0, "tickUpper not aligned");
            // Contiguous, non-overlapping.
            if (i > 0) require(tl[i] == tu[i - 1], "LP positions not contiguous");
            // Single-sided LAYER: every position must start at or above the
            // pool's starting tick — guarantees no WETH seed is required.
            require(tl[i] >= startingTick, "Position requires WETH seed");
        }
        require(bpsSum == 10_000, "LP bps sum != 10000");
        // Allow a few wei of dust from integer division.
        require(
            layerSum >= EXPECTED_LP_ALLOCATION - 100 && layerSum <= EXPECTED_LP_ALLOCATION,
            "LP LAYER sum != 639,800,000"
        );
    }

    /// @dev Hard preflight after broadcast: confirm the per-pool sniper-fee
    ///      recipient was set to the BurnRouter and the slot was locked.
    ///      Together with the `protocolFeeNumerator == 0` check above, this
    ///      pins the routing for the lifetime of the pool.
    function _verifySniperWiring(address hook, PoolKey memory canonicalKey, address burnRouter)
        internal
        view
    {
        IArtCoinsHookSniperView h = IArtCoinsHookSniperView(hook);
        PoolId pid = _poolIdOf(canonicalKey);
        require(h.sniperFeeRecipient(pid) == burnRouter, "sniperFeeRecipient must be BurnRouter");
        require(h.sniperFeeRecipientLocked(pid), "sniperFeeRecipient slot must be locked");
    }

    function _poolIdOf(PoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }

    function _printReport(
        address layer,
        ArtCoinsFactory factory,
        address hook,
        address locker,
        address mevSniperStepped,
        address airdrop,
        address burnExtension,
        address llCounter,
        address llRenderer,
        address weth,
        address protocolFeeController,
        address burnRouter,
        int24 startingTick
    ) internal view {
        ArtCoinsToken token = ArtCoinsToken(layer);
        // (deploymentInfo lookup retained as a side-effect sanity check)
        factory.tokenDeploymentInfo(layer);
        console2.log("");
        console2.log("=== LAUNCH REPORT ===");
        console2.log("LAYER token:               ", layer);
        console2.log("Pool hook:                 ", hook);
        console2.log("Locker:                    ", locker);
        console2.log("MEV (sniper-stepped):      ", mevSniperStepped);
        console2.log("Airdrop ext:               ", airdrop);
        console2.log("Burn ext:                  ", burnExtension);
        console2.log("LL counter ext:            ", llCounter);
        console2.log("LL renderer:               ", llRenderer);
        console2.log("WETH:                      ", weth);
        console2.log("ProtocolFeeController:     ", protocolFeeController);
        console2.log("BurnRouter:                ", burnRouter);
        console2.log("LiquiditySupportReceiver:  not used by LAYER (0%)");
        console2.log("");
        console2.log("Initial supply:            ", TOTAL_SUPPLY);
        console2.log("Initial burned:            ", EXPECTED_BURN_AMOUNT);
        console2.log("Migrator claim pool:       ", EXPECTED_CLAIM_POOL);
        console2.log("LP allocation:             ", EXPECTED_LP_ALLOCATION);
        console2.log("WETH seed:                 0");
        console2.log("Current totalSupply:       ", token.totalSupply());
        console2.log("");
        console2.log("Total trading fee:         1.00%");
        console2.log("Protocol share (fixed):    20% of fee  (0.20% of volume)");
        console2.log("  artcoins treasury:       12% of fee  (0.12% of volume)");
        console2.log("  protocol-side burn:       8% of fee  (0.08% of volume)");
        console2.log("Project share:             80% of fee  (0.80% of volume)");
        console2.log("  artist treasury:         38% of fee  (0.38% of volume)");
        console2.log("  project-side burn:       42% of fee  (0.42% of volume)");
        console2.log("  liquidity support:        0% of fee  (0.00% of volume)");
        console2.log("Effective LAYER buy/burn:  0.50% of volume (project + protocol)");
        console2.log("Effective treasury:        0.50% of volume (artist + protocol-treasury)");
        console2.log("");
        console2.log("Anti-sniper (sniper-stepped, 15m):");
        console2.log("  0-1m:    50%  (1% base + 49% extra)");
        console2.log("  1-3m:    25%  (1% base + 24% extra)");
        console2.log("  3-5m:    15%  (1% base + 14% extra)");
        console2.log("  5-10m:    7%  (1% base +  6% extra)");
        console2.log("  10-15m:   3%  (1% base +  2% extra)");
        console2.log("  15m+:     1%  (base only)");
        console2.log("Routing for the 1% base portion (every swap):");
        console2.log("  artist treasury:           38%  (0.38% of volume)");
        console2.log("  project-side burn:         42%  (0.42% of volume)");
        console2.log("  protocol-side treasury:    12%  (0.12% of volume)");
        console2.log("  protocol-side burn:         8%  (0.08% of volume)");
        console2.log("Routing for the EXTRA portion (sniper window only):");
        console2.log("  100%% to BurnRouter -> LAYER buy-and-burn (no artist or treasury share)");
        console2.log("");
        console2.log("Starting tick:             ", startingTick);
        console2.log("Tick spacing:              ", LaunchDefaults.TICK_SPACING);
        console2.log("Merkle root (claims):      ");
        console2.logBytes32(MERKLE_ROOT);
        console2.log("");
        console2.log("Pool URL: https://app.uniswap.org/explore/tokens/ethereum/", layer);
    }

    function _requireNonZero(address a, string memory name) internal pure {
        if (a == address(0)) revert(string(abi.encodePacked("Required addr unset: ", name)));
    }
}
