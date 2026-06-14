// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {TaxConfig} from "../src/interfaces/IArtCoinsTaxable.sol";
import {DynamicBlockRenderer} from "../src/renderer/DynamicBlockRenderer.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Dormant (default-off) tax config for unit tests that don't exercise it.
function _emptyTax() pure returns (TaxConfig memory t) {}

contract DynamicBlockRendererTest is Test {
    DynamicBlockRenderer public renderer;
    ArtCoinsToken public token;
    address public admin = address(0xA1);

    uint256 constant SUPPLY = 100_000_000_000e18;

    function setUp() public {
        renderer = new DynamicBlockRenderer();

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

    /// @dev escapeJSON correctness: for ANY token name, the rendered JSON must
    ///      contain no raw control byte (0x00-0x1F). The token name is
    ///      interpolated into the JSON `name` field via
    ///      `LibString.escapeJSON(t.name())` (DynamicBlockRenderer.sol:34),
    ///      so the only path a control byte could reach the output is an
    ///      escaping failure. The renderer's `description` is a fixed string
    ///      (NOT user-supplied), and the symbol is the only other escaped
    ///      field; the name is the escaped field we drive with arbitrary bytes,
    ///      set via the token constructor (`ArtCoinsToken.name()`). The JSON
    ///      envelope and the embedded SVG are printable.
    function testFuzz_contractURI_noRawControlBytes(string memory name_) public {
        ArtCoinsToken fuzzToken = new ArtCoinsToken(
            name_,
            "MTK",
            SUPPLY,
            admin,
            "https://example.com/img.png",
            "A cool token",
            "context",
            address(0),
            _emptyTax()
        );

        bytes memory json = bytes(_decodeDataUri(renderer.contractURI(address(fuzzToken))));
        for (uint256 i = 0; i < json.length; i++) {
            assertGe(uint8(json[i]), 0x20, "raw control byte in rendered JSON");
        }
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

    function _decodeDataUri(string memory uri) internal pure returns (string memory) {
        bytes memory jsonPrefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        bytes memory b64Part = new bytes(uriBytes.length - jsonPrefix.length);
        for (uint256 i = 0; i < b64Part.length; i++) {
            b64Part[i] = uriBytes[i + jsonPrefix.length];
        }
        return string(Base64.decode(string(b64Part)));
    }
}
