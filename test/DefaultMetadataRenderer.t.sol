// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {TaxConfig} from "../src/interfaces/IArtCoinsTaxable.sol";
import {DefaultMetadataRenderer} from "../src/renderer/DefaultMetadataRenderer.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Dormant (default-off) tax config for unit tests that don't exercise it.
function _emptyTax() pure returns (TaxConfig memory t) {}

contract DefaultMetadataRendererTest is Test {
    DefaultMetadataRenderer public renderer;
    ArtCoinsToken public token;
    address public admin = address(0xA1);

    uint256 constant SUPPLY = 100_000_000_000e18;

    function setUp() public {
        renderer = new DefaultMetadataRenderer();

        token = new ArtCoinsToken(
            "MyToken",
            "MTK",
            SUPPLY,
            admin,
            "https://example.com/img.png",
            "A cool token",
            "context",
            address(0),
            _emptyTax()
        );
    }

    function test_contractURI_returnsValidDataURI() public view {
        string memory uri = renderer.contractURI(address(token));
        assertTrue(_startsWith(uri, "data:application/json;base64,"));
    }

    function test_contractURI_containsTokenData() public view {
        string memory uri = renderer.contractURI(address(token));

        // Decode the base64 part
        bytes memory jsonPrefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        bytes memory b64Part = new bytes(uriBytes.length - jsonPrefix.length);
        for (uint256 i = 0; i < b64Part.length; i++) {
            b64Part[i] = uriBytes[i + jsonPrefix.length];
        }
        string memory json = string(Base64.decode(string(b64Part)));

        // Verify JSON contains expected fields
        assertTrue(_contains(json, '"MyToken"'));
        assertTrue(_contains(json, '"MTK"'));
        assertTrue(_contains(json, '"A cool token"'));
        assertTrue(_contains(json, '"https://example.com/img.png"'));
    }

    function test_contractURI_afterMetadataUpdate() public {
        vm.prank(admin);
        token.updateMetadata("Updated description");

        string memory uri = renderer.contractURI(address(token));
        bytes memory jsonPrefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        bytes memory b64Part = new bytes(uriBytes.length - jsonPrefix.length);
        for (uint256 i = 0; i < b64Part.length; i++) {
            b64Part[i] = uriBytes[i + jsonPrefix.length];
        }
        string memory json = string(Base64.decode(string(b64Part)));

        assertTrue(_contains(json, '"Updated description"'));
    }

    function test_contractURI_afterImageUpdate() public {
        vm.prank(admin);
        token.updateImage("https://new-image.com/v2.png");

        string memory uri = renderer.contractURI(address(token));
        bytes memory jsonPrefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        bytes memory b64Part = new bytes(uriBytes.length - jsonPrefix.length);
        for (uint256 i = 0; i < b64Part.length; i++) {
            b64Part[i] = uriBytes[i + jsonPrefix.length];
        }
        string memory json = string(Base64.decode(string(b64Part)));

        assertTrue(_contains(json, '"https://new-image.com/v2.png"'));
    }

    function test_rendererSwap() public {
        // Set renderer on token
        vm.prank(admin);
        token.setMetadataRenderer(address(renderer));

        string memory uriWithRenderer = token.contractURI();
        assertTrue(_startsWith(uriWithRenderer, "data:application/json;base64,"));

        // Remove renderer — fallback to built-in
        vm.prank(admin);
        token.setMetadataRenderer(address(0));

        string memory uriWithoutRenderer = token.contractURI();
        assertTrue(_startsWith(uriWithoutRenderer, "data:application/json;base64,"));

        // Both should be valid but may differ slightly (same content, different encoding paths)
    }

    function test_contractURI_escapesControlCharsInMetadata() public {
        // A raw newline inside a JSON string is invalid JSON unless escaped.
        // solady's escapeJSON escapes control chars; the previous hand-rolled
        // escaper passed them through raw, producing invalid JSON.
        vm.prank(admin);
        token.updateMetadata("line one\nline two");

        string memory json = _decodeDataUri(renderer.contractURI(address(token)));

        assertTrue(_contains(json, "line one\\nline two"), "newline escaped to backslash-n");
        assertFalse(_containsByte(json, 0x0A), "no raw newline byte survives in the JSON");
    }

    /// @dev The core invariant the swap guarantees: for ANY description, the
    ///      rendered JSON contains no raw control byte (0x00-0x1F). The JSON
    ///      envelope and the fixed name/symbol/image are all printable, so a
    ///      control byte in the output could only be an unescaped description
    ///      char — exactly what the old hand-rolled escaper let through.
    function testFuzz_contractURI_noRawControlBytes(string memory desc) public {
        vm.prank(admin);
        token.updateMetadata(desc);

        bytes memory json = bytes(_decodeDataUri(renderer.contractURI(address(token))));
        for (uint256 i = 0; i < json.length; i++) {
            assertGe(uint8(json[i]), 0x20, "raw control byte in rendered JSON");
        }
    }

    function test_escape_quoteAndBackslash() public {
        vm.prank(admin);
        token.updateMetadata("a\"b\\c");
        string memory json = _decodeDataUri(renderer.contractURI(address(token)));
        // " -> \"  and  \ -> \\  (this is also what blocks JSON-key injection)
        assertTrue(_contains(json, "a\\\"b\\\\c"), "quote and backslash escaped");
    }

    function test_escape_tabAndCarriageReturn() public {
        vm.prank(admin);
        token.updateMetadata("x\ty\rz");
        string memory json = _decodeDataUri(renderer.contractURI(address(token)));
        assertTrue(_contains(json, "x\\ty\\rz"), "tab and CR escaped to 2-char forms");
        assertFalse(_containsByte(json, 0x09), "no raw tab byte");
        assertFalse(_containsByte(json, 0x0D), "no raw carriage-return byte");
    }

    function test_escape_unicodePassesThrough() public {
        // Multi-byte UTF-8 is valid inside a JSON string; escapeJSON escapes
        // only 0x00-0x1F, '"' and '\\', so it must leave UTF-8 intact.
        vm.prank(admin);
        token.updateMetadata(unicode"café 😀 ▲");
        string memory json = _decodeDataUri(renderer.contractURI(address(token)));
        assertTrue(_contains(json, unicode"café 😀 ▲"), "unicode preserved byte-for-byte");
    }

    function test_escape_emptyDescription() public {
        vm.prank(admin);
        token.updateMetadata("");
        string memory json = _decodeDataUri(renderer.contractURI(address(token)));
        assertTrue(
            _contains(json, '"description":""'), "empty description renders as empty JSON string"
        );
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory s = bytes(str);
        bytes memory p = bytes(prefix);
        if (s.length < p.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (s[i] != p[i]) return false;
        }
        return true;
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    function _decodeDataUri(string memory uri) internal pure returns (string memory) {
        bytes memory jsonPrefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        bytes memory b64Part = new bytes(uriBytes.length - jsonPrefix.length);
        for (uint256 i = 0; i < b64Part.length; i++) {
            b64Part[i] = uriBytes[i + jsonPrefix.length];
        }
        return string(Base64.decode(string(b64Part)));
    }

    function _containsByte(string memory haystack, bytes1 b) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        for (uint256 i = 0; i < h.length; i++) {
            if (h[i] == b) return true;
        }
        return false;
    }
}
