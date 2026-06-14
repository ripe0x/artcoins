// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMetadataRenderer} from "../interfaces/IMetadataRenderer.sol";
import {LiquidityLayerCounterPoolExtension} from "./LiquidityLayerCounterPoolExtension.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @notice Minimal subset of the ArtCoinsToken interface this renderer reads from.
/// @dev Anything that exposes these three view functions can be rendered.
interface IRenderableToken {
    /// @notice ERC20 name of the token being rendered.
    function name() external view returns (string memory);
    /// @notice ERC20 symbol of the token being rendered.
    function symbol() external view returns (string memory);
    /// @notice URL of the base image used as the SVG canvas backdrop.
    function imageUrl() external view returns (string memory);
}

/// @title LiquidityLayerSpriteRenderer
/// @notice ERC-7572 metadata renderer that overlays a deterministic + / − glyph
///         pattern onto a token's base art, scaled to the token's lifetime
///         buy and sell counts read from a `LiquidityLayerCounterPoolExtension`.
///
/// @dev    Output shape:
///           {
///             name, symbol, description,
///             image: "data:image/svg+xml;base64,<svg with base art + glyphs>",
///             animation_url: "<animationUrlBase>/<chainId>/<token>"
///           }
///
///         Glyph count cap: SVG output stays manageable for indexers
///         (Etherscan/OpenSea) by capping each glyph type at `MAX_GLYPHS`.
///         The animation_url page can read the full bit-packed sequence from
///         the extension to render every trade chronologically on a canvas.
///
///         Glyph positions are derived from `keccak256(idx, type)` so the
///         layout is deterministic per token but visually scattered.
contract LiquidityLayerSpriteRenderer is IMetadataRenderer {
    using Strings for uint256;

    /// @notice The counter extension this renderer reads buy/sell totals from.
    LiquidityLayerCounterPoolExtension public immutable extension;

    /// @notice Base URL for the canvas animation page. The renderer appends
    ///         `/<chainId>/<tokenAddress>` so a single hosted page can serve
    ///         all tokens that use this renderer.
    string public animationUrlBase;

    /// @notice Maximum glyphs rendered per type (buy / sell) in the SVG.
    ///         Capped to keep tokenURI() output size reasonable for indexers.
    ///         Beyond this the SVG visually saturates anyway, and the canvas
    ///         animation has the full sequence.
    uint256 public constant MAX_GLYPHS = 200;

    /// @notice SVG canvas dimensions (square).
    uint256 internal constant VIEW_SIZE = 1000;

    /// @param extension_ The counter pool extension to query.
    /// @param animationUrlBase_ Base URL for the animation page (no trailing slash).
    constructor(LiquidityLayerCounterPoolExtension extension_, string memory animationUrlBase_) {
        extension = extension_;
        animationUrlBase = animationUrlBase_;
    }

    /// @inheritdoc IMetadataRenderer
    function contractURI(address token) external view returns (string memory) {
        IRenderableToken t = IRenderableToken(token);
        (uint128 buys, uint128 sells) = extension.countsForToken(token);

        string memory svg = _buildSvg(t.imageUrl(), buys, sells, token);
        string memory json = string.concat(
            '{"name":"',
            LibString.escapeJSON(t.name()),
            '","symbol":"',
            LibString.escapeJSON(t.symbol()),
            '","description":"',
            _buildDescription(buys, sells),
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","animation_url":"',
            _animationUrl(token),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ─── SVG composition ──────────────────────────────────────────────

    function _buildSvg(string memory baseImage, uint128 buys, uint128 sells, address token)
        internal
        pure
        returns (string memory)
    {
        // Header + base image filling the viewBox.
        string memory header = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ',
            VIEW_SIZE.toString(),
            " ",
            VIEW_SIZE.toString(),
            '" preserveAspectRatio="xMidYMid meet">',
            '<image href="',
            baseImage,
            '" width="',
            VIEW_SIZE.toString(),
            '" height="',
            VIEW_SIZE.toString(),
            '"/>'
        );

        // Glyph layers — buy = '+', sell = '−'. Each glyph type has its own
        // hash domain so positions don't collide across types.
        string memory plusGlyphs = _glyphLayer(token, _capped(buys), 0, "+", "#22c55e");
        string memory minusGlyphs = _glyphLayer(token, _capped(sells), 1, unicode"−", "#ef4444");

        return string.concat(header, plusGlyphs, minusGlyphs, "</svg>");
    }

    function _glyphLayer(
        address token,
        uint256 count,
        uint256 typeSalt,
        string memory glyph,
        string memory color
    ) internal pure returns (string memory) {
        if (count == 0) return "";
        string memory layer = string.concat(
            '<g fill="',
            color,
            '" font-family="monospace" font-size="40" font-weight="700" text-anchor="middle">'
        );
        for (uint256 i = 0; i < count; i++) {
            (uint256 x, uint256 y) = _glyphPosition(token, typeSalt, i);
            layer = string.concat(
                layer, '<text x="', x.toString(), '" y="', y.toString(), '">', glyph, "</text>"
            );
        }
        return string.concat(layer, "</g>");
    }

    /// @dev Deterministic, well-distributed (token, type, idx) → (x, y) in [0, VIEW_SIZE).
    function _glyphPosition(address token, uint256 typeSalt, uint256 idx)
        internal
        pure
        returns (uint256 x, uint256 y)
    {
        bytes32 h = keccak256(abi.encode(token, typeSalt, idx));
        x = uint256(h) % VIEW_SIZE;
        y = (uint256(h) >> 128) % VIEW_SIZE;
    }

    function _capped(uint128 n) internal pure returns (uint256) {
        return n > MAX_GLYPHS ? MAX_GLYPHS : uint256(n);
    }

    // ─── JSON helpers ─────────────────────────────────────────────────

    function _buildDescription(uint128 buys, uint128 sells) internal pure returns (string memory) {
        return
            string.concat(
                "Buys: ", uint256(buys).toString(), " | Sells: ", uint256(sells).toString()
            );
    }

    function _animationUrl(address token) internal view returns (string memory) {
        return string.concat(
            animationUrlBase, "/", block.chainid.toString(), "/", Strings.toHexString(token)
        );
    }
}
