// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFeeLocker} from "./IArtCoinsFeeLocker.sol";

/// @title  IArtCoinsFeeEscrow
/// @notice Extends `IArtCoinsFeeLocker` with first-class native-ETH support.
///         Allowlisted depositors call `storeFeesNative{value: amount}(feeOwner)`
///         to credit native-ETH fees; fee owners (or anyone on their behalf)
///         call `claim(feeOwner, address(0))` to withdraw the balance as
///         native ETH.
/// @dev    The native-ETH slot lives in the `feesToClaim[feeOwner][address(0)]`
///         storage — `address(0)` is the V4 sentinel for native ETH, mirroring
///         the `Currency.unwrap` convention. The ERC20 path is the inherited
///         `IArtCoinsFeeLocker` surface.
interface IArtCoinsFeeEscrow is IArtCoinsFeeLocker {
    /// @notice Reverts when `storeFeesNative` is called with `msg.value == 0`.
    error ZeroNativeDeposit();
    /// @notice Reverts when the native-ETH transfer to the fee owner fails on `claim`.
    error NativeTransferFailed();
    /// @notice Reverts when `claimTo` is called with `recipient == address(0)`.
    error ZeroRecipient();

    /// @notice Emitted when native ETH is stored against a fee owner's balance.
    /// @param sender The depositor that called `storeFeesNative`.
    /// @param feeOwner The account credited.
    /// @param balance Updated total native-ETH balance after the deposit.
    /// @param amount Amount of ETH credited (equals `msg.value`).
    event StoreNative(
        address indexed sender, address indexed feeOwner, uint256 balance, uint256 amount
    );
    /// @notice Emitted when a fee owner's native-ETH balance is claimed.
    /// @param feeOwner Owner of the fees.
    /// @param amountClaimed Native-ETH amount transferred.
    event ClaimNative(address indexed feeOwner, uint256 amountClaimed);
    /// @notice Emitted when a fee owner redirects their balance to a chosen recipient
    ///         via `claimTo`.
    /// @param feeOwner Owner of the fees.
    /// @param recipient Address that received the balance.
    /// @param token Token claimed (address(0) = native ETH).
    /// @param amountClaimed Amount transferred.
    event ClaimedTo(
        address indexed feeOwner,
        address indexed recipient,
        address indexed token,
        uint256 amountClaimed
    );

    /// @notice Stores `msg.value` native ETH against `feeOwner`'s balance under
    ///         the `address(0)` slot. Callable only by allowlisted depositors.
    /// @dev    Reverts with `ZeroNativeDeposit` if `msg.value == 0`. The amount
    ///         credited equals `msg.value` exactly — there is no fee-on-transfer
    ///         concern for native ETH, so balance-delta accounting is unnecessary.
    /// @param  feeOwner The account to credit.
    function storeFeesNative(address feeOwner) external payable;

    /// @notice Redirects `feeOwner`'s `token` balance to a different `recipient`.
    ///         Restricted to `msg.sender == feeOwner` — only the credited owner
    ///         can redirect their own balance.
    ///
    ///         Escape hatch for the case where `feeOwner` is a contract that
    ///         can't receive its credited balance (e.g., a non-payable contract
    ///         on the native-ETH path, which would otherwise lock the balance
    ///         indefinitely via `claim`'s `NativeTransferFailed` revert).
    /// @dev    Reverts with `Unauthorized` if `msg.sender != feeOwner`,
    ///         `ZeroRecipient` if `recipient == address(0)`, or
    ///         `NoFeesToClaim` if the balance is zero. For native ETH, reverts
    ///         with `NativeTransferFailed` if the recipient also rejects ETH.
    /// @param  feeOwner The account whose balance is being claimed.
    /// @param  token The token to claim (`address(0)` = native ETH).
    /// @param  recipient The address that receives the balance.
    function claimTo(address feeOwner, address token, address payable recipient) external;
}
