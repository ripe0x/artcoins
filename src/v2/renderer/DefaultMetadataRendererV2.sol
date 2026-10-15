// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMetadataRenderer} from "../../interfaces/IMetadataRenderer.sol";
import {IRenderableTokenV2} from "./IRenderableTokenV2.sol";
import {SvgText} from "./SvgText.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title  DefaultMetadataRendererV2
/// @notice Metadata renderer returning an ERC-7572 json data uri of the coin's name, symbol,
///         description and image url. Stateless and ownerless.
/// @dev    Each field is capped by `SvgText`, cleaned to valid utf8 and json escaped. The json is
///         well formed for any stored bytes and the gas is bounded by the caps. An image url
///         longer than `SvgText.URL_MAX` is replaced by an empty string.
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
            SvgText.jsonText(t.description(), SvgText.DESC_MAX),
            '","image":"',
            SvgText.jsonUrl(t.imageUrl(), SvgText.URL_MAX),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
