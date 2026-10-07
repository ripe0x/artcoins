// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMetadataRenderer} from "../../interfaces/IMetadataRenderer.sol";
import {IRenderableTokenV2} from "./IRenderableTokenV2.sol";
import {SvgText} from "./SvgText.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title  DefaultMetadataRendererV2
/// @notice Reads the token fields and returns an ERC-7572 json data uri. No svg,
///         no html, no state, no owner.
/// @dev    Differences from v1: every field is bounded (`SvgText` caps), cleaned to
///         valid utf8 and then json escaped, so the json is well formed for any
///         bytes and the gas is bounded by the caps, not by what the token admin
///         stored. An image url longer than `SvgText.URL_MAX` is dropped.
contract DefaultMetadataRendererV2 is IMetadataRenderer {
    /// @inheritdoc IMetadataRenderer
    function contractURI(address token) external view override returns (string memory) {
        IRenderableTokenV2 t = IRenderableTokenV2(token);
        string memory json = string.concat(
            '{"name":"',
            SvgText.jsonText(t.name(), SvgText.NAME_MAX),
            '","symbol":"',
            SvgText.jsonText(t.symbol(), SvgText.SYMBOL_MAX),
            '","description":"',
            SvgText.jsonText(t.metadata(), SvgText.DESC_MAX),
            '","image":"',
            SvgText.jsonUrl(t.imageUrl(), SvgText.URL_MAX),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
