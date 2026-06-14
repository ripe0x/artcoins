// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../ArtCoinsToken.sol";
import {IMetadataRenderer} from "../interfaces/IMetadataRenderer.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @title ExampleOnChainRenderer
/// @notice Example on-chain SVG metadata renderer.
/// @dev Generates a fully on-chain SVG image and JSON metadata — no external hosting needed.
///      Token admins can deploy this contract and call token.setMetadataRenderer(address(this))
///      to enable on-chain art for their token.
///
///      This is a reference implementation. Fork it to create custom generative art,
///      dynamic visuals based on token state, or any on-chain rendering logic.
contract ExampleOnChainRenderer is IMetadataRenderer {
    using Strings for uint256;
    using Strings for address;

    /// @notice Generates a full ERC-7572 compliant metadata JSON with on-chain SVG.
    /// @param token The ArtCoins token to render for.
    /// @return The ERC-7572 metadata data URI including an embedded SVG.
    function contractURI(address token) external view override returns (string memory) {
        ArtCoinsToken t = ArtCoinsToken(token);

        string memory svg = _generateSvg(token, t.name(), t.symbol(), t.totalSupply());
        string memory svgDataUri =
            string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));

        string memory json = string.concat(
            '{"name":"',
            LibString.escapeJSON(t.name()),
            '","symbol":"',
            LibString.escapeJSON(t.symbol()),
            '","description":"',
            LibString.escapeJSON(t.metadata()),
            '","image":"',
            svgDataUri,
            '","external_url":"',
            LibString.escapeJSON(t.imageUrl()),
            '"}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice Generates an SVG image from token properties
    /// @dev Override this in your own renderer to create custom art
    function _generateSvg(
        address token,
        string memory name,
        string memory symbol,
        uint256 totalSupply
    ) internal pure returns (string memory) {
        // Derive colors from token address for uniqueness
        bytes20 addr = bytes20(token);
        string memory color1 = _toColor(uint8(addr[0]), uint8(addr[1]), uint8(addr[2]));
        string memory color2 = _toColor(uint8(addr[3]), uint8(addr[4]), uint8(addr[5]));
        string memory color3 = _toColor(uint8(addr[6]), uint8(addr[7]), uint8(addr[8]));

        // Format supply for display
        string memory supplyDisplay = _formatSupply(totalSupply);

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            "<defs>",
            '<linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" stop-color="#',
            color1,
            '"/>',
            '<stop offset="50%" stop-color="#',
            color2,
            '"/>',
            '<stop offset="100%" stop-color="#',
            color3,
            '"/>',
            "</linearGradient>",
            "</defs>",
            '<rect width="400" height="400" rx="24" fill="url(#bg)"/>',
            '<rect x="20" y="20" width="360" height="360" rx="16" fill="rgba(0,0,0,0.3)"/>',
            // Symbol - large centered text
            '<text x="200" y="160" font-family="monospace" font-size="64" font-weight="bold" ',
            'fill="white" text-anchor="middle" dominant-baseline="middle">',
            _truncate(symbol, 6),
            "</text>",
            // Name
            '<text x="200" y="220" font-family="sans-serif" font-size="18" ',
            'fill="rgba(255,255,255,0.8)" text-anchor="middle">',
            _truncate(name, 28),
            "</text>",
            // Supply
            '<text x="200" y="310" font-family="monospace" font-size="14" ',
            'fill="rgba(255,255,255,0.5)" text-anchor="middle">',
            supplyDisplay,
            " tokens",
            "</text>",
            // Address
            '<text x="200" y="340" font-family="monospace" font-size="10" ',
            'fill="rgba(255,255,255,0.3)" text-anchor="middle">',
            Strings.toHexString(token),
            "</text>",
            "</svg>"
        );
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _toColor(uint8 r, uint8 g, uint8 b) internal pure returns (string memory) {
        return string.concat(
            _toHexChar(r >> 4),
            _toHexChar(r & 0x0f),
            _toHexChar(g >> 4),
            _toHexChar(g & 0x0f),
            _toHexChar(b >> 4),
            _toHexChar(b & 0x0f)
        );
    }

    function _toHexChar(uint8 value) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(1);
        result[0] = hexChars[value];
        return string(result);
    }

    function _formatSupply(uint256 supply) internal pure returns (string memory) {
        uint256 whole = supply / 1e18;
        if (whole >= 1_000_000_000) {
            return string.concat((whole / 1_000_000_000).toString(), "B");
        } else if (whole >= 1_000_000) {
            return string.concat((whole / 1_000_000).toString(), "M");
        } else if (whole >= 1000) {
            return string.concat((whole / 1000).toString(), "K");
        } else {
            return whole.toString();
        }
    }

    function _truncate(string memory str, uint256 maxLen) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        if (b.length <= maxLen) return str;
        bytes memory result = new bytes(maxLen);
        for (uint256 i = 0; i < maxLen; i++) {
            result[i] = b[i];
        }
        return string(result);
    }
}
