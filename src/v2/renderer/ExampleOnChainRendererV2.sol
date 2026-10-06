// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMetadataRenderer} from "../../interfaces/IMetadataRenderer.sol";
import {IRenderableTokenV2} from "./IRenderableTokenV2.sol";
import {SvgText} from "./SvgText.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @title  ExampleOnChainRendererV2
/// @notice Reference on-chain svg renderer. Fork it for custom art.
/// @dev    Differences from v1 (review R1, R2): name and symbol reach the svg only
///         through `SvgText.text`, which truncates on a utf8 boundary, sanitises
///         and escapes `& < > " '`, so a hostile name cannot close the text node
///         or break the xml. json fields use `SvgText.jsonText` (bounded, valid
///         utf8, `LibString.escapeJSON`). No loops, no state, no owner.
contract ExampleOnChainRendererV2 is IMetadataRenderer {
    uint256 internal constant SYMBOL_SVG_MAX = 6;
    uint256 internal constant NAME_SVG_MAX = 28;

    /// @inheritdoc IMetadataRenderer
    function contractURI(address token) external view override returns (string memory) {
        IRenderableTokenV2 t = IRenderableTokenV2(token);
        string memory name = t.name();
        string memory symbol = t.symbol();

        string memory svg = _generateSvg(token, name, symbol, t.totalSupply());
        string memory json = string.concat(
            '{"name":"',
            SvgText.jsonText(name, SvgText.NAME_MAX),
            '","symbol":"',
            SvgText.jsonText(symbol, SvgText.SYMBOL_MAX),
            '","description":"',
            SvgText.jsonText(t.metadata(), SvgText.DESC_MAX),
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","external_url":"',
            SvgText.jsonUrl(t.imageUrl(), SvgText.URL_MAX),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _generateSvg(
        address token,
        string memory name,
        string memory symbol,
        uint256 totalSupply
    ) internal pure returns (string memory) {
        bytes20 addr = bytes20(token);
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            _defs(
                _toColor(uint8(addr[0]), uint8(addr[1]), uint8(addr[2])),
                _toColor(uint8(addr[3]), uint8(addr[4]), uint8(addr[5])),
                _toColor(uint8(addr[6]), uint8(addr[7]), uint8(addr[8]))
            ),
            '<rect width="400" height="400" rx="24" fill="url(#bg)"/>',
            '<rect x="20" y="20" width="360" height="360" rx="16" fill="rgba(0,0,0,0.3)"/>',
            '<text x="200" y="160" font-family="monospace" font-size="64" font-weight="bold" ',
            'fill="white" text-anchor="middle" dominant-baseline="middle">',
            SvgText.text(symbol, SYMBOL_SVG_MAX),
            "</text>",
            '<text x="200" y="220" font-family="sans-serif" font-size="18" ',
            'fill="rgba(255,255,255,0.8)" text-anchor="middle">',
            SvgText.text(name, NAME_SVG_MAX),
            "</text>",
            '<text x="200" y="310" font-family="monospace" font-size="14" ',
            'fill="rgba(255,255,255,0.5)" text-anchor="middle">',
            _formatSupply(totalSupply),
            " tokens</text>",
            '<text x="200" y="340" font-family="monospace" font-size="10" ',
            'fill="rgba(255,255,255,0.3)" text-anchor="middle">',
            LibString.toHexString(token),
            "</text></svg>"
        );
    }

    function _defs(string memory c1, string memory c2, string memory c3)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "<defs>",
            '<linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" stop-color="#',
            c1,
            '"/>',
            '<stop offset="50%" stop-color="#',
            c2,
            '"/>',
            '<stop offset="100%" stop-color="#',
            c3,
            '"/>',
            "</linearGradient>",
            "</defs>"
        );
    }

    function _toColor(uint8 r, uint8 g, uint8 b) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(6);
        result[0] = hexChars[r >> 4];
        result[1] = hexChars[r & 0x0f];
        result[2] = hexChars[g >> 4];
        result[3] = hexChars[g & 0x0f];
        result[4] = hexChars[b >> 4];
        result[5] = hexChars[b & 0x0f];
        return string(result);
    }

    function _formatSupply(uint256 supply) internal pure returns (string memory) {
        uint256 whole = supply / 1e18;
        if (whole >= 1_000_000_000) {
            return string.concat(LibString.toString(whole / 1_000_000_000), "B");
        } else if (whole >= 1_000_000) {
            return string.concat(LibString.toString(whole / 1_000_000), "M");
        } else if (whole >= 1000) {
            return string.concat(LibString.toString(whole / 1000), "K");
        } else {
            return LibString.toString(whole);
        }
    }
}
