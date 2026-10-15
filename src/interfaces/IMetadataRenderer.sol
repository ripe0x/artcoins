// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IMetadataRenderer
/// @notice Renderer a coin admin can set on a v2 coin with `setMetadataRenderer`. The coin
///         calls `contractURI(token)` on every `contractURI` and `tokenURI` read.
interface IMetadataRenderer {
    /// @notice Returns the ERC-7572 contract metadata URI for `token`.
    /// @param token The coin the metadata describes.
    /// @return A data URI with json, or an https url.
    function contractURI(address token) external view returns (string memory);
}
