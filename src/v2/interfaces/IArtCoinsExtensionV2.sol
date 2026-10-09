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
    ///         The factory approves `extensionSupply` of `token` to this
    ///         extension before the call; the extension must pull exactly that
    ///         amount with `transferFrom` during the call, or the launch reverts
    ///         `SupplyNotPulled`. The factory sends the extension's configured
    ///         eth as `msg.value` (revert InvalidMsgValue on a mismatch).
    /// @param  config         The full launch config.
    /// @param  poolKey        The pool the factory just created.
    /// @param  token          The launched coin.
    /// @param  extensionSupply Coin supply approved to this extension, to be pulled in full.
    /// @param  extensionIndex This extension's index in `config.extensions`.
    function receiveTokens(
        IArtCoinsFactoryV2.DeploymentConfigV2 calldata config,
        PoolKey calldata poolKey,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable;
}
