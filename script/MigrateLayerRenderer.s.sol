// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// targets superseded stack legacy (LAYER); current stack is 0x4959… (Addresses.CURRENT_FACTORY).
// Mainnet runs are refused unless ALLOW_SUPERSEDED=1.

import {Script, console2} from "forge-std/Script.sol";

import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {IScriptyBuilderV2, IScriptyStorageV2} from "../src/interfaces/IScripty.sol";

import {Addresses} from "./Addresses.sol";

interface IRenderableToken {
    function setMetadataRenderer(address) external;
    function metadataRenderer() external view returns (address);
}

/// @title  MigrateLayerRenderer
/// @notice Phase 3 of the LAYER counter fix. Deploys a new
///         `LiquidityLayerOnchainRenderer` pointing at the new auto-forward
///         extension, mirrors the existing renderer's settings, and switches
///         LAYER's metadata pointer to the new renderer.
///
/// Usage:
///   # Dry run on a fork:
///   NEW_EXTENSION=0x... forge script script/MigrateLayerRenderer.s.sol \
///     --fork-url $MAINNET_RPC_URL --sender 0xCB43078C32423F5348Cab5885911C3B5faE217F9 -vvv
///
///   # Mainnet broadcast:
///   NEW_EXTENSION=0x... forge script script/MigrateLayerRenderer.s.sol \
///     --rpc-url $MAINNET_RPC_URL --broadcast --account <name> -vvv
///
/// `NEW_EXTENSION` is the address output by `SetUpLayerAutoForward.s.sol`.
contract MigrateLayerRenderer is Script {
    address constant LAYER = Addresses.COIN_LAYER;

    // Scripty addresses as used by the live LAYER renderer (Addresses.LEGACY_LL_RENDERER).
    address constant SCRIPTY_BUILDER = Addresses.SCRIPTY_BUILDER;
    address constant SCRIPTY_STORAGE = Addresses.SCRIPTY_STORAGE;

    string constant SKETCH_SCRIPT = "ll/sketch.b64.1778120217836";
    string constant MONA_ASSET = "ll/mona.1778120217836";
    string constant MONA_MIME = "image/jpeg";
    string constant HISTORY_ASSET = "ll/history.b64.1778120217836";
    string constant PROJECT_DESCRIPTION = "Until nothing remains but speculation";
    string constant IMAGE_OVERRIDE =
        "ipfs://bafkreiguuln4aa23vdrsx53ashjqxcrst2oms7mow2bu7u2axvncmkikiu";

    uint256 constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint8 constant DECIMALS = 18;

    /// @dev Drives the legacy stack (LAYER). On mainnet it refuses to run unless ALLOW_SUPERSEDED=1.
    function _requireSupersededAllowed() internal view {
        if (block.chainid == Addresses.CHAIN_ID && vm.envOr("ALLOW_SUPERSEDED", uint256(0)) != 1) {
            revert("targets superseded stack legacy; set ALLOW_SUPERSEDED=1 to run on mainnet");
        }
    }

    function run() external {
        _requireSupersededAllowed();
        address newExtension = vm.envAddress("NEW_EXTENSION");
        require(newExtension != address(0), "NEW_EXTENSION env required");
        require(newExtension.code.length > 0, "NEW_EXTENSION has no code");

        address sender = msg.sender;

        console2.log("Pre-flight:");
        console2.log("  layer token        ", LAYER);
        console2.log("  current renderer   ", IRenderableToken(LAYER).metadataRenderer());
        console2.log("  new counter (ext)  ", newExtension);
        console2.log("  broadcaster        ", sender);

        vm.startBroadcast();

        // Deploy. Owner = sender (CB43, same as the existing renderer).
        LiquidityLayerOnchainRenderer renderer = new LiquidityLayerOnchainRenderer({
            initialOwner: sender,
            counter_: LiquidityLayerCounterPoolExtension(newExtension),
            scriptyBuilder_: IScriptyBuilderV2(SCRIPTY_BUILDER),
            scriptyStorage_: IScriptyStorageV2(SCRIPTY_STORAGE),
            sketchScriptName_: SKETCH_SCRIPT,
            monaAssetName_: MONA_ASSET,
            monaMimeType_: MONA_MIME,
            projectDescription_: PROJECT_DESCRIPTION
        });
        console2.log("Deployed renderer at", address(renderer));

        // Mirror post-deploy settings the existing renderer had.
        renderer.setHistoryAsset(HISTORY_ASSET);
        renderer.setImageOverrideUri(IMAGE_OVERRIDE);
        renderer.setSupplyConfig(INITIAL_SUPPLY, DECIMALS);

        // Repoint LAYER's renderer slot.
        IRenderableToken(LAYER).setMetadataRenderer(address(renderer));
        require(
            IRenderableToken(LAYER).metadataRenderer() == address(renderer), "renderer not bound"
        );
        console2.log("LAYER.metadataRenderer set");

        vm.stopBroadcast();

        console2.log("");
        console2.log("Done. New renderer:", address(renderer));
        console2.log(
            "Sanity check via cast: cast call",
            LAYER,
            " 'contractURI()(string)' --rpc-url $MAINNET_RPC_URL"
        );
    }
}
