// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../ArtCoinsToken.sol";
import {IArtCoinsFactory} from "../interfaces/IArtCoinsFactory.sol";
import {TaxConfig} from "../interfaces/IArtCoinsTaxable.sol";

/// @title ArtCoinsDeployer
/// @notice Deploys a new `ArtCoinsToken` contract directly via CREATE2 with a
///         deterministic salt derived from `(tokenAdmin, tokenConfig.salt)`.
/// @dev No proxy. Solady's `ERC20` short-circuit (allowance(_, PERMIT2) returns
///      max; approve(PERMIT2, x != max) reverts) is what enables the 1-tx EOA
///      sell flow; that requires construction-time state, which is incompatible
///      with proxy delegation. Each launched coin is its own full-bytecode
///      deploy.
library ArtCoinsDeployer {
    /// @notice Deploys a new ArtCoinsToken with the transfer tax DORMANT and
    ///         returns its address. This is the path every standard art coin
    ///         uses.
    /// @param tokenConfig Token configuration (name, symbol, salt, metadata, admin, renderer).
    /// @param supply Total token supply minted to the caller (factory).
    function deployToken(IArtCoinsFactory.TokenConfig memory tokenConfig, uint256 supply)
        external
        returns (address tokenAddress)
    {
        return _deploy(tokenConfig, supply, _emptyTaxConfig());
    }

    /// @notice Deploys a new ArtCoinsToken with a venue-scoped buy-side
    ///         transfer tax configured. Used only by deploys that opt in
    ///         (currently PC's 111PUNKS).
    /// @param tokenConfig Token configuration (name, symbol, salt, metadata, admin, renderer).
    /// @param supply Total token supply minted to the caller (factory).
    /// @param taxConfig Venue-scoped tax configuration. `enabled = false`
    ///        behaves identically to `deployToken`.
    function deployTokenWithTax(
        IArtCoinsFactory.TokenConfig memory tokenConfig,
        uint256 supply,
        TaxConfig memory taxConfig
    ) external returns (address tokenAddress) {
        return _deploy(tokenConfig, supply, taxConfig);
    }

    function _deploy(
        IArtCoinsFactory.TokenConfig memory tokenConfig,
        uint256 supply,
        TaxConfig memory taxConfig
    ) private returns (address tokenAddress) {
        ArtCoinsToken token = new ArtCoinsToken{
            salt: keccak256(abi.encode(tokenConfig.tokenAdmin, tokenConfig.salt))
        }(
            tokenConfig.name,
            tokenConfig.symbol,
            supply,
            tokenConfig.tokenAdmin,
            tokenConfig.image,
            tokenConfig.metadata,
            tokenConfig.context,
            tokenConfig.renderer,
            taxConfig
        );

        tokenAddress = address(token);
    }

    /// @dev A fully-dormant tax config (`enabled = false`, empty sets). The
    ///      token treats this as "behave exactly like a vanilla ERC20."
    function _emptyTaxConfig() private pure returns (TaxConfig memory tc) {
        // All fields default to zero / false / empty arrays.
    }
}
