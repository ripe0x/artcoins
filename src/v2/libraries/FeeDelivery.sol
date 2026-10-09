// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFeeEscrowV2} from "../interfaces/IArtCoinsFeeEscrowV2.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title  FeeDelivery
/// @notice Pushes a fee to its recipient and credits the recipient in the fee
///         escrow when the push fails. Used by the hook, locker, fee swapper and
///         protocol fee controller.
/// @dev    Invariant: while the calling contract is an escrow depositor (and, for
///         erc20, the token lets the escrow pull from the caller), the amount
///         reaches `to` or the escrow balance of `to`. An erc20 `transfer` that
///         returns false or fewer than 32 bytes reverts `InvalidTransferReturn`,
///         and a token without code reverts, leaving the amount with the caller.
///         Callers must reject `to == address(0)`: a native push to the zero
///         address succeeds and burns the amount.
library FeeDelivery {
    /// @notice An erc20 `transfer` returned false or fewer than 32 bytes of data.
    error InvalidTransferReturn();

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

    /// @notice Transfers `amount` of `token` to `to`, crediting `to` in `escrow` when the
    ///         transfer reverts.
    /// @dev Accepts tokens that return nothing or true. When `transfer` reverts, `amount` is
    ///      approved to `escrow` and `storeFees` pulls it. A `transfer` that returns false or
    ///      fewer than 32 bytes reverts `InvalidTransferReturn` and the amount stays with the
    ///      caller. A token without code reverts in the approval (`ApproveFailed`). An
    ///      `amount` of zero returns true.
    /// @param escrow Fee escrow for the fallback credit.
    /// @param token Erc20 to send.
    /// @param to Recipient.
    /// @param amount Amount in token base units.
    /// @return pushed True when `to` received the tokens directly or `amount == 0`.
    function sendErc20(address escrow, address token, address to, uint256 amount)
        internal
        returns (bool pushed)
    {
        if (amount == 0) return true;
        bool returnedFalse;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xa9059cbb00000000000000000000000000000000000000000000000000000000) // transfer(address,uint256)
            mstore(add(m, 0x04), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 0x24), amount)
            // scratch space 0x00 receives at most 32 bytes of returndata.
            mstore(0x00, 0)
            let ok := call(gas(), token, 0, m, 0x44, 0x00, 0x20)
            // ok and (returned true, or returned nothing from a contract)
            pushed := and(
                ok,
                or(
                    and(eq(mload(0x00), 1), gt(returndatasize(), 0x1f)),
                    and(iszero(returndatasize()), gt(extcodesize(token), 0))
                )
            )
            // a call that succeeded with returndata that is not a true word
            returnedFalse := and(
                ok,
                and(
                    iszero(iszero(returndatasize())),
                    iszero(and(gt(returndatasize(), 0x1f), eq(mload(0x00), 1)))
                )
            )
        }
        if (returnedFalse) revert InvalidTransferReturn();
        if (!pushed) {
            SafeTransferLib.safeApproveWithRetry(token, escrow, amount);
            IArtCoinsFeeEscrowV2(escrow).storeFees(to, token, amount);
        }
    }
}
