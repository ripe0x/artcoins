// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsExtensionV2} from "../../interfaces/IArtCoinsExtensionV2.sol";

/// @title  IArtCoinsUniv4EthDevBuyV2
/// @notice Buys the new art coin with native eth from its own pool during the
///         launch tx. Swaps through the PoolManager directly. Takes no supply.
interface IArtCoinsUniv4EthDevBuyV2 is IArtCoinsExtensionV2 {
    /// @notice `extensionData` layout: `abi.encode(recipient, refundRecipient, minTokenOut)`.
    /// @param recipient Receives the bought coin. Nonzero.
    /// @param refundRecipient Receives any eth the pool did not take (partial fill). Nonzero.
    /// @param minTokenOut Minimum coin out as reported by the pool, in coin base units. Nonzero.
    struct DevBuyDataV2 {
        address recipient;
        address refundRecipient;
        uint128 minTokenOut;
    }

    /// @notice `extensionData` is not exactly 96 bytes.
    error InvalidExtensionData();
    /// @notice The entry has a nonzero `extensionBps` or a nonzero supply share.
    error InvalidDevBuyBps();
    /// @notice `recipient` or `refundRecipient` is zero.
    error ZeroRecipient();
    /// @notice `minTokenOut` is zero.
    error ZeroMinOut();
    /// @notice The config entry at `extensionIndex` is not this contract.
    error WrongExtensionEntry();
    /// @notice The pool key is not native eth against the coin on the launch hook.
    error InvalidPoolKey();
    /// @notice The caller of `unlockCallback` is not the PoolManager.
    error NotPoolManager();
    /// @notice The pool returned less than `minTokenOut`.
    /// @param out Coin amount returned by the pool, in coin base units.
    /// @param minOut Required minimum, in coin base units.
    error SlippageExceeded(uint256 out, uint256 minOut);
    /// @notice The eth refund transfer failed.
    error NativeTransferFailed();
    /// @notice The caller of `receiveTokens` is not the factory.
    error Unauthorized();
    /// @notice A constructor address argument is zero.
    error ZeroAddress();
    /// @notice Eth sent to the contract outside an escrow claim.
    error UnexpectedEth();

    /// @notice The launch dev buy executed.
    /// @param token Bought coin.
    /// @param recipient Receiver of the coin.
    /// @param ethSpent Eth the pool took, skim included, in wei.
    /// @param tokenAmount Coin amount reported by the pool, in coin base units.
    /// @param ethRefunded Unspent eth sent to `refundRecipient`, in wei.
    /// @param refundRecipient Receiver of the refund.
    event EthDevBuy(
        address indexed token,
        address indexed recipient,
        uint256 ethSpent,
        uint256 tokenAmount,
        uint256 ethRefunded,
        address refundRecipient
    );
}
