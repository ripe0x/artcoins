// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactoryV2} from "./IArtCoinsFactoryV2.sol";
import {IConstantsBound} from "./IConstantsBound.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IArtCoinsExtensionV2
/// @notice Launch extension: receives its supply share and eth from the
///         factory during the launch tx.
interface IArtCoinsExtensionV2 is IERC165, IConstantsBound {
    error InvalidMsgValue();

    function receiveTokens(
        IArtCoinsFactoryV2.DeploymentConfigV2 calldata config,
        PoolKey calldata poolKey,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable;
}
