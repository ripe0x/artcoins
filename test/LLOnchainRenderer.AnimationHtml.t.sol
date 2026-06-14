// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {TaxConfig} from "../src/interfaces/IArtCoinsTaxable.sol";
import {IScriptyBuilderV2, IScriptyStorageV2} from "../src/interfaces/IScripty.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev Dormant (default-off) tax config for unit tests that don't exercise it.
function _emptyTax() pure returns (TaxConfig memory t) {}

/// @dev Minimal mock — pretends to be ScriptyStorageV2. Bytes can be set
///      directly via `set(name, bytes)`.
contract MockScriptyStorage {
    mapping(bytes32 => bytes) private _content;

    function set(string calldata name, bytes calldata data) external {
        _content[keccak256(bytes(name))] = data;
    }

    function getContent(string calldata name, bytes calldata) external view returns (bytes memory) {
        return _content[keccak256(bytes(name))];
    }

    function createContent(string calldata, bytes calldata) external pure {}

    function addChunkToContent(string calldata name, bytes calldata data) external {
        _content[keccak256(bytes(name))] = bytes.concat(_content[keccak256(bytes(name))], data);
    }
}

/// @dev Minimal mock — empty pool, zero trades.
contract MockCounter {
    function poolForToken(address) external pure returns (PoolId) {
        return PoolId.wrap(bytes32(uint256(0)));
    }

    function totalTrades(PoolId) external pure returns (uint256) {
        return 0;
    }

    function tradeChunk(PoolId, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @title LiquidityLayerOnchainRendererAnimationHtmlTest
/// @notice Regression test for the "raw JS leaks past the closing `"` of the
///         base64 src attribute" bug in `tokenURI` / `contractURI`.
///
///         The ROOT CAUSE was that ScriptyBuilderV2's `tagType: 2` emits
///         storage content VERBATIM between
///         `<script src="data:text/javascript;base64,` and `"></script>` —
///         it does NOT auto-base64-encode the bytes it reads. So whatever is
///         in storage under the sketch's name must already be base64.
///         `Deploy.s.sol` was uploading the raw JS bytes of `sketch.js` to that
///         slot, producing `<script src="data:text/javascript;base64,<raw JS>">`
///         which the browser silently rejects (data URI isn't valid base64).
///
///         This test exercises the renderer + the REAL on-chain ScriptyBuilderV2
///         (forked from mainnet), with mock storage + mock counter so the test
///         is self-contained. It uploads `Base64.encode(sketch.js)` to the mock
///         storage and asserts:
///           1. Exactly one `<script src="data:text/javascript;base64,...">` is
///              present in the decoded animation_url HTML.
///           2. The captured src= value contains only the base64 alphabet
///              (`A-Za-z0-9+/=`) — no leaked raw chars.
///           3. The captured base64 equals `Base64.encode(sketch.js)` byte-for-
///              byte (i.e. the renderer didn't mangle, truncate, or duplicate).
///
/// Run:
///   forge test --match-contract LiquidityLayerOnchainRendererAnimationHtmlTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract LiquidityLayerOnchainRendererAnimationHtmlTest is Test {
    /// @notice Canonical ScriptyBuilderV2 address — same on every chain.
    address constant SCRIPTY_BUILDER = 0xD7587F110E08F4D120A231bA97d3B577A81Df022;

    string constant SKETCH_NAME = "ll/sketch.test";
    string constant MONA_NAME = "ll/mona.test";

    bytes internal sketchSource;
    string internal sketchBase64;

    MockScriptyStorage internal storageContract;
    MockCounter internal counter;
    LiquidityLayerOnchainRenderer internal renderer;
    ArtCoinsToken internal token;

    bool internal _onFork;

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    function setUp() public {
        if (SCRIPTY_BUILDER.code.length == 0) {
            console2.log("SKIPPING: ScriptyBuilderV2 not deployed on this fork");
            return;
        }
        _onFork = true;

        sketchSource = vm.readFileBinary("script-js/data/ll/sketch.js");
        sketchBase64 = Base64.encode(sketchSource);

        storageContract = new MockScriptyStorage();
        counter = new MockCounter();

        // THE FIX: upload pre-encoded base64 to the slot ScriptyBuilder
        // consumes via tagType:2. Mona stays raw because the renderer
        // base64-encodes it itself for an inline-script (`tagType:1`) shim.
        storageContract.set(SKETCH_NAME, bytes(sketchBase64));
        storageContract.set(MONA_NAME, hex"ffd8ffe000104a46494600"); // 11-byte JPEG header

        renderer = new LiquidityLayerOnchainRenderer(
            address(this),
            LiquidityLayerCounterPoolExtension(address(counter)),
            IScriptyBuilderV2(SCRIPTY_BUILDER),
            IScriptyStorageV2(address(storageContract)),
            SKETCH_NAME,
            MONA_NAME,
            "image/jpeg",
            "Test description"
        );

        token = new ArtCoinsToken(
            "Test", "T", 1_000_000_000e18, address(this), "", "meta", "ctx", address(0), _emptyTax()
        );
    }

    /// @notice The third script tag's `src=` attribute must be a valid
    ///         `data:text/javascript;base64,<PURE_BASE64>` URI — no raw text
    ///         leaking past the base64 portion. Asserts the captured base64
    ///         equals `Base64.encode(sketch.js)`.
    function test_animationHtml_scriptSrcIsPureBase64() public view onlyFork {
        string memory uri = renderer.contractURI(address(token));

        // Decode the outer JSON wrapper.
        bytes memory json = _decodeDataUri(uri, "data:application/json;base64,");

        // Locate `"animation_url":"data:text/html;base64,...."` and decode it.
        bytes memory animUrl = _extractJsonStringField(json, '"animation_url":"');
        bytes memory html = _decodeDataUri(string(animUrl), "data:text/html;base64,");

        // Find every `<script src="data:text/javascript;base64,...">` in the HTML.
        string[] memory srcs = _extractScriptSrcBase64s(html);

        assertEq(srcs.length, 1, "expected exactly one external script src");

        for (uint256 i = 0; i < srcs.length; i++) {
            assertTrue(
                _isPureBase64Alphabet(srcs[i]), "script src contains non-base64 char (raw JS leak)"
            );
        }

        // The captured base64 must EXACTLY match Base64.encode(sketch.js).
        // No truncation, no duplication, no leaked raw bytes.
        assertEq(
            keccak256(bytes(srcs[0])),
            keccak256(bytes(sketchBase64)),
            "src base64 != Base64.encode(sketch.js)"
        );

        // Also assert the inline script tags are present (3 tags total).
        assertTrue(_countOccurrences(html, "<script") == 3, "expected 3 <script> tags total");
    }

    /// @notice The image field is a clean data URI (mona). Sanity check that
    ///         the bug's "fix" didn't accidentally break the inline mona path.
    function test_animationHtml_imageDataUriIsValid() public view onlyFork {
        string memory uri = renderer.contractURI(address(token));
        bytes memory json = _decodeDataUri(uri, "data:application/json;base64,");
        bytes memory image = _extractJsonStringField(json, '"image":"');
        // image starts with `data:image/jpeg;base64,`
        assertTrue(
            _startsWith(image, bytes("data:image/jpeg;base64,")),
            "image field must be a data:image data URI"
        );
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    /// @dev Strips the given prefix from a `data:...;base64,<B64>` URI and
    ///      returns the decoded body bytes.
    function _decodeDataUri(string memory uri, string memory prefix)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory u = bytes(uri);
        bytes memory p = bytes(prefix);
        require(_startsWith(u, p), "uri does not start with expected prefix");
        bytes memory b64 = new bytes(u.length - p.length);
        for (uint256 i = 0; i < b64.length; i++) {
            b64[i] = u[i + p.length];
        }
        return _base64Decode(string(b64));
    }

    /// @dev Find `field` in `json` (e.g. `"animation_url":"`) and return the
    ///      value bytes up to the next unescaped `"`.
    function _extractJsonStringField(bytes memory json, string memory fieldKey)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory key = bytes(fieldKey);
        int256 start = _indexOf(json, key, 0);
        require(start >= 0, "field not found");
        uint256 vStart = uint256(start) + key.length;
        // walk until next `"` (we don't worry about escaping for our specific
        // fields: animation_url and image are data: URIs that don't contain `"`).
        uint256 vEnd = vStart;
        while (vEnd < json.length && json[vEnd] != '"') {
            vEnd++;
        }
        bytes memory out = new bytes(vEnd - vStart);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = json[vStart + i];
        }
        return out;
    }

    /// @dev Find every `<script src="data:text/javascript;base64,(...)">`
    ///      occurrence and return the captured `(...)` portions.
    function _extractScriptSrcBase64s(bytes memory html) internal pure returns (string[] memory) {
        bytes memory marker = bytes('<script src="data:text/javascript;base64,');
        // first pass: count
        uint256 n = 0;
        int256 cursor = 0;
        while (true) {
            int256 idx = _indexOf(html, marker, uint256(cursor));
            if (idx < 0) break;
            n++;
            cursor = idx + int256(marker.length);
        }
        string[] memory out = new string[](n);
        cursor = 0;
        uint256 k = 0;
        while (k < n) {
            int256 idx = _indexOf(html, marker, uint256(cursor));
            if (idx < 0) break;
            uint256 vStart = uint256(idx) + marker.length;
            // capture up to the closing `"` of the src attribute
            uint256 vEnd = vStart;
            while (vEnd < html.length && html[vEnd] != '"') {
                vEnd++;
            }
            bytes memory captured = new bytes(vEnd - vStart);
            for (uint256 i = 0; i < captured.length; i++) {
                captured[i] = html[vStart + i];
            }
            out[k++] = string(captured);
            cursor = int256(vEnd);
        }
        return out;
    }

    /// @dev `^[A-Za-z0-9+/=]+$` — pure base64 alphabet.
    function _isPureBase64Alphabet(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length == 0) return false;
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            bool ok = (c >= 0x41 && c <= 0x5a) // A-Z
                || (c >= 0x61 && c <= 0x7a) // a-z
                || (c >= 0x30 && c <= 0x39) // 0-9
                || c == 0x2b // +
                || c == 0x2f // /
                || c == 0x3d; // =
            if (!ok) return false;
        }
        return true;
    }

    /// @dev Returns the index of the first occurrence of `needle` in `haystack`
    ///      starting at `from`, or -1 if not found.
    function _indexOf(bytes memory haystack, bytes memory needle, uint256 from)
        internal
        pure
        returns (int256)
    {
        if (needle.length == 0) return int256(from);
        if (haystack.length < needle.length) return -1;
        uint256 last = haystack.length - needle.length;
        for (uint256 i = from; i <= last; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return int256(i);
        }
        return -1;
    }

    function _startsWith(bytes memory s, bytes memory prefix) internal pure returns (bool) {
        if (s.length < prefix.length) return false;
        for (uint256 i = 0; i < prefix.length; i++) {
            if (s[i] != prefix[i]) return false;
        }
        return true;
    }

    function _countOccurrences(bytes memory haystack, string memory needle)
        internal
        pure
        returns (uint256 count)
    {
        bytes memory n = bytes(needle);
        int256 cursor = 0;
        while (true) {
            int256 idx = _indexOf(haystack, n, uint256(cursor));
            if (idx < 0) break;
            count++;
            cursor = idx + int256(n.length);
        }
    }

    /// @dev Lightweight base64 decoder. Handles the standard alphabet with
    ///      `=` padding. Reverts on malformed input.
    function _base64Decode(string memory data) internal pure returns (bytes memory) {
        bytes memory b = bytes(data);
        require(b.length % 4 == 0, "base64: length % 4 != 0");
        uint256 padding = 0;
        if (b.length > 0 && b[b.length - 1] == "=") padding++;
        if (b.length > 1 && b[b.length - 2] == "=") padding++;

        uint256 outLen = (b.length / 4) * 3 - padding;
        bytes memory out = new bytes(outLen);
        uint256 k = 0;
        for (uint256 i = 0; i < b.length; i += 4) {
            uint8 a = _b64CharToVal(uint8(b[i]));
            uint8 c2 = _b64CharToVal(uint8(b[i + 1]));
            uint8 c3 = b[i + 2] == "=" ? 0 : _b64CharToVal(uint8(b[i + 2]));
            uint8 c4 = b[i + 3] == "=" ? 0 : _b64CharToVal(uint8(b[i + 3]));

            uint32 triple = (uint32(a) << 18) | (uint32(c2) << 12) | (uint32(c3) << 6) | uint32(c4);
            if (k < outLen) out[k++] = bytes1(uint8(triple >> 16));
            if (k < outLen) out[k++] = bytes1(uint8(triple >> 8));
            if (k < outLen) out[k++] = bytes1(uint8(triple));
        }
        return out;
    }

    function _b64CharToVal(uint8 c) internal pure returns (uint8) {
        if (c >= 0x41 && c <= 0x5a) return c - 0x41; // A-Z = 0..25
        if (c >= 0x61 && c <= 0x7a) return c - 0x61 + 26; // a-z = 26..51
        if (c >= 0x30 && c <= 0x39) return c - 0x30 + 52; // 0-9 = 52..61
        if (c == 0x2b) return 62; // +
        if (c == 0x2f) return 63; // /
        revert("base64: invalid char");
    }
}
