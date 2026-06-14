// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {IScriptyStorageV2} from "../src/interfaces/IScripty.sol";

/// @notice Upload a new Mona Lisa asset into ScriptyStorageV2 and point the
///         renderer at it. Used to swap the canvas backdrop without
///         redeploying the renderer or re-uploading the sketch / history.
///
/// Required env:
///     PRIVATE_KEY      deployer + scripty content owner + renderer owner
///     RENDERER         deployed LiquidityLayerOnchainRenderer
///     MONA_NEW_NAME    fresh scripty content name (e.g. "ll/mona.v2")
///     MONA_NEW_MIME    e.g. "image/webp"
///     MONA_NEW_PATH    filesystem path to the raw image bytes
///
/// Idempotent on scripty (createContent reverts if name taken; we catch and
/// continue to addChunk; addChunk reverts NotContentOwner if owned by someone
/// else, in which case bump MONA_NEW_NAME).
contract SwapMonaAsset is Script {
    address constant SCRIPTY_STORAGE = 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        LiquidityLayerOnchainRenderer renderer =
            LiquidityLayerOnchainRenderer(vm.envAddress("RENDERER"));
        string memory name = vm.envString("MONA_NEW_NAME");
        string memory mime = vm.envString("MONA_NEW_MIME");
        bytes memory data = vm.readFileBinary(vm.envString("MONA_NEW_PATH"));

        console2.log("=== Swap Mona Lisa asset ===");
        console2.log("Renderer:", address(renderer));
        console2.log("New name:", name);
        console2.log("New MIME:", mime);
        console2.log("Bytes:   ", data.length);

        IScriptyStorageV2 storage_ = IScriptyStorageV2(SCRIPTY_STORAGE);

        vm.startBroadcast(pk);

        bytes memory existing = storage_.getContent(name, "");
        if (keccak256(existing) == keccak256(data)) {
            console2.log("  [skip]  scripty content already matches");
        } else if (existing.length == 0) {
            try storage_.createContent(name, "") {
                console2.log("  [new]   createContent");
            } catch {
                console2.log("  [exists] createContent reverted; continuing to addChunk");
            }
            storage_.addChunkToContent(name, data);
            console2.log("  [chunk] uploaded", data.length, "bytes");
        } else {
            console2.log(
                "  [abort] existing content differs from local artifact; bump MONA_NEW_NAME"
            );
            revert("content mismatch");
        }

        renderer.setMonaAsset(name, mime);
        console2.log("  [ok]    setMonaAsset");

        vm.stopBroadcast();
    }
}
