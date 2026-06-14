// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Interface for custom metadata renderers that generate on-chain art/metadata
interface IMetadataRenderer {
    /// @notice Returns contract-level metadata URI per ERC-7572
    /// @param token The token contract address to generate metadata for
    /// @return URI string (data URI with JSON, or HTTPS URL)
    function contractURI(address token) external view returns (string memory);
}
