// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IRenderableTokenV2
/// @notice The coin fields the v2 renderers read. Every `ArtCoinsTokenV2` implements them.
interface IRenderableTokenV2 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    /// @notice Free form description, set by the coin admin.
    function description() external view returns (string memory);
    /// @notice Image url, set by the coin admin.
    function imageUrl() external view returns (string memory);
}
