// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../ArtCoinsToken.sol";
import {IMetadataRenderer} from "../interfaces/IMetadataRenderer.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @title DefaultMetadataRenderer
/// @notice Default renderer — reads token fields, returns ERC-7572 JSON data URI.
contract DefaultMetadataRenderer is IMetadataRenderer {
    /// @notice Builds a base64-encoded data URI from the token's on-chain fields.
    /// @param token The ArtCoins token to render for.
    /// @return The ERC-7572 metadata data URI.
    function contractURI(address token) external view override returns (string memory) {
        ArtCoinsToken t = ArtCoinsToken(token);
        string memory json = string.concat(
            '{"name":"',
            LibString.escapeJSON(t.name()),
            '","symbol":"',
            LibString.escapeJSON(t.symbol()),
            '","description":"',
            LibString.escapeJSON(t.metadata()),
            '","image":"',
            LibString.escapeJSON(t.imageUrl()),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
