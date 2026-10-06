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
    /// @param minTokenOut Minimum coin out as reported by the pool. Must be nonzero.
    struct DevBuyDataV2 {
        address recipient;
        address refundRecipient;
        uint128 minTokenOut;
    }

    error InvalidExtensionData();
    error InvalidDevBuyBps();
    error ZeroRecipient();
    error ZeroMinOut();
    error WrongExtensionEntry();
    error InvalidPoolKey();
    error NotPoolManager();
    error SlippageExceeded(uint256 out, uint256 minOut);
    error EthRefundFailed();
    error Unauthorized();
    error ZeroAddress();

    /// @param token Bought coin.
    /// @param recipient Receiver of the coin.
    /// @param ethSpent Eth the pool took, skim included.
    /// @param tokenAmount Coin amount reported by the pool.
    /// @param ethRefunded Unspent eth sent to `refundRecipient`.
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
