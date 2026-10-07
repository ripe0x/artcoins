// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFeeEscrowV2} from "../interfaces/IArtCoinsFeeEscrowV2.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title  FeeDelivery
/// @notice Push a fee to its recipient; if the push fails, credit the
///         recipient in the fee escrow instead. Shared by the v2 hook, locker,
///         fee swapper and protocol fee controller (DESIGN d1).
/// @dev    Invariant: once the calling contract is an escrow depositor (and,
///         for erc20, the token lets the escrow pull from the caller), every
///         wei reaches `to` or `to`'s escrow balance. The exceptions are an
///         erc20 `transfer` that returns false and a token without code, which
///         revert the call.
///         Callers must reject `to == address(0)` before calling: a native
///         push to the zero address succeeds and burns the amount.
library FeeDelivery {
    /// @notice An erc20 `transfer` returned a value other than true.
    error TransferReturnedFalse();

    /// @notice Sends `amount` wei to `to` forwarding at most `gasCap` gas.
    ///         Returndata is never copied (no returndata bomb). On failure the
    ///         amount is credited to `to` in `escrow`.
    /// @return pushed True when `to` received the eth directly (or `amount == 0`).
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

    /// @notice Transfers `amount` of `token` to `to`. Accepts tokens that
    ///         return nothing or `true`. When `transfer` reverts, the exact
    ///         amount is approved to `escrow` and `storeFees` pulls it. When
    ///         `transfer` returns false, the call reverts with
    ///         `TransferReturnedFalse` and the amount stays with the caller.
    ///         A token without code reverts in the approval (`ApproveFailed`).
    /// @return pushed True when `to` received the tokens directly (or `amount == 0`).
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
            // a call that succeeded with a returned word other than 1
            returnedFalse := and(ok, and(gt(returndatasize(), 0x1f), iszero(eq(mload(0x00), 1))))
        }
        if (returnedFalse) revert TransferReturnedFalse();
        if (!pushed) {
            SafeTransferLib.safeApproveWithRetry(token, escrow, amount);
            IArtCoinsFeeEscrowV2(escrow).storeFees(to, token, amount);
        }
    }
}
