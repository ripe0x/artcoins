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
    /// @notice `msg.value` does not equal the extension's configured eth.
    error InvalidMsgValue();

    /// @notice Called once by the factory during the launch tx. Factory only.
    ///         The factory has already transferred `extensionSupply` of `token`
    ///         to this extension and sends the extension's configured eth as
    ///         `msg.value` (revert InvalidMsgValue on a mismatch).
    /// @param  config         The full launch config.
    /// @param  poolKey        The pool the factory just created.
    /// @param  token          The launched coin.
    /// @param  extensionSupply Coin supply already transferred in.
    /// @param  extensionIndex This extension's index in `config.extensions`.
    function receiveTokens(
        IArtCoinsFactoryV2.DeploymentConfigV2 calldata config,
        PoolKey calldata poolKey,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable;
}
