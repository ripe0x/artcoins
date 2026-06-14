// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsExtension} from "../../interfaces/IArtCoinsExtension.sol";
import {IArtCoinsFactory} from "../../interfaces/IArtCoinsFactory.sol";

import {IArtCoinsUniv4EthDevBuy} from "../interfaces/IArtCoinsUniv4EthDevBuy.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {
    IUniversalRouter
} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @title ArtCoinsUniv4EthDevBuy
/// @notice Extension that performs an immediate ETH-funded "dev buy" of the newly deployed token
///         through Uniswap v4, optionally hopping through an intermediate paired token.
contract ArtCoinsUniv4EthDevBuy is ReentrancyGuard, IArtCoinsUniv4EthDevBuy {
    /// @notice The factory authorized to call `receiveTokens`.
    IArtCoinsFactory public immutable factory;
    /// @notice WETH instance.
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
    /// @param tokenPoolKey The newly created v4 pool key for the token.
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
        // ensure that the msgValue matches what was requested and is not zero
        if (
            deploymentConfig.extensionConfigs[extensionIndex].msgValue != msg.value
                || deploymentConfig.extensionConfigs[extensionIndex].msgValue == 0
        ) {
            revert IArtCoinsExtension.InvalidMsgValue();
        }

        // check the vault percentage is zero
        if (
            deploymentConfig.extensionConfigs[extensionIndex].extensionBps != 0
                || extensionSupply != 0
        ) {
            revert InvalidEthDevBuyPercentage();
        }

        // decode the dev buy data
        Univ4EthDevBuyExtensionData memory devBuyData = abi.decode(
            deploymentConfig.extensionConfigs[extensionIndex].extensionData,
            (Univ4EthDevBuyExtensionData)
        );

        // perform the dev buy
        uint256 tokenAmount = _performDevBuy(
            token, deploymentConfig.poolConfig.pairedToken, tokenPoolKey, devBuyData
        );

        // transfer the token to the recipient
        IERC20(token).transfer(devBuyData.recipient, tokenAmount);

        emit EthDevBuy(token, devBuyData.recipient, msg.value, tokenAmount);
    }

    function _performDevBuy(
        address token,
        address pairedToken,
        PoolKey memory tokenPoolKey,
        Univ4EthDevBuyExtensionData memory devBuyData
    ) internal returns (uint256) {
        uint128 amountPairedToken = uint128(msg.value);

        // if the paired token is not weth, we need to swap from weth to paired token
        if (pairedToken != address(weth)) {
            PoolKey memory pairedTokenPoolKey = devBuyData.pairedTokenPoolKey;
            uint128 pairedTokenAmountOutMinimum = devBuyData.pairedTokenAmountOutMinimum;
            address currency0 = Currency.unwrap(pairedTokenPoolKey.currency0);
            address currency1 = Currency.unwrap(pairedTokenPoolKey.currency1);

            // check that the first pool to swap on is paired with W/ETH
            bool pairedTokenIsToken0 = currency0 == pairedToken;
            if (pairedTokenIsToken0) {
                // currency1 should be weth (if this was an ETH pair, currency0 would be ETH)
                if (currency1 != address(weth)) {
                    revert InvalidPairedTokenPoolKey();
                }
            } else {
                // currency0 should be W/ETH and currency1 should be paired token
                if (
                    (currency0 != address(weth) && currency0 != address(0))
                        || currency1 != pairedToken
                ) {
                    revert InvalidPairedTokenPoolKey();
                }
            }

            // convert ETH to WETH if needed and approve the spend
            // if paired token's paired token is weth
            if (pairedTokenIsToken0 ? currency1 == address(weth) : currency0 == address(weth)) {
                weth.deposit{value: amountPairedToken}();
                // ERC20→Permit2 grant set to max for Solady-token compatibility;
                // per-call scoping on the Permit2→router allowance below.
                IERC20(weth).approve(address(permit2), type(uint256).max);
                permit2.approve(
                    address(weth),
                    address(universalRouter),
                    amountPairedToken,
                    uint48(block.timestamp)
                );
            }

            // swap from W/ETH to paired token
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

        // if paired is weth, swap from ETH to weth
        // note: univ4 supports ETH as a currency, but we only allow WETH
        if (pairedToken == address(weth)) {
            weth.deposit{value: amountPairedToken}();
        }

        // approve the paired token to be spent by the router. ERC20→Permit2
        // is max for Solady compatibility; the actual amount/expiration is
        // bounded by the Permit2→router allowance below.
        IERC20(pairedToken).approve(address(permit2), type(uint256).max);
        permit2.approve(
            pairedToken, address(universalRouter), amountPairedToken, uint48(block.timestamp)
        );

        // swap from paired token to new token
        return _univ4Swap(tokenPoolKey, pairedToken, token, amountPairedToken, 1);
    }

    // perform a swap using the universal router
    function _univ4Swap(
        PoolKey memory poolKey,
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) internal returns (uint256) {
        // initiate a swap command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);

        // token ordering
        bool tokenInIsToken0 = Currency.unwrap(poolKey.currency0) == tokenIn;

        // First parameter: SWAP_EXACT_IN_SINGLE
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: tokenInIsToken0 ? true : false, // swapping tokenIn -> tokenOut
                amountIn: amountIn, // amount of tokenIn to swap
                amountOutMinimum: amountOutMinimum, // minimum amount we expect to receive
                hookData: bytes("") // no hook data needed, assuming we're using simple hooks
            })
        );

        // Second parameter: SETTLE_ALL
        params[1] = abi.encode(tokenIn, uint256(amountIn));

        // Third parameter: TAKE_ALL
        params[2] = abi.encode(tokenOut, 1);

        // Combine actions and params into inputs
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        universalRouter.execute{
            value: Currency.unwrap(poolKey.currency0) == address(0) ? amountIn : 0
        }(
            commands, inputs, block.timestamp
        );

        uint256 tokenOutAfter = IERC20(tokenOut).balanceOf(address(this));

        return tokenOutAfter - tokenOutBefore;
    }

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsExtension).interfaceId;
    }
}
