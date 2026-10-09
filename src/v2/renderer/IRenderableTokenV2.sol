// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IRenderableTokenV2
/// @notice The token fields the v2 renderers read. `IArtCoinsTokenV2` plus erc20
///         is a superset, so any v2 art coin can be rendered.
interface IRenderableTokenV2 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    /// @notice Free form description, set by the coin admin.
    function description() external view returns (string memory);
    /// @notice Image url, set by the token admin.
    function imageUrl() external view returns (string memory);
}
