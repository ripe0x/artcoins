// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsExtension} from "../interfaces/IArtCoinsExtension.sol";
import {IArtCoinsFactory} from "../interfaces/IArtCoinsFactory.sol";

import {IArtCoinsUniv4EthDevBuy} from "./interfaces/IArtCoinsUniv4EthDevBuy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {
    IUniversalRouter
} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @title  ArtCoinsUniv4EthDevBuy
/// @notice Dev-buy extension. Performs an immediate ETH-funded "dev buy"
///         of the newly deployed artcoin through Uniswap v4 at deploy time.
///
///         Native-ETH-paired artcoins swap ETH directly through the artcoin's
///         native-ETH pool (no wrap, no intermediate hop), so the path never
///         calls `IERC20(address(0)).approve`; WETH-paired artcoins use the
///         WETH/intermediate-hop branch.
///
///         The final artcoin-buy leg takes an explicit `tokenAmountOutMinimum`
///         from the extension data for slippage protection.
contract ArtCoinsUniv4EthDevBuy is ReentrancyGuard, IArtCoinsUniv4EthDevBuy {
    /// @notice The factory authorized to call `receiveTokens`.
    IArtCoinsFactory public immutable factory;
    /// @notice WETH instance (still used for WETH-paired artcoins).
    IWETH9 public immutable weth;
    /// @notice Uniswap Universal Router used to execute swaps.
    IUniversalRouter public immutable universalRouter;
    /// @notice Permit2 instance.
    IPermit2 public immutable permit2;

    /// @dev Restricts a function to the factory.
    modifier onlyFactory() {
        if (msg.sender != address(factory)) revert Unauthorized();
        _;
    }

    /// @param factory_ The factory.
    /// @param weth_ WETH address.
    /// @param universalRouter_ Universal Router address.
    /// @param permit2_ Permit2 address.
    constructor(address factory_, address weth_, address universalRouter_, address permit2_) {
        factory = IArtCoinsFactory(factory_);
        weth = IWETH9(weth_);
        universalRouter = IUniversalRouter(universalRouter_);
        permit2 = IPermit2(permit2_);
    }

    /// @notice Called by the factory to perform the dev buy with the supplied ETH.
    /// @param deploymentConfig Full deployment config.
    /// @param tokenPoolKey The newly created v4 pool key for the artcoin.
    /// @param token The newly deployed token.
    /// @param extensionSupply Must be zero (this extension does not take tokens).
    /// @param extensionIndex Index of this extension in the deployment config.
    function receiveTokens(
        IArtCoinsFactory.DeploymentConfig calldata deploymentConfig,
        PoolKey memory tokenPoolKey,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable nonReentrant onlyFactory {
        if (
            deploymentConfig.extensionConfigs[extensionIndex].msgValue != msg.value
                || deploymentConfig.extensionConfigs[extensionIndex].msgValue == 0
        ) {
            revert IArtCoinsExtension.InvalidMsgValue();
        }

        if (
            deploymentConfig.extensionConfigs[extensionIndex].extensionBps != 0
                || extensionSupply != 0
        ) {
            revert InvalidEthDevBuyPercentage();
        }

        Univ4EthDevBuyExtensionData memory devBuyData = abi.decode(
            deploymentConfig.extensionConfigs[extensionIndex].extensionData,
            (Univ4EthDevBuyExtensionData)
        );

        uint256 tokenAmount = _performDevBuy(
            token, deploymentConfig.poolConfig.pairedToken, tokenPoolKey, devBuyData
        );

        IERC20(token).transfer(devBuyData.recipient, tokenAmount);

        emit EthDevBuy(token, devBuyData.recipient, msg.value, tokenAmount);
    }

    /// @dev Routes the dev-buy swap based on the artcoin's pair currency:
    ///        - Native ETH (`address(0)`): direct V4 swap, no wrap.   ← V3 ADDITION
    ///        - WETH (`address(weth)`): wrap ETH, swap WETH → artcoin.
    ///        - Other ERC20: intermediate hop W/ETH → paired, then paired → artcoin.
    function _performDevBuy(
        address token,
        address pairedToken,
        PoolKey memory tokenPoolKey,
        Univ4EthDevBuyExtensionData memory devBuyData
    ) internal returns (uint256) {
        uint128 amountPairedToken = uint128(msg.value);

        // ─── native-ETH branch ───────────────────────────────────────
        //
        // For native-ETH-paired artcoins, swap ETH directly through the
        // artcoin's pool. No wrap (V4 supports native ETH natively), no
        // intermediate hop (msg.value IS the input currency).
        if (pairedToken == address(0)) {
            return _univ4Swap(
                tokenPoolKey, address(0), token, amountPairedToken, devBuyData.tokenAmountOutMinimum
            );
        }

        // ─── intermediate-hop branch (paired is non-WETH ERC20) ────────
        if (pairedToken != address(weth)) {
            PoolKey memory pairedTokenPoolKey = devBuyData.pairedTokenPoolKey;
            uint128 pairedTokenAmountOutMinimum = devBuyData.pairedTokenAmountOutMinimum;
            address currency0 = Currency.unwrap(pairedTokenPoolKey.currency0);
            address currency1 = Currency.unwrap(pairedTokenPoolKey.currency1);

            bool pairedTokenIsToken0 = currency0 == pairedToken;
            if (pairedTokenIsToken0) {
                if (currency1 != address(weth)) {
                    revert InvalidPairedTokenPoolKey();
                }
            } else {
                if (
                    (currency0 != address(weth) && currency0 != address(0))
                        || currency1 != pairedToken
                ) {
                    revert InvalidPairedTokenPoolKey();
                }
            }

            if (pairedTokenIsToken0 ? currency1 == address(weth) : currency0 == address(weth)) {
                weth.deposit{value: amountPairedToken}();
                IERC20(weth).approve(address(permit2), type(uint256).max);
                permit2.approve(
                    address(weth),
                    address(universalRouter),
                    amountPairedToken,
                    uint48(block.timestamp)
                );
            }

            amountPairedToken = uint128(
                _univ4Swap(
                    pairedTokenPoolKey,
                    pairedTokenIsToken0 ? currency1 : currency0,
                    pairedTokenIsToken0 ? currency0 : currency1,
                    amountPairedToken,
                    pairedTokenAmountOutMinimum
                )
            );
        }

        // ─── WETH-paired branch (or post-intermediate-hop final leg) ───
        if (pairedToken == address(weth)) {
            weth.deposit{value: amountPairedToken}();
        }

        IERC20(pairedToken).approve(address(permit2), type(uint256).max);
        permit2.approve(
            pairedToken, address(universalRouter), amountPairedToken, uint48(block.timestamp)
        );

        // Use the caller-supplied tokenAmountOutMinimum for slippage protection.
        return _univ4Swap(
            tokenPoolKey, pairedToken, token, amountPairedToken, devBuyData.tokenAmountOutMinimum
        );
    }

    function _univ4Swap(
        PoolKey memory poolKey,
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) internal returns (uint256) {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);

        bool tokenInIsToken0 = Currency.unwrap(poolKey.currency0) == tokenIn;

        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: tokenInIsToken0 ? true : false,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                hookData: bytes("")
            })
        );

        params[1] = abi.encode(tokenIn, uint256(amountIn));
        params[2] = abi.encode(tokenOut, 1);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // For native-ETH input, `tokenOut` is an ERC20 → balanceOf works.
        // For native-ETH output (not used here, but for completeness), would
        // need different accounting.
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        universalRouter.execute{value: tokenIn == address(0) ? amountIn : 0}(
            commands, inputs, block.timestamp
        );

        uint256 tokenOutAfter = IERC20(tokenOut).balanceOf(address(this));

        return tokenOutAfter - tokenOutBefore;
    }

    /// @notice ERC-165 introspection.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsExtension).interfaceId;
    }
}
