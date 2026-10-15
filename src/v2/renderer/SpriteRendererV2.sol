// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IMetadataRenderer} from "../../interfaces/IMetadataRenderer.sol";
import {SvgText} from "./SvgText.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {DynamicBufferLib} from "solady/utils/DynamicBufferLib.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @notice Any contract that counts buys and sells per token behind this one view.
interface IBuySellCounter {
    function countsForToken(address token) external view returns (uint128 buys, uint128 sells);
}

/// @notice The token fields the sprite renderer reads.
interface ISpriteToken {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    /// @notice Url of the base image used as the svg backdrop.
    function imageUrl() external view returns (string memory);
}

/// @title  SpriteRendererV2
/// @notice ERC-7572 renderer that overlays a deterministic `+` and minus glyph pattern on a
///         coin's base image. The glyph counts follow the buy and sell counts of an
///         `IBuySellCounter`, which is a constructor argument.
///
/// @dev    - The base image url enters the `href` attribute through `SvgText.attrUrl`: sanitised,
///           escaped, and replaced by an empty string when longer than `SvgText.URL_MAX`.
///         - Name, symbol and the animation url enter the json through `SvgText` and
///           `LibString.escapeJSON`.
///         - Each glyph type is built in its own preallocated buffer by `_glyphs`, then appended to
///           the `DynamicBufferLib` buffer. Each glyph type is capped at `Constants.MAX_GLYPHS`.
///         - The counter, the glyph cap and the animation url base are fixed at construction.
///           The coin admin switches renderers with `setMetadataRenderer`.
contract SpriteRendererV2 is IMetadataRenderer {
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;

    error AnimationUrlTooLong();

    /// @notice Source of the buy and sell totals.
    IBuySellCounter public immutable counter;

    /// @notice Base url of the animation page. The renderer appends `/<chainId>/<tokenAddress>`.
    string public animationUrlBase;

    /// @notice Maximum glyphs rendered per type (buy, sell).
    uint256 public constant MAX_GLYPHS = Constants.MAX_GLYPHS;

    uint256 internal constant VIEW_SIZE = 1000;

    /// @param counter_ Counter to query.
    /// @param animationUrlBase_ Animation page base url without a trailing slash, at most
    ///        `SvgText.URL_MAX` bytes. Longer reverts `AnimationUrlTooLong`.
    constructor(IBuySellCounter counter_, string memory animationUrlBase_) {
        if (bytes(animationUrlBase_).length > SvgText.URL_MAX) revert AnimationUrlTooLong();
        counter = counter_;
        animationUrlBase = animationUrlBase_;
    }

    /// @inheritdoc IMetadataRenderer
    function contractURI(address token) external view returns (string memory) {
        ISpriteToken t = ISpriteToken(token);
        (uint128 buys, uint128 sells) = counter.countsForToken(token);

        string memory svg = _buildSvg(t.imageUrl(), buys, sells, token);
        string memory json = string.concat(
            '{"name":"',
            SvgText.jsonText(t.name(), SvgText.NAME_MAX),
            '","symbol":"',
            SvgText.jsonText(t.symbol(), SvgText.SYMBOL_MAX),
            '","description":"Buys: ',
            LibString.toString(buys),
            " | Sells: ",
            LibString.toString(sells),
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","animation_url":"',
            LibString.escapeJSON(_animationUrl(token)),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ─── svg ─────────────────────────────────────────────────────────────

    function _buildSvg(string memory baseImage, uint128 buys, uint128 sells, address token)
        internal
        pure
        returns (string memory)
    {
        DynamicBufferLib.DynamicBuffer memory buf;
        string memory size = LibString.toString(VIEW_SIZE);
        buf.p(
            bytes(
                string.concat(
                    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ',
                    size,
                    " ",
                    size,
                    '" preserveAspectRatio="xMidYMid meet">'
                )
            )
        );

        string memory href = SvgText.attrUrl(baseImage, SvgText.URL_MAX);
        if (bytes(href).length != 0) {
            buf.p(
                bytes(
                    string.concat(
                        '<image href="', href, '" width="', size, '" height="', size, '"/>'
                    )
                )
            );
        }

        _glyphLayer(buf, token, _capped(buys), 0, "+", "#22c55e");
        _glyphLayer(buf, token, _capped(sells), 1, unicode"−", "#ef4444");

        buf.p("</svg>");
        return string(buf.data);
    }

    function _glyphLayer(
        DynamicBufferLib.DynamicBuffer memory buf,
        address token,
        uint256 count,
        uint256 typeSalt,
        string memory glyph,
        string memory color
    ) internal pure {
        if (count == 0) return;
        buf.p(
            bytes(
                string.concat(
                    '<g fill="',
                    color,
                    '" font-family="monospace" font-size="40" font-weight="700" text-anchor="middle">'
                )
            )
        );
        buf.p(_glyphs(token, count, typeSalt, bytes(glyph)));
        buf.p("</g>");
    }

    /// @dev Writes `count` elements `<text x="X" y="Y">G</text>` into one preallocated buffer of
    ///      at most 32 bytes per element. The position derives from
    ///      `keccak256(abi.encode(token, typeSalt, i))`. `glyph` is at most 3 bytes.
    function _glyphs(address token, uint256 count, uint256 typeSalt, bytes memory glyph)
        internal
        pure
        returns (bytes memory out)
    {
        // 32 bytes per element, 0x40 slack for the last overlapping word write, 0x60 hash scratch
        out = new bytes(count * 32 + 0xa0);
        /// @solidity memory-safe-assembly
        assembly {
            let glen := mload(glyph)
            let gword := mload(add(glyph, 0x20))
            let start := add(out, 0x20)
            let p := start
            let t := add(start, sub(mload(out), 0x60)) // hash scratch at the end of the buffer
            mstore(t, token)
            mstore(add(t, 0x20), typeSalt)
            for { let i := 0 } lt(i, count) { i := add(i, 1) } {
                mstore(add(t, 0x40), i)
                let h := keccak256(t, 0x60)
                mstore(p, shl(184, 0x3c7465787420783d22)) // <text x="
                p := add(p, 9)
                for { let k := 0 } lt(k, 2) { k := add(k, 1) } {
                    let v := mod(h, 1000)
                    h := shr(128, h)
                    let hu := div(v, 100)
                    let te := mod(div(v, 10), 10)
                    if hu {
                        mstore8(p, add(48, hu))
                        p := add(p, 1)
                    }
                    if or(hu, te) {
                        mstore8(p, add(48, te))
                        p := add(p, 1)
                    }
                    mstore8(p, add(48, mod(v, 10)))
                    p := add(p, 1)
                    if iszero(k) {
                        mstore(p, shl(216, 0x2220793d22)) // " y="
                        p := add(p, 5)
                    }
                }
                mstore(p, shl(240, 0x223e)) // ">
                p := add(p, 2)
                mstore(p, gword)
                p := add(p, glen)
                mstore(p, shl(200, 0x3c2f746578743e)) // </text>
                p := add(p, 7)
            }
            mstore(out, sub(p, start))
        }
    }

    function _capped(uint128 n) internal pure returns (uint256) {
        return n > MAX_GLYPHS ? MAX_GLYPHS : uint256(n);
    }

    function _animationUrl(address token) internal view returns (string memory) {
        return string.concat(
            animationUrlBase,
            "/",
            LibString.toString(block.chainid),
            "/",
            LibString.toHexString(token)
        );
    }
}
