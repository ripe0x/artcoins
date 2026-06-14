// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal subset of the Uniswap V3 SwapRouter interface used by ArtCoins.
/// @dev Only the single-pool exact-input swap is exposed.
interface ISwapRouterV3 {
    /// @notice Parameters for `exactInputSingle`.
    /// @param tokenIn Input token address.
    /// @param tokenOut Output token address.
    /// @param fee Fee tier of the V3 pool, in hundredths of a bip (e.g. `3000` = 0.30%).
    /// @param recipient Address to receive the output tokens.
    /// @param amountIn Exact amount of `tokenIn` to spend.
    /// @param amountOutMinimum Minimum acceptable amount of `tokenOut` (slippage guard).
    /// @param sqrtPriceLimitX96 Price limit in Q64.96 form (`0` = no limit).
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swap an exact `amountIn` of one token for as much as possible of another.
    /// @param params Swap configuration. See `ExactInputSingleParams`.
    /// @return amountOut Amount of `tokenOut` actually received.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
