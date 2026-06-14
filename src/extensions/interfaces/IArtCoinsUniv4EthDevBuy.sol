// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsExtension} from "../../interfaces/IArtCoinsExtension.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IArtCoinsUniv4EthDevBuy
/// @notice Interface for the Uniswap v4 ETH dev-buy extension. Adds
///         native-ETH pool support (the prior extension reverts atomically
///         when the artcoin's pair is `address(0)`) and a final-leg
///         `tokenAmountOutMinimum` for slippage protection on the
///         artcoin-buy leg (the prior version hardcodes 1).
interface IArtCoinsUniv4EthDevBuy is IArtCoinsExtension {
    /// @notice Init data for the dev buy.
    /// @param pairedTokenPoolKey Pool key to swap W/ETH → paired token (only
    ///        used when paired token is not WETH and not native ETH).
    /// @param pairedTokenAmountOutMinimum Minimum paired token out from the
    ///        W/ETH hop (only used when intermediate hop runs).
    /// @param tokenAmountOutMinimum Minimum artcoin out from the final leg.
    ///        ADDED: the prior version hardcoded `1` here, leaving the dev buy
    ///        sandwich-vulnerable. Callers must now specify a real floor.
    /// @param recipient Address to receive the bought tokens.
    struct Univ4EthDevBuyExtensionData {
        PoolKey pairedTokenPoolKey;
        uint128 pairedTokenAmountOutMinimum;
        uint128 tokenAmountOutMinimum;
        address recipient;
    }

    /// @notice Reverts when the caller is not authorized.
    error Unauthorized();
    /// @notice Reverts when the extension is configured with non-zero token bps (not allowed).
    error InvalidEthDevBuyPercentage();
    /// @notice Reverts when the supplied paired-token pool key isn't a W/ETH pair with the paired token.
    error InvalidPairedTokenPoolKey();

    /// @notice Emitted when a dev buy completes.
    /// @param token The bought token.
    /// @param user The recipient of the tokens.
    /// @param ethAmount ETH supplied.
    /// @param tokenAmount Tokens received.
    event EthDevBuy(
        address indexed token, address indexed user, uint256 ethAmount, uint256 tokenAmount
    );
}
