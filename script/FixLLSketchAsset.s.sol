// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {IScriptyStorageV2} from "../src/interfaces/IScripty.sol";

/// @title FixLLSketchAsset
/// @notice One-off ops script. ScriptyStorageV2 has no truncate/delete, and
///         the existing `ll/sketch.v1` slot is corrupt (a stale base64-prefix
///         was merged with a raw-bytes tail by a buggy earlier deploy). We:
///           1. upload `Base64.encode(sketch.js)` under a fresh name
///              `ll/sketch.v2` (correctly pre-encoded for ScriptyBuilderV2's
///              `tagType:2`, which emits storage content verbatim);
///           2. call `renderer.setSketchScriptName("ll/sketch.v2")` so every
///              token already pointing at the renderer picks up the fix.
///
/// Required env vars:
///   PRIVATE_KEY         Deployer / renderer owner.
///   LL_RENDERER         Address of the deployed LiquidityLayerOnchainRenderer.
///   SCRIPTY_STORAGE     ScriptyStorageV2 address (canonical 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699).
///
/// Optional env vars:
///   LL_SKETCH_PATH      Defaults to script-js/data/ll/sketch.js
///   LL_SKETCH_NAME_NEW  Defaults to ll/sketch.b64.<unix-time-of-this-run>.
///                       Timestamp suffix avoids collisions with stale slots
///                       from prior deploys (ScriptyStorage has no truncate).
contract FixLLSketchAsset is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address rendererAddr = vm.envAddress("LL_RENDERER");
        address storageAddr = vm.envAddress("SCRIPTY_STORAGE");

        string memory sketchPath = _envOrString("LL_SKETCH_PATH", "script-js/data/ll/sketch.js");
        string memory newName = _envOrString(
            "LL_SKETCH_NAME_NEW", string.concat("ll/sketch.b64.", vm.toString(vm.unixTime()))
        );

        bytes memory raw = vm.readFileBinary(sketchPath);
        bytes memory encoded = bytes(Base64.encode(raw));

        console2.log("=== Fix LL sketch asset ===");
        console2.log("Renderer:           ", rendererAddr);
        console2.log("ScriptyStorage:     ", storageAddr);
        console2.log("New asset name:     ", newName);
        console2.log("sketch.js raw size: ", raw.length);
        console2.log("base64 size:        ", encoded.length);

        IScriptyStorageV2 scripty = IScriptyStorageV2(storageAddr);
        LiquidityLayerOnchainRenderer renderer = LiquidityLayerOnchainRenderer(rendererAddr);

        bytes memory existing = scripty.getContent(newName, "");
        if (keccak256(existing) == keccak256(encoded)) {
            console2.log("Content already matches; skipping upload.");
        } else if (existing.length != 0) {
            revert(
                string.concat(
                    "asset name '",
                    newName,
                    "' already populated with non-matching bytes; bump LL_SKETCH_NAME_NEW"
                )
            );
        } else {
            vm.startBroadcast(pk);
            try scripty.createContent(newName, "") {} catch {}
            scripty.addChunkToContent(newName, encoded);
            vm.stopBroadcast();
            console2.log("Uploaded base64(sketch.js).");
        }

        // Repoint the renderer.
        if (keccak256(bytes(renderer.sketchScriptName())) == keccak256(bytes(newName))) {
            console2.log("Renderer already points at the new name; nothing to do.");
        } else {
            vm.startBroadcast(pk);
            renderer.setSketchScriptName(newName);
            vm.stopBroadcast();
            console2.log("Renderer.sketchScriptName = ", newName);
        }

        console2.log("");
        console2.log("Done. Verify with:");
        console2.log("  cast call $LL_RENDERER 'sketchScriptName()(string)' --rpc-url $RPC");
        console2.log(
            "  cast call $LL_RENDERER 'contractURI(address)(string)' <token> --rpc-url $RPC"
        );
    }

    function _envOrString(string memory key, string memory fallbackValue)
        internal
        view
        returns (string memory)
    {
        try vm.envString(key) returns (string memory v) {
            if (bytes(v).length == 0) return fallbackValue;
            return v;
        } catch {
            return fallbackValue;
        }
    }
}
