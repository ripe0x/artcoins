// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../ArtCoinsToken.sol";
import {IMetadataRenderer} from "../interfaces/IMetadataRenderer.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @title DynamicBlockRenderer
/// @notice Dynamic on-chain SVG renderer that displays live block data.
/// @dev Every call returns different metadata because it reads block.number,
///      blockhash, and block.timestamp. Useful for testing that metadata
///      consumers properly handle changing URIs.
contract DynamicBlockRenderer is IMetadataRenderer {
    using Strings for uint256;
    using Strings for address;

    /// @inheritdoc IMetadataRenderer
    function contractURI(address token) external view override returns (string memory) {
        ArtCoinsToken t = ArtCoinsToken(token);

        uint256 blockNum = block.number;
        bytes32 prevHash = blockhash(block.number - 1);
        uint256 ts = block.timestamp;

        string memory svg =
            _generateSvg(token, t.name(), t.symbol(), t.totalSupply(), blockNum, prevHash, ts);
        string memory svgDataUri =
            string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));

        string memory json = string.concat(
            '{"name":"',
            LibString.escapeJSON(t.name()),
            '","symbol":"',
            LibString.escapeJSON(t.symbol()),
            '","description":"Dynamic renderer - metadata changes every block.' " Block ",
            blockNum.toString(),
            '."',
            ',"image":"',
            svgDataUri,
            '","attributes":[',
            _buildAttributes(token, blockNum, prevHash, ts, t.totalSupply()),
            "]}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ─── SVG ────────────────────────────────────────────────────────────

    function _generateSvg(
        address token,
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        uint256 blockNum,
        bytes32 prevHash,
        uint256 ts
    ) internal pure returns (string memory) {
        // Derive gradient colors from the block hash for visual variety
        string memory color1 = _toColor(uint8(prevHash[0]), uint8(prevHash[1]), uint8(prevHash[2]));
        string memory color2 = _toColor(uint8(prevHash[3]), uint8(prevHash[4]), uint8(prevHash[5]));
        string memory color3 = _toColor(uint8(prevHash[6]), uint8(prevHash[7]), uint8(prevHash[8]));

        string memory hashStr = _bytes32ToHex(prevHash);
        string memory supplyStr = _formatSupply(totalSupply);

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 500">',
            _svgDefs(color1, color2, color3),
            '<rect width="400" height="500" rx="24" fill="url(#bg)"/>',
            '<rect x="16" y="16" width="368" height="468" rx="16" fill="rgba(0,0,0,0.45)"/>',
            // Symbol
            '<text x="200" y="80" font-family="monospace" font-size="48" font-weight="bold" ',
            'fill="white" text-anchor="middle">',
            _truncate(symbol, 8),
            "</text>",
            // Name
            '<text x="200" y="112" font-family="sans-serif" font-size="15" ',
            'fill="rgba(255,255,255,0.7)" text-anchor="middle">',
            _truncate(name, 30),
            "</text>",
            _svgBlockSection(blockNum, hashStr, ts),
            _svgFooter(supplyStr, token)
        );
    }

    function _svgDefs(string memory c1, string memory c2, string memory c3)
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

    function _svgBlockSection(uint256 blockNum, string memory hashStr, uint256 ts)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            // Divider
            '<line x1="48" y1="140" x2="352" y2="140" stroke="rgba(255,255,255,0.15)" stroke-width="1"/>',
            // Block number label + value
            '<text x="48" y="175" font-family="monospace" font-size="11" fill="rgba(255,255,255,0.5)">BLOCK NUMBER</text>',
            '<text x="48" y="200" font-family="monospace" font-size="28" font-weight="bold" fill="#7c3aed">',
            blockNum.toString(),
            "</text>",
            // Block hash label + value (2 lines)
            '<text x="48" y="240" font-family="monospace" font-size="11" fill="rgba(255,255,255,0.5)">PREV BLOCK HASH</text>',
            '<text x="48" y="262" font-family="monospace" font-size="11" fill="rgba(255,255,255,0.85)">',
            _substring(hashStr, 0, 34),
            "</text>",
            '<text x="48" y="280" font-family="monospace" font-size="11" fill="rgba(255,255,255,0.85)">',
            _substring(hashStr, 34, 66),
            "</text>",
            // Timestamp
            '<text x="48" y="320" font-family="monospace" font-size="11" fill="rgba(255,255,255,0.5)">TIMESTAMP</text>',
            '<text x="48" y="345" font-family="monospace" font-size="22" fill="white">',
            ts.toString(),
            "</text>",
            // Divider
            '<line x1="48" y1="370" x2="352" y2="370" stroke="rgba(255,255,255,0.15)" stroke-width="1"/>'
        );
    }

    function _svgFooter(string memory supplyStr, address token)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '<text x="200" y="400" font-family="monospace" font-size="12" ',
            'fill="rgba(255,255,255,0.5)" text-anchor="middle">',
            supplyStr,
            " tokens</text>",
            '<text x="200" y="425" font-family="monospace" font-size="9" ',
            'fill="rgba(255,255,255,0.3)" text-anchor="middle">',
            Strings.toHexString(token),
            "</text>",
            '<text x="200" y="460" font-family="monospace" font-size="10" ',
            'fill="rgba(255,255,255,0.25)" text-anchor="middle">DYNAMIC BLOCK RENDERER</text>',
            "</svg>"
        );
    }

    // ─── JSON Attributes / Traits ───────────────────────────────────────

    function _buildAttributes(
        address token,
        uint256 blockNum,
        bytes32 prevHash,
        uint256 ts,
        uint256 totalSupply
    ) internal pure returns (string memory) {
        return string.concat(
            '{"trait_type":"Block Number","value":"',
            blockNum.toString(),
            '"},',
            '{"trait_type":"Block Hash","value":"',
            _bytes32ToHex(prevHash),
            '"},',
            '{"trait_type":"Timestamp","value":"',
            ts.toString(),
            '"},',
            '{"trait_type":"Total Supply","value":"',
            _formatSupply(totalSupply),
            '"},',
            '{"trait_type":"Token Address","value":"',
            Strings.toHexString(token),
            '"},',
            '{"display_type":"number","trait_type":"Block Number (raw)","value":',
            blockNum.toString(),
            "}"
        );
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _bytes32ToHex(bytes32 data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(66); // 0x + 64 chars
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            result[2 + i * 2] = hexChars[uint8(data[i]) >> 4];
            result[3 + i * 2] = hexChars[uint8(data[i]) & 0x0f];
        }
        return string(result);
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

    function _substring(string memory str, uint256 start, uint256 end)
        internal
        pure
        returns (string memory)
    {
        bytes memory b = bytes(str);
        if (start >= b.length) return "";
        if (end > b.length) end = b.length;
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = b[i];
        }
        return string(result);
    }
}
