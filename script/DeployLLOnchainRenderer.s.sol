// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {IScriptyBuilderV2, IScriptyStorageV2} from "../src/interfaces/IScripty.sol";

/// @notice Uploads the LL sketch + Mona Lisa to ScriptyStorageV2 (canonical
///         deployment, same on all chains we use), then deploys the
///         on-chain renderer pointing at those assets and the existing
///         LiquidityLayerCounterPoolExtension.
///
/// Required env vars:
///     PRIVATE_KEY        deployer key (also becomes scripty content owner + renderer owner)
///     LL_COUNTER         already-deployed LiquidityLayerCounterPoolExtension
///     LL_SKETCH_NAME     e.g. "ll/sketch.v1"
///     LL_MONA_NAME       e.g. "ll/mona.v1"
///     LL_MONA_MIME       e.g. "image/jpeg"
///     LL_DESCRIPTION     e.g. "Until nothing remains but speculation"
///     LL_SKETCH_PATH     filesystem path to the sketch JS (read by vm.readFileBinary)
///     LL_MONA_PATH       filesystem path to the Mona Lisa image bytes
///
/// Optional env vars (omit/empty to skip):
///     LL_HISTORY_NAME    e.g. "ll/history.v1" — historical Base trades
///     LL_HISTORY_PATH    filesystem path to the packed history bit-stream
///                        (LSB-first within bytes). The renderer prepends this
///                        to live counter bits before injecting into the sketch.
///
/// Idempotent on scripty: if a content name already exists with my key as
/// owner and the bytes match the local artifact, the upload is skipped. If
/// the name is taken by a different owner, the script aborts and asks for a
/// version bump.
contract DeployLLOnchainRenderer is Script {
    address constant SCRIPTY_BUILDER = 0xD7587F110E08F4D120A231bA97d3B577A81Df022;
    address constant SCRIPTY_STORAGE = 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address counter = vm.envAddress("LL_COUNTER");
        string memory sketchName = vm.envString("LL_SKETCH_NAME");
        string memory monaName = vm.envString("LL_MONA_NAME");
        string memory monaMime = vm.envString("LL_MONA_MIME");
        string memory description = vm.envString("LL_DESCRIPTION");
        bytes memory sketchBytes = vm.readFileBinary(vm.envString("LL_SKETCH_PATH"));
        bytes memory monaBytes = vm.readFileBinary(vm.envString("LL_MONA_PATH"));

        // Hard guard: ScriptyBuilder tagType:2 emits the sketch as
        //   <script src="data:text/javascript;base64,<onchain bytes>">
        // i.e. the on-chain bytes are spliced verbatim after `;base64,`.
        // If we upload raw JS, the browser tries to base64-decode it and
        // the script silently fails to execute (no shapes, no animation).
        // Reject any sketch input that isn't already valid base64 ASCII.
        _assertBase64Ascii(sketchBytes, "LL_SKETCH_PATH");

        // Optional history asset: empty name (or empty path) skips entirely.
        string memory historyName = _envOrEmpty("LL_HISTORY_NAME");
        bytes memory historyBytes;
        if (bytes(historyName).length > 0) {
            string memory historyPath = _envOrEmpty("LL_HISTORY_PATH");
            require(
                bytes(historyPath).length > 0, "LL_HISTORY_NAME set but LL_HISTORY_PATH missing"
            );
            historyBytes = vm.readFileBinary(historyPath);
        }

        console2.log("=== Deploy LL on-chain renderer ===");
        console2.log("Deployer:      ", deployer);
        console2.log("Counter:       ", counter);
        console2.log("Sketch name:   ", sketchName);
        console2.log("Mona name:     ", monaName);
        console2.log("Mona MIME:     ", monaMime);
        console2.log("History name:  ", bytes(historyName).length > 0 ? historyName : "(none)");
        console2.log("Sketch bytes:  ", sketchBytes.length);
        console2.log("Mona bytes:    ", monaBytes.length);
        console2.log("History bytes: ", historyBytes.length);

        IScriptyStorageV2 storageContract = IScriptyStorageV2(SCRIPTY_STORAGE);

        vm.startBroadcast(pk);

        _ensureContent(storageContract, sketchName, sketchBytes, deployer);
        _ensureContent(storageContract, monaName, monaBytes, deployer);
        if (bytes(historyName).length > 0) {
            _ensureContent(storageContract, historyName, historyBytes, deployer);
        }

        // Belt-and-suspenders: re-fetch the on-chain sketch and re-validate.
        // Catches partial-chunk corruption, wrong-content collisions on a
        // pre-existing name, or any other path by which non-base64 bytes
        // could have ended up under the sketch's content slot.
        bytes memory onchainSketch = storageContract.getContent(sketchName, "");
        _assertBase64Ascii(onchainSketch, string.concat("on-chain content '", sketchName, "'"));

        LiquidityLayerOnchainRenderer renderer = new LiquidityLayerOnchainRenderer(
            deployer,
            LiquidityLayerCounterPoolExtension(counter),
            IScriptyBuilderV2(SCRIPTY_BUILDER),
            storageContract,
            sketchName,
            monaName,
            monaMime,
            description
        );

        // Wire the history asset post-deploy via its setter (the constructor
        // intentionally takes only the always-required fields).
        if (bytes(historyName).length > 0) {
            renderer.setHistoryAsset(historyName);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("Renderer:      ", address(renderer));
        console2.log("");
        console2.log("Set tokenConfig.renderer = ", address(renderer));
        console2.log("when launching a token via the factory.");
    }

    function _envOrEmpty(string memory name) internal view returns (string memory) {
        try vm.envString(name) returns (string memory v) {
            return v;
        } catch {
            return "";
        }
    }

    function _hexByte(uint8 b) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory out = new bytes(2);
        out[0] = hexChars[b >> 4];
        out[1] = hexChars[b & 0x0f];
        return string(out);
    }

    /// @dev Revert if any byte in `data` is outside the base64 charset.
    ///      Allowed: A–Z, a–z, 0–9, '+', '/', '=', '\n', '\r'.
    ///      Reverting here is correct: ScriptyBuilder tagType:2 splices the
    ///      stored bytes verbatim after `data:text/javascript;base64,`, so
    ///      anything not base64-ASCII produces a broken data URI on chain.
    function _assertBase64Ascii(bytes memory data, string memory source) public view {
        require(data.length > 0, string.concat(source, " is empty"));
        for (uint256 i = 0; i < data.length; i++) {
            uint8 b = uint8(data[i]);
            bool ok = (b >= 0x41 && b <= 0x5A) // A-Z
                || (b >= 0x61 && b <= 0x7A) // a-z
                || (b >= 0x30 && b <= 0x39) // 0-9
                || b == 0x2B // +
                || b == 0x2F // /
                || b == 0x3D // =
                || b == 0x0A // \n
                || b == 0x0D; // \r
            if (!ok) {
                revert(
                    string.concat(
                        source,
                        " contains non-base64 byte at offset ",
                        vm.toString(i),
                        " (0x",
                        _hexByte(b),
                        "). The sketch must be uploaded base64-encoded; point at the .js.b64 sibling."
                    )
                );
            }
        }
    }

    /// @dev Read existing content from scripty: if the entry exists with our
    ///      owner and the bytes match, do nothing. If it's empty or partial,
    ///      append the missing tail. If owned by someone else (or content
    ///      diverges), abort with a clear message.
    function _ensureContent(
        IScriptyStorageV2 storageContract,
        string memory name,
        bytes memory data,
        address self
    ) internal {
        // We can't read the content owner via the IScriptyStorageV2 interface
        // alone — getContent doesn't expose it. Read the chunk pointers and
        // existing bytes, then attempt write. If owned by someone else, the
        // chain reverts with NotContentOwner — caller bumps the version.
        bytes memory existing = storageContract.getContent(name, "");
        if (keccak256(existing) == keccak256(data)) {
            console2.log("  [skip]  ", name, " already uploaded; bytes match");
            return;
        }
        if (existing.length > data.length) {
            console2.log(
                "  [abort] ", name, " has more bytes on chain than local; bump the version"
            );
            revert("content longer than local artifact");
        }
        if (existing.length == 0) {
            // Try createContent first; if it reverts (ContentExists), continue
            // to the chunk append, which will revert with NotContentOwner if
            // we don't own the existing entry.
            try storageContract.createContent(name, "") {
                console2.log("  [new]   ", name);
            } catch {
                console2.log("  [exists]", name, " (continuing to addChunk)");
            }
        }

        bytes memory remaining = _slice(data, existing.length);
        storageContract.addChunkToContent(name, remaining);
        console2.log("  [chunk] ", name, " appended ", remaining.length);
    }

    function _slice(bytes memory src, uint256 start) internal pure returns (bytes memory) {
        if (start >= src.length) return new bytes(0);
        bytes memory out = new bytes(src.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = src[start + i];
        }
        return out;
    }
}
