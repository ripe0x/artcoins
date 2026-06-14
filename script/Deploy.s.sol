// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {ArtCoinsAirdrop} from "../src/extensions/ArtCoinsAirdrop.sol";
import {ArtCoinsUniv4EthDevBuy} from "../src/extensions/ArtCoinsUniv4EthDevBuy.sol";
import {ArtCoinsVault} from "../src/extensions/ArtCoinsVault.sol";
import {BurnExtension} from "../src/extensions/BurnExtension.sol";
import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsHookStaticFeeV2} from "../src/hooks/legacy/ArtCoinsHookStaticFeeV2.sol";
import {IScriptyBuilderV2, IScriptyStorageV2} from "../src/interfaces/IScripty.sol";
import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {ArtCoinsFeeLocker} from "../src/legacy/ArtCoinsFeeLocker.sol";
import {ArtCoinsLpLockerMultiple} from "../src/lp-lockers/legacy/ArtCoinsLpLockerMultiple.sol";
import {ArtCoinsMevDescendingFees} from "../src/mev-modules/ArtCoinsMevDescendingFees.sol";
import {ArtCoinsMevLinearFees} from "../src/mev-modules/ArtCoinsMevLinearFees.sol";
import {ArtCoinsMevSniperSteppedFees} from "../src/mev-modules/ArtCoinsMevSniperSteppedFees.sol";
import {ArtCoinsMevTimeDelay} from "../src/mev-modules/ArtCoinsMevTimeDelay.sol";
import {DefaultMetadataRenderer} from "../src/renderer/DefaultMetadataRenderer.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Full stack deployment for ArtCoins token launcher
/// @dev Supports ETH mainnet and Sepolia. Auto-detects chain.
///
///   Sepolia:  forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL \
///                 --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvv
///   Mainnet:  forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL \
///                 --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvv
///
/// `--verify` is mandatory. The token implementation + factory are the
/// trust roots of the protocol — if they ship unverified, every token
/// deployed against them is suspicious. If a verification call fails for
/// any contract (rate limit, transient API error), re-run
/// `script/verify-sepolia.sh` (or its mainnet sibling) to retry —
/// `forge verify-contract` is idempotent.
contract DeployScript is Script {
    // ETH Mainnet
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant MAINNET_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant MAINNET_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    // Sepolia
    address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant SEPOLIA_POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant SEPOLIA_UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;

    // Shared
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant SCRIPTY_BUILDER = 0xD7587F110E08F4D120A231bA97d3B577A81Df022;
    address constant SCRIPTY_STORAGE = 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699;
    uint256 constant LAYER_INITIAL_SUPPLY = 1_000_000_000e18;

    struct Network {
        address poolManager;
        address positionManager;
        address weth;
        address universalRouter;
        string name;
    }

    /// @notice Bag of every address produced by `deployStack`. Returned to the
    ///         caller (either `run()` for logging, or a test contract for the
    ///         launch-day rehearsal).
    struct Stack {
        address feeLocker;
        address factory;
        address poolExtAllowlist;
        address hook;
        address lpLocker;
        address mevTimeDelay;
        address mevDescFees;
        address mevLinearFees;
        address mevSniperStepped;
        address vault;
        address airdrop;
        address burnExtension;
        address devBuy;
        address renderer;
        address llCounter;
        address llRenderer;
    }

    function _getNetwork() internal view returns (Network memory) {
        if (block.chainid == 1) {
            return Network(
                MAINNET_POOL_MANAGER,
                MAINNET_POSITION_MANAGER,
                MAINNET_WETH,
                MAINNET_UNIVERSAL_ROUTER,
                "ETH Mainnet"
            );
        } else if (block.chainid == 11_155_111) {
            return Network(
                SEPOLIA_POOL_MANAGER,
                SEPOLIA_POSITION_MANAGER,
                SEPOLIA_WETH,
                SEPOLIA_UNIVERSAL_ROUTER,
                "Sepolia"
            );
        } else {
            revert("Unsupported chain. Use mainnet (1) or Sepolia (11155111)");
        }
    }

    /// @notice Deploys the full ArtCoins stack as `deployer` and returns every
    ///         address. Caller is responsible for `vm.startBroadcast(deployer)`
    ///         before calling and `vm.stopBroadcast()` after — this lets
    ///         `run()` use the script-mode broadcast (which rewrites
    ///         `new {salt}` to CREATE2_DEPLOYER) and lets the rehearsal test
    ///         broadcast as a synthetic deployer for an end-to-end fork run.
    function deployStack(address deployer) public returns (Stack memory s) {
        Network memory net = _getNetwork();

        // --- Pre-compute addresses for hook mining ---
        //
        // The hook must be deployed at an address whose bottom 14 bits encode
        // which V4 callbacks it uses. We use CREATE2 + HookMiner to find a salt.
        // But the hook constructor needs factory & poolExtAllowlist addresses,
        // which haven't been deployed yet. We predict them from deployer nonce.

        uint64 nonce = vm.getNonce(deployer);
        // nonce+0 = feeLocker
        // nonce+1 = factory
        // nonce+2 = factory.setTeamFeeRecipient (tx)
        // nonce+3 = poolExtAllowlist
        address predictedFactory = vm.computeCreateAddress(deployer, nonce + 1);
        address predictedPoolExtAllowlist = vm.computeCreateAddress(deployer, nonce + 3);

        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs =
            abi.encode(net.poolManager, predictedFactory, predictedPoolExtAllowlist, net.weth);

        (address hookAddress, bytes32 hookSalt) = HookMiner.find(
            CREATE2_DEPLOYER, hookFlags, type(ArtCoinsHookStaticFeeV2).creationCode, constructorArgs
        );

        // --- Deploy everything (caller already opened a broadcast/prank window) ---

        // 1. Core
        ArtCoinsFeeLocker feeLocker = new ArtCoinsFeeLocker(deployer);
        ArtCoinsFactory factory = new ArtCoinsFactory(deployer);
        require(address(factory) == predictedFactory, "Factory address mismatch");

        factory.setTeamFeeRecipient(deployer);

        // 2. Hook
        ArtCoinsPoolExtensionAllowlist poolExtAllowlist =
            new ArtCoinsPoolExtensionAllowlist(deployer);
        require(address(poolExtAllowlist) == predictedPoolExtAllowlist, "PoolExt address mismatch");

        ArtCoinsHookStaticFeeV2 hook = new ArtCoinsHookStaticFeeV2{salt: hookSalt}(
            net.poolManager, address(factory), address(poolExtAllowlist), net.weth
        );
        require(address(hook) == hookAddress, "Hook address mismatch");
        // Defense in depth: artcoins v1 routes the protocol's share through
        // the locker's factory-injected protocol reward slot, NOT through a
        // hook-level skim on top of the pool fee. The hook source already
        // defaults `protocolFeeNumerator` to 0, but assert here so any future
        // change to the source default is caught at deploy time.
        require(
            hook.protocolFeeNumerator() == 0,
            "Hook protocolFeeNumerator must be 0 for artcoins v1 (trader pays exactly pool fee)"
        );

        // 3. LP Locker
        ArtCoinsLpLockerMultiple lpLocker = new ArtCoinsLpLockerMultiple(
            deployer, address(factory), address(feeLocker), net.positionManager, PERMIT2
        );

        // 4. MEV Modules
        ArtCoinsMevTimeDelay mevTimeDelay = new ArtCoinsMevTimeDelay(120);
        ArtCoinsMevDescendingFees mevDescFees = new ArtCoinsMevDescendingFees();
        ArtCoinsMevLinearFees mevLinearFees = new ArtCoinsMevLinearFees();
        ArtCoinsMevSniperSteppedFees mevSniperStepped = new ArtCoinsMevSniperSteppedFees();

        // 5. Extensions
        ArtCoinsVault vault = new ArtCoinsVault(address(factory));
        ArtCoinsAirdrop airdrop = new ArtCoinsAirdrop(address(factory));
        BurnExtension burnExtension = new BurnExtension(address(factory));
        ArtCoinsUniv4EthDevBuy devBuy =
            new ArtCoinsUniv4EthDevBuy(address(factory), net.weth, net.universalRouter, PERMIT2);

        // 6. Renderers + LAYER pool counter
        DefaultMetadataRenderer renderer = new DefaultMetadataRenderer();
        LiquidityLayerCounterPoolExtension llCounter =
            new LiquidityLayerCounterPoolExtension(address(hook));
        LiquidityLayerOnchainRenderer llRenderer =
            _deployLiquidityLayerRenderer(deployer, llCounter);

        // 7. Wire everything together
        factory.setHook(address(hook), true);
        factory.setLocker(address(lpLocker), address(hook), true);
        factory.setMevModule(address(mevTimeDelay), true);
        factory.setMevModule(address(mevDescFees), true);
        factory.setMevModule(address(mevLinearFees), true);
        factory.setMevModule(address(mevSniperStepped), true);
        factory.setExtension(address(vault), true);
        factory.setExtension(address(airdrop), true);
        factory.setExtension(address(burnExtension), true);
        factory.setExtension(address(devBuy), true);
        poolExtAllowlist.setPoolExtension(address(llCounter), true);
        feeLocker.addDepositor(address(lpLocker));
        // artcoins v1 launches with no factory-level deploy fee. The
        // factory's source default is 0.069 ETH (a Clanker convention) but
        // we override here so every deploy — LAYER and any future artcoin
        // — costs the deployer only gas. MainnetLaunchRehearsalForkTest
        // models this same override; keeping production aligned with the
        // rehearsal closes the obvious surprise (0.069 ETH leaving the
        // deployer wallet at LaunchLayer time, landing in the
        // ProtocolFeeController).
        factory.setDeployFee(0);
        // Leave public deploys disabled after stack deployment. Owner/admin
        // callers can still deploy while the factory is deprecated, which lets
        // LAYER launch before the factory is opened to the public.

        s.feeLocker = address(feeLocker);
        s.factory = address(factory);
        s.poolExtAllowlist = address(poolExtAllowlist);
        s.hook = address(hook);
        s.lpLocker = address(lpLocker);
        s.mevTimeDelay = address(mevTimeDelay);
        s.mevDescFees = address(mevDescFees);
        s.mevLinearFees = address(mevLinearFees);
        s.mevSniperStepped = address(mevSniperStepped);
        s.vault = address(vault);
        s.airdrop = address(airdrop);
        s.burnExtension = address(burnExtension);
        s.devBuy = address(devBuy);
        s.renderer = address(renderer);
        s.llCounter = address(llCounter);
        s.llRenderer = address(llRenderer);
    }

    function _deployLiquidityLayerRenderer(
        address deployer,
        LiquidityLayerCounterPoolExtension llCounter
    ) internal returns (LiquidityLayerOnchainRenderer renderer) {
        // Asset names get a unix-timestamp suffix by default (instead of
        // `v1` / `v2` / ... incrementing) so re-uploads of changed source
        // can't collide with stale slots from previous deploys. ScriptyStorage
        // has no truncate; once a name has bytes you can never overwrite it,
        // and accidentally re-using a slot that has different (possibly
        // corrupt) bytes is the bug we just fixed. Timestamp-suffixed names
        // make every fresh asset upload a guaranteed-empty slot. Operators
        // who want a fixed name across runs override via env vars.
        //
        // The `.b64` infix is mandatory for the sketch (and history): scripty's
        // `tagType: 2` emits the storage bytes VERBATIM into a
        // `data:text/javascript;base64,...` URI, so the bytes MUST be pre-
        // base64-encoded.
        string memory ts = vm.toString(vm.unixTime());
        string memory sketchName =
            _envOrString("LL_SKETCH_NAME", string.concat("ll/sketch.b64.", ts));
        string memory monaName = _envOrString("LL_MONA_NAME", string.concat("ll/mona.", ts));
        string memory monaMime = _envOrString("LL_MONA_MIME", "image/jpeg");
        string memory description =
            _envOrString("LL_DESCRIPTION", "Until nothing remains but speculation");
        string memory sketchPath = _envOrString("LL_SKETCH_PATH", "script-js/data/ll/sketch.js");
        string memory monaPath = _envOrString("LL_MONA_PATH", "script-js/data/ll/mona.jpeg");
        string memory historyName =
            _envOrString("LL_HISTORY_NAME", string.concat("ll/history.b64.", ts));
        string memory historyPath =
            _envOrString("LL_HISTORY_PATH", "script-js/data/ll/history.v1.bin");

        console2.log("LL renderer asset names:");
        console2.log("  sketch:  ", sketchName);
        console2.log("  mona:    ", monaName);
        console2.log("  history: ", historyName);

        IScriptyStorageV2 storageContract = IScriptyStorageV2(SCRIPTY_STORAGE);
        // The sketch is consumed by ScriptyBuilderV2 with `tagType: 2`
        // (`scriptBase64DataURI`). That tagType emits storage content VERBATIM
        // between `<script src="data:text/javascript;base64,` and `"></script>`,
        // so the bytes in storage MUST already be base64-encoded — otherwise
        // the resulting data URI is malformed and the iframe can't load the
        // script.
        _ensureContent(
            storageContract, sketchName, bytes(Base64.encode(vm.readFileBinary(sketchPath)))
        );
        // Mona is fetched raw by the renderer and base64-encoded inside
        // `_buildAnimationHtml` for the assetShim inline script — keep it raw.
        _ensureContent(storageContract, monaName, vm.readFileBinary(monaPath));

        renderer = new LiquidityLayerOnchainRenderer(
            deployer,
            llCounter,
            IScriptyBuilderV2(SCRIPTY_BUILDER),
            storageContract,
            sketchName,
            monaName,
            monaMime,
            description
        );
        renderer.setSupplyConfig(LAYER_INITIAL_SUPPLY, 18);

        // Optional IPFS / HTTPS URI for the JSON `image` field. When set,
        // the renderer returns this verbatim as the metadata image instead
        // of the on-chain Mona Lisa data URI fallback. Marketplaces show
        // the IPFS thumbnail; the animation iframe still uses the on-chain
        // Mona for its canvas (kept self-contained, no network for the
        // interactive view).
        string memory imageOverrideUri = _envOrString("LL_IMAGE_URI", "");
        if (bytes(imageOverrideUri).length > 0) {
            renderer.setImageOverrideUri(imageOverrideUri);
            console2.log("  imageURI:", imageOverrideUri);
        }

        if (bytes(historyName).length > 0) {
            // History is also a tagType-2-consumed asset elsewhere in the
            // renderer pipeline: store as base64.
            _ensureContent(
                storageContract, historyName, bytes(Base64.encode(vm.readFileBinary(historyPath)))
            );
            renderer.setHistoryAsset(historyName);
        }
    }

    function _envOrString(string memory key, string memory fallbackValue)
        internal
        view
        returns (string memory)
    {
        try vm.envString(key) returns (string memory value) {
            if (bytes(value).length == 0) return fallbackValue;
            return value;
        } catch {
            return fallbackValue;
        }
    }

    /// @dev Idempotently uploads `data` under `name` to ScriptyStorageV2.
    ///      ScriptyStorageV2 only supports append — there is no truncate or
    ///      delete — so we can only handle two cases safely:
    ///        (a) storage is empty → create + add the full data.
    ///        (b) storage already equals `data` exactly → no-op.
    ///      Any other state (existing content present but not equal to `data`,
    ///      or a strict-prefix mismatch) means the on-chain content can't be
    ///      converged to the new `data` without using a fresh `name`. Rather
    ///      than try a "tail diff" merge — which corrupts storage when the
    ///      old content is structurally different (e.g. raw vs base64-encoded
    ///      versions of the same source) — we revert with a clear message
    ///      instructing the operator to bump the asset name.
    function _ensureContent(
        IScriptyStorageV2 storageContract,
        string memory name,
        bytes memory data
    ) internal {
        bytes memory existing = storageContract.getContent(name, "");
        if (keccak256(existing) == keccak256(data)) return; // already matches
        if (existing.length != 0) {
            revert(
                string.concat(
                    "scripty content for '",
                    name,
                    "' is non-empty and does not match local artifact; bump the asset name (e.g. v1->v2) since ScriptyStorage cannot truncate"
                )
            );
        }
        try storageContract.createContent(name, "") {} catch {}
        // ScriptyStorageV2 stores each chunk via SSTORE2-style contract
        // creation, so a single chunk is bounded by EIP-170 (24_576 bytes).
        // We split anything larger into 20KB pieces — well below the cap and
        // a comfortable margin under the 30M-gas Sepolia block limit per tx.
        uint256 CHUNK_SIZE = 20_000;
        if (data.length <= CHUNK_SIZE) {
            storageContract.addChunkToContent(name, data);
        } else {
            uint256 offset = 0;
            while (offset < data.length) {
                uint256 size = data.length - offset;
                if (size > CHUNK_SIZE) size = CHUNK_SIZE;
                bytes memory chunk = new bytes(size);
                for (uint256 j = 0; j < size; j++) {
                    chunk[j] = data[offset + j];
                }
                storageContract.addChunkToContent(name, chunk);
                offset += size;
            }
        }
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        Network memory net = _getNetwork();

        console2.log("=== ArtCoins Full Stack Deploy ===");
        console2.log("Network:  ", net.name);
        console2.log("Chain ID: ", block.chainid);
        console2.log("Deployer: ", deployer);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);
        Stack memory s = deployStack(deployer);
        vm.stopBroadcast();

        console2.log("[1] FeeLocker:              ", s.feeLocker);
        console2.log("[2] Factory:                ", s.factory);
        console2.log("[3] PoolExtAllowlist:       ", s.poolExtAllowlist);
        console2.log("[4] Hook:                   ", s.hook);
        console2.log("[5] LpLocker:               ", s.lpLocker);
        console2.log("[6] MevTimeDelay:           ", s.mevTimeDelay);
        console2.log("[7] MevDescendingFees:      ", s.mevDescFees);
        console2.log("[8] MevLinearFees:          ", s.mevLinearFees);
        console2.log("[8b] MevSniperSteppedFees:  ", s.mevSniperStepped);
        console2.log("[9] Vault:                  ", s.vault);
        console2.log("[10] AirdropV2:             ", s.airdrop);
        console2.log("[11] BurnExtension:         ", s.burnExtension);
        console2.log("[12] DevBuy:                ", s.devBuy);
        console2.log("[13] DefaultRenderer:       ", s.renderer);
        console2.log("[14] LLCounter:             ", s.llCounter);
        console2.log("[15] LLOnchainRenderer:     ", s.llRenderer);
        console2.log("[16-21] All modules wired; public deploys remain disabled");

        console2.log("");
        console2.log("========================================");
        console2.log("  DEPLOYMENT COMPLETE - READY FOR ADMIN LAUNCH");
        console2.log("========================================");
        console2.log("");
        console2.log("Core:");
        console2.log("  FeeLocker:          ", s.feeLocker);
        console2.log("  Factory:            ", s.factory);
        console2.log("");
        console2.log("Hook:");
        console2.log("  PoolExtAllowlist:   ", s.poolExtAllowlist);
        console2.log("  Hook (StaticFeeV2): ", s.hook);
        console2.log("");
        console2.log("LP Locker:");
        console2.log("  LpLockerMultiple:   ", s.lpLocker);
        console2.log("");
        console2.log("MEV Modules:");
        console2.log("  TimeDelay (120s):   ", s.mevTimeDelay);
        console2.log("  DescendingFees:     ", s.mevDescFees);
        console2.log("  LinearFees (69min): ", s.mevLinearFees);
        console2.log("  SniperSteppedFees:  ", s.mevSniperStepped);
        console2.log("");
        console2.log("Extensions:");
        console2.log("  Vault:              ", s.vault);
        console2.log("  AirdropV2:          ", s.airdrop);
        console2.log("  BurnExtension:      ", s.burnExtension);
        console2.log("  DevBuy:             ", s.devBuy);
        console2.log("");
        console2.log("Renderer:");
        console2.log("  Default:            ", s.renderer);
        console2.log("  LL Counter:         ", s.llCounter);
        console2.log("  LL Onchain:         ", s.llRenderer);
    }
}
