// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMetadataRenderer} from "../../interfaces/IMetadataRenderer.sol";
import {IRenderableTokenV2} from "./IRenderableTokenV2.sol";
import {SvgText} from "./SvgText.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @title  DynamicBlockRendererV2
/// @notice Dynamic on-chain svg renderer that shows live block data. Every call
///         reads `block.number`, the previous block hash and `block.timestamp`, so
///         the metadata changes every block.
/// @dev    Differences from v1 (review R1, R2): name and symbol reach the svg only
///         through `SvgText.text` (utf8 safe truncation, sanitising, escaping of
///         `& < > " '`); json fields use `SvgText.jsonText`. No loops, no state,
///         no owner, a few hundred thousand gas at most.
contract DynamicBlockRendererV2 is IMetadataRenderer {
    uint256 internal constant SYMBOL_SVG_MAX = 8;
    uint256 internal constant NAME_SVG_MAX = 30;

    /// @inheritdoc IMetadataRenderer
    function contractURI(address token) external view override returns (string memory) {
        IRenderableTokenV2 t = IRenderableTokenV2(token);
        string memory name = t.name();
        string memory symbol = t.symbol();
        uint256 supply = t.totalSupply();

        uint256 blockNum = block.number;
        bytes32 prevHash = blockNum == 0 ? bytes32(0) : blockhash(blockNum - 1);
        uint256 ts = block.timestamp;

        string memory svg = _generateSvg(token, name, symbol, supply, blockNum, prevHash, ts);

        string memory json = string.concat(
            '{"name":"',
            SvgText.jsonText(name, SvgText.NAME_MAX),
            '","symbol":"',
            SvgText.jsonText(symbol, SvgText.SYMBOL_MAX),
            '","description":"Dynamic renderer, metadata changes every block. Block ',
            LibString.toString(blockNum),
            '.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[',
            _buildAttributes(token, blockNum, prevHash, ts, supply),
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
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 500">',
            _svgDefs(
                _toColor(uint8(prevHash[0]), uint8(prevHash[1]), uint8(prevHash[2])),
                _toColor(uint8(prevHash[3]), uint8(prevHash[4]), uint8(prevHash[5])),
                _toColor(uint8(prevHash[6]), uint8(prevHash[7]), uint8(prevHash[8]))
            ),
            '<rect width="400" height="500" rx="24" fill="url(#bg)"/>',
            '<rect x="16" y="16" width="368" height="468" rx="16" fill="rgba(0,0,0,0.45)"/>',
            '<text x="200" y="80" font-family="monospace" font-size="48" font-weight="bold" ',
            'fill="white" text-anchor="middle">',
            SvgText.text(symbol, SYMBOL_SVG_MAX),
            "</text>",
            '<text x="200" y="112" font-family="sans-serif" font-size="15" ',
            'fill="rgba(255,255,255,0.7)" text-anchor="middle">',
            SvgText.text(name, NAME_SVG_MAX),
            "</text>",
            _svgBlockSection(blockNum, _bytes32ToHex(prevHash), ts),
            _svgFooter(_formatSupply(totalSupply), token)
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
            '<line x1="48" y1="140" x2="352" y2="140" stroke="rgba(255,255,255,0.15)" stroke-width="1"/>',
            '<text x="48" y="175" font-family="monospace" font-size="11" fill="rgba(255,255,255,0.5)">BLOCK NUMBER</text>',
            '<text x="48" y="200" font-family="monospace" font-size="28" font-weight="bold" fill="#7c3aed">',
            LibString.toString(blockNum),
            "</text>",
            '<text x="48" y="240" font-family="monospace" font-size="11" fill="rgba(255,255,255,0.5)">PREV BLOCK HASH</text>',
            '<text x="48" y="262" font-family="monospace" font-size="11" fill="rgba(255,255,255,0.85)">',
            _substring(hashStr, 0, 34),
            "</text>",
            '<text x="48" y="280" font-family="monospace" font-size="11" fill="rgba(255,255,255,0.85)">',
            _substring(hashStr, 34, 66),
            "</text>",
            '<text x="48" y="320" font-family="monospace" font-size="11" fill="rgba(255,255,255,0.5)">TIMESTAMP</text>',
            '<text x="48" y="345" font-family="monospace" font-size="22" fill="white">',
            LibString.toString(ts),
            "</text>",
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
            LibString.toHexString(token),
            "</text>",
            '<text x="200" y="460" font-family="monospace" font-size="10" ',
            'fill="rgba(255,255,255,0.25)" text-anchor="middle">DYNAMIC BLOCK RENDERER</text>',
            "</svg>"
        );
    }

    // ─── json attributes ────────────────────────────────────────────────

    function _buildAttributes(
        address token,
        uint256 blockNum,
        bytes32 prevHash,
        uint256 ts,
        uint256 totalSupply
    ) internal pure returns (string memory) {
        return string.concat(
            '{"trait_type":"Block Number","value":"',
            LibString.toString(blockNum),
            '"},',
            '{"trait_type":"Block Hash","value":"',
            _bytes32ToHex(prevHash),
            '"},',
            '{"trait_type":"Timestamp","value":"',
            LibString.toString(ts),
            '"},',
            '{"trait_type":"Total Supply","value":"',
            _formatSupply(totalSupply),
            '"},',
            '{"trait_type":"Token Address","value":"',
            LibString.toHexString(token),
            '"},',
            '{"display_type":"number","trait_type":"Block Number (raw)","value":',
            LibString.toString(blockNum),
            "}"
        );
    }

    // ─── helpers ────────────────────────────────────────────────────────

    function _bytes32ToHex(bytes32 data) internal pure returns (string memory) {
        return LibString.toHexString(uint256(data), 32);
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
