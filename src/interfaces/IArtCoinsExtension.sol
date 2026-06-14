// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactory} from "./IArtCoinsFactory.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IArtCoinsExtension
/// @notice Interface implemented by extension contracts that receive token allocations
///         from the factory during deployment.
interface IArtCoinsExtension is IERC165 {
    /// @notice Reverts when `msg.value` is non-zero but the extension expects zero.
    error InvalidMsgValue();

    /// @notice Called by the factory with the extension's token allocation and optional ETH.
    /// @dev The factory approves `extensionSupply` of `token` to `msg.sender == address(this)`
    ///      before calling this.
    /// @param deploymentConfig The full deployment config for context.
    /// @param poolKey The pool key of the newly created Uniswap v4 pool.
    /// @param token The new token address.
    /// @param extensionSupply Amount of tokens allocated to this extension.
    /// @param extensionIndex The index of this extension in the deployment config.
    function receiveTokens(
        IArtCoinsFactory.DeploymentConfig calldata deploymentConfig,
        PoolKey memory poolKey,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable;
}
