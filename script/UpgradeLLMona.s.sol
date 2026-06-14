// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IScriptyStorageV2} from "../src/interfaces/IScripty.sol";

interface ILLRenderer {
    function setMonaAsset(string calldata name, string calldata mime) external;
    function setImageOverrideUri(string calldata uri) external;
    function owner() external view returns (address);
}

interface IArtCoinsToken {
    function updateImage(string calldata image_) external;
    function admin() external view returns (address);
}

/// @notice Uploads a higher-fidelity Mona Lisa JPEG/AVIF to ScriptyStorageV2
///         under a fresh asset name (chunked, since EIP-170 caps a single
///         scripty chunk at ~24KB), then points one or more LL renderers at it.
///
/// Required env:
///   PRIVATE_KEY           Renderer-owner key.
///   LL_MONA_PATH          Path to source image (relative to repo root).
///   LL_MONA_MIME          MIME type (e.g. image/jpeg, image/avif).
///   LL_MONA_NEW_NAME      Fresh scripty asset name (must not already exist
///                         with different content).
///   LL_RENDERERS          Comma-separated renderer addresses to repoint.
///
/// Optional env:
///   LL_IMAGE_URI          IPFS / HTTPS URI to set as the JSON `image` field on
///                         each renderer (and as `imageUrl` on each token in
///                         LL_TOKENS). Empty string clears the override.
///   LL_TOKENS             Comma-separated LAYER token addresses; the signer
///                         must be `admin()` on each. Calls `updateImage()`
///                         to keep `token.imageUrl()` in sync with the renderer
///                         override. Skipped if empty.
contract UpgradeLLMona is Script {
    address constant SCRIPTY_STORAGE = 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699;
    uint256 constant CHUNK_SIZE = 20_000; // safe under EIP-170 24KB cap

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory path = vm.envString("LL_MONA_PATH");
        string memory mime = vm.envString("LL_MONA_MIME");
        string memory newName = vm.envString("LL_MONA_NEW_NAME");
        address[] memory renderers = vm.envAddress("LL_RENDERERS", ",");
        string memory imageUri = vm.envOr("LL_IMAGE_URI", string(""));
        address[] memory tokens;
        try vm.envAddress("LL_TOKENS", ",") returns (address[] memory ts) {
            tokens = ts;
        } catch {
            tokens = new address[](0);
        }

        bytes memory data = vm.readFileBinary(path);
        IScriptyStorageV2 store = IScriptyStorageV2(SCRIPTY_STORAGE);

        console2.log("=== Upgrade LL Mona ===");
        console2.log("Path:        ", path);
        console2.log("MIME:        ", mime);
        console2.log("New name:    ", newName);
        console2.log("Bytes:       ", data.length);
        uint256 chunkCount = (data.length + CHUNK_SIZE - 1) / CHUNK_SIZE;
        console2.log("Chunks:      ", chunkCount);
        console2.log("Renderers:   ", renderers.length);

        bytes memory existing = store.getContent(newName, "");
        require(
            existing.length == 0,
            "scripty asset name already has content; pick a fresh LL_MONA_NEW_NAME"
        );

        vm.startBroadcast(pk);

        // 1. Create the empty content slot.
        try store.createContent(newName, "") {} catch {}

        // 2. Append chunks.
        for (uint256 i = 0; i < chunkCount; i++) {
            uint256 start = i * CHUNK_SIZE;
            uint256 end = start + CHUNK_SIZE;
            if (end > data.length) end = data.length;
            uint256 size = end - start;
            bytes memory chunk = new bytes(size);
            for (uint256 j = 0; j < size; j++) {
                chunk[j] = data[start + j];
            }
            store.addChunkToContent(newName, chunk);
            console2.log("  chunk", i + 1, "size", size);
        }

        // 3. Repoint renderers (mona + optional image override).
        for (uint256 i = 0; i < renderers.length; i++) {
            address r = renderers[i];
            require(ILLRenderer(r).owner() == vm.addr(pk), "signer is not renderer owner");
            ILLRenderer(r).setMonaAsset(newName, mime);
            ILLRenderer(r).setImageOverrideUri(imageUri);
            console2.log("  repointed renderer", r);
        }

        // 4. Sync each token's `imageUrl` with the renderer override (admin tx).
        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            require(IArtCoinsToken(t).admin() == vm.addr(pk), "signer is not token admin");
            IArtCoinsToken(t).updateImage(imageUri);
            console2.log("  updated token imageUrl", t);
        }

        vm.stopBroadcast();

        // 5. Verify on-chain content matches local file byte-for-byte.
        bytes memory uploaded = store.getContent(newName, "");
        require(uploaded.length == data.length, "uploaded length mismatch");
        require(keccak256(uploaded) == keccak256(data), "uploaded content mismatch");
        console2.log("Verified scripty content matches local file.");
    }
}
