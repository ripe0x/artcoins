// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFeeEscrowV2} from "../interfaces/IArtCoinsFeeEscrowV2.sol";

/// @title  FeeDelivery
/// @notice Pushes native eth to a recipient and credits the recipient in the fee
///         escrow when the push fails. Used by the hook and the protocol fee
///         controller.
/// @dev    Invariant: while the calling contract is an escrow depositor, the amount
///         reaches `to` or the escrow balance of `to`. Callers must reject
///         `to == address(0)`: a native push to the zero address succeeds and
///         burns the amount.
library FeeDelivery {
    /// @notice Sends `amount` wei to `to` with at most `gasCap` gas.
    /// @dev Returndata is not copied. On failure the amount is credited to `to` in `escrow`
    ///      through `storeFeesNative`, which reverts `NotDepositor` when the caller is not an
    ///      escrow depositor. An `amount` of zero returns true.
    /// @param escrow Fee escrow for the fallback credit.
    /// @param to Recipient.
    /// @param amount Amount in wei.
    /// @param gasCap Gas forwarded to `to`.
    /// @return pushed True when `to` received the eth directly or `amount == 0`.
    function sendNative(address escrow, address to, uint256 amount, uint256 gasCap)
        internal
        returns (bool pushed)
    {
        if (amount == 0) return true;
        assembly ("memory-safe") {
            pushed := call(gasCap, to, amount, codesize(), 0x00, codesize(), 0x00)
        }
        if (!pushed) {
            IArtCoinsFeeEscrowV2(escrow).storeFeesNative{value: amount}(to);
        }
    }
}
