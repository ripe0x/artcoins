// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {TaxConfig} from "../src/interfaces/IArtCoinsTaxable.sol";
import {ExampleOnChainRenderer} from "../src/renderer/ExampleOnChainRenderer.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Dormant (default-off) tax config for unit tests that don't exercise it.
function _emptyTax() pure returns (TaxConfig memory t) {}

contract ExampleOnChainRendererTest is Test {
    ExampleOnChainRenderer public renderer;
    ArtCoinsToken public token;
    address public admin = address(0xA1);

    function setUp() public {
        renderer = new ExampleOnChainRenderer();

        token = new ArtCoinsToken(
            "OnChain Art Token",
            "OCART",
            1_000_000_000e18,
            admin,
            "https://example.com",
            "A token with on-chain art",
            "example",
            address(0),
            _emptyTax()
        );
    }

    function test_contractURI_returnsDataUri() public view {
        string memory uri = renderer.contractURI(address(token));
        assertTrue(_startsWith(uri, "data:application/json;base64,"));
    }

    function test_contractURI_containsSvgImage() public view {
        string memory uri = renderer.contractURI(address(token));

        // Decode the JSON
        bytes memory jsonPrefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        bytes memory b64Part = new bytes(uriBytes.length - jsonPrefix.length);
        for (uint256 i = 0; i < b64Part.length; i++) {
            b64Part[i] = uriBytes[i + jsonPrefix.length];
        }
        string memory json = string(Base64.decode(string(b64Part)));

        // Should contain an SVG data URI as the image
        assertTrue(_contains(json, "data:image/svg+xml;base64,"));
        assertTrue(_contains(json, '"OnChain Art Token"'));
        assertTrue(_contains(json, '"OCART"'));
    }

    function test_contractURI_uniquePerToken() public {
        // Deploy a second token at a different address
        ArtCoinsToken token2 = new ArtCoinsToken(
            "Other Token", "OTH", 500_000_000e18, admin, "", "other", "", address(0), _emptyTax()
        );

        string memory uri1 = renderer.contractURI(address(token));
        string memory uri2 = renderer.contractURI(address(token2));

        // Different tokens should produce different metadata (different names, symbols, addresses)
        assertTrue(keccak256(bytes(uri1)) != keccak256(bytes(uri2)));
    }

    function test_tokenUsesRenderer() public {
        vm.prank(admin);
        token.setMetadataRenderer(address(renderer));

        string memory uri = token.contractURI();
        assertTrue(_startsWith(uri, "data:application/json;base64,"));

        // tokenURI should match
        assertEq(token.tokenURI(), uri);
    }

    /// @dev escapeJSON correctness: for ANY metadata string, the rendered JSON
    ///      must contain no raw control byte (0x00-0x1F). The token's metadata
    ///      is interpolated into the JSON `description` field via
    ///      `LibString.escapeJSON(t.metadata())` (ExampleOnChainRenderer.sol:38),
    ///      so the only path a control byte could reach the output is an
    ///      escaping failure — exactly what this fuzz proves cannot happen.
    ///      The JSON envelope and the fixed name/symbol are printable.
    function testFuzz_contractURI_noRawControlBytes(string memory metadata_) public {
        vm.prank(admin);
        token.updateMetadata(metadata_);

        bytes memory json = bytes(_decodeDataUri(renderer.contractURI(address(token))));
        for (uint256 i = 0; i < json.length; i++) {
            assertGe(uint8(json[i]), 0x20, "raw control byte in rendered JSON");
        }
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
}
