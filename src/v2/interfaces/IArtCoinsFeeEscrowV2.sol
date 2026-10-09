// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IConstantsBound} from "./IConstantsBound.sol";

/// @title  IArtCoinsFeeEscrowV2
/// @notice Fallback store for fees whose direct push failed. Balances are keyed by
///         (feeOwner, token) and `token == address(0)` is native eth.
/// @dev    Credited balances are owed to the fee owner. `rescue` is bounded by
///         `balance - totalOwed[token]`. Amounts are in token base units (wei for eth).
interface IArtCoinsFeeEscrowV2 is IConstantsBound {
    // ── events ────────────────────────────────────────────────────────────

    /// @notice A depositor credited `feeOwner` with fees.
    /// @param depositor Caller of `storeFees` or `storeFeesNative`.
    /// @param feeOwner Account credited.
    /// @param token Credited token, `address(0)` for eth.
    /// @param amount Amount credited by this call.
    /// @param balance `balances[feeOwner][token]` after the credit.
    event FeesStored(
        address indexed depositor,
        address indexed feeOwner,
        address indexed token,
        uint256 amount,
        uint256 balance
    );

    /// @notice A fee owner balance was paid out and reset to zero.
    /// @param feeOwner Account whose balance was paid.
    /// @param token Paid token, `address(0)` for eth.
    /// @param recipient Account that received the funds.
    /// @param amount Amount paid.
    event FeesClaimed(
        address indexed feeOwner, address indexed token, address indexed recipient, uint256 amount
    );

    /// @notice `feeOwner` changed its `selfClaimOnly` flag.
    /// @param feeOwner Account that set the flag.
    /// @param on New flag value.
    event SelfClaimOnlySet(address indexed feeOwner, bool on);

    /// @notice The owner authorized a depositor.
    /// @param depositor Authorized account.
    /// @param core True when the depositor is permanent.
    event DepositorAdded(address indexed depositor, bool core);

    /// @notice The owner revoked a non core depositor.
    /// @param depositor Revoked account.
    event DepositorRemoved(address indexed depositor);

    /// @notice The owner withdrew funds held above `totalOwed`.
    /// @param token Withdrawn token, `address(0)` for eth.
    /// @param to Receiver.
    /// @param amount Amount withdrawn.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ── errors ────────────────────────────────────────────────────────────

    /// @notice Caller may not claim for this fee owner.
    error Unauthorized();
    /// @notice Caller is not an authorized depositor, or the account to remove is not one.
    error NotDepositor();
    /// @notice An address argument is the zero address.
    error ZeroAddress();
    /// @notice The fee owner or claim recipient is the zero address.
    error ZeroRecipient();
    /// @notice `storeFeesNative` was called with `msg.value == 0`.
    error ZeroNativeDeposit();
    /// @notice The fee owner balance for the token is zero.
    error NoFeesToClaim();
    /// @notice The native eth transfer to the recipient or rescue receiver failed.
    error NativeTransferFailed();
    /// @notice The depositor is core and cannot be removed or downgraded.
    /// @param depositor The core depositor.
    error CoreDepositor(address depositor);
    /// @notice A rescue amount exceeds the funds held above `totalOwed`.
    /// @param requested Requested amount.
    /// @param excess `balance - totalOwed[token]`, or zero when the balance is lower.
    error RescueExceedsExcess(uint256 requested, uint256 excess);

    // ── depositors ────────────────────────────────────────────────────────

    /// @notice Pulls `amount` of `token` from the caller and credits `feeOwner` with the amount received.
    /// @dev Callable by depositors. The caller must have approved this contract for `amount`.
    ///      A zero `amount` returns without effect. Reverts `NotDepositor`, `ZeroRecipient`
    ///      when `feeOwner` is zero, and `ZeroAddress` when `token` is zero.
    /// @param feeOwner Account to credit.
    /// @param token Erc20 to pull.
    /// @param amount Requested amount in token base units.
    function storeFees(address feeOwner, address token, uint256 amount) external;

    /// @notice Credits `msg.value` wei of native eth to `feeOwner`.
    /// @dev Callable by depositors. Reverts `NotDepositor`, `ZeroRecipient` when `feeOwner`
    ///      is zero, and `ZeroNativeDeposit` when `msg.value` is zero.
    /// @param feeOwner Account to credit.
    function storeFeesNative(address feeOwner) external payable;

    // ── claims ────────────────────────────────────────────────────────────

    /// @notice Sends the whole `token` balance of `feeOwner` to `feeOwner`.
    /// @dev Callable by anyone unless `selfClaimOnly[feeOwner]` is set, in which case only
    ///      `feeOwner` may call. Reverts `Unauthorized`, `ZeroRecipient` when `feeOwner` is zero,
    ///      `NoFeesToClaim` when the balance is zero, and `NativeTransferFailed` for a failed eth push.
    /// @param feeOwner Account whose balance is paid.
    /// @param token Token to pay, `address(0)` for eth.
    function claim(address feeOwner, address token) external;

    /// @notice Sends the whole `token` balance of `feeOwner` to `recipient`.
    /// @dev Callable by `feeOwner` only. Reverts `Unauthorized`, `ZeroRecipient` when
    ///      `recipient` is zero, `NoFeesToClaim`, and `NativeTransferFailed`.
    /// @param feeOwner Account whose balance is paid.
    /// @param token Token to pay, `address(0)` for eth.
    /// @param recipient Receiver of the funds.
    function claimTo(address feeOwner, address token, address payable recipient) external;

    /// @notice Sets whether only the caller may claim the caller's balances through `claim`.
    /// @dev Callable by any account for itself.
    /// @param on New flag value.
    function setSelfClaimOnly(bool on) external;

    // ── reads ─────────────────────────────────────────────────────────────

    /// @notice Credited balance owed to `feeOwner` in `token`, in base units.
    /// @param feeOwner Account to query.
    /// @param token Token to query, `address(0)` for eth.
    function balances(address feeOwner, address token) external view returns (uint256);

    /// @notice Sum of all credited balances in `token`, in base units.
    /// @param token Token to query, `address(0)` for eth.
    function totalOwed(address token) external view returns (uint256);

    /// @notice True when only `feeOwner` may call `claim` for its balances.
    /// @param feeOwner Account to query.
    function selfClaimOnly(address feeOwner) external view returns (bool);

    /// @notice True when `depositor` may call `storeFees` and `storeFeesNative`.
    /// @param depositor Account to query.
    function isDepositor(address depositor) external view returns (bool);

    /// @notice True when `depositor` is permanent and `removeDepositor` reverts for it.
    /// @param depositor Account to query.
    function isCoreDepositor(address depositor) external view returns (bool);

    // ── owner ─────────────────────────────────────────────────────────────

    /// @notice Authorizes `depositor`. A core depositor (hook, locker) is permanent.
    /// @dev Owner only. Re adding a non core depositor with `core == true` upgrades it.
    ///      Reverts `ZeroAddress`, and `CoreDepositor` when downgrading a core depositor.
    /// @param depositor Account to authorize.
    /// @param core True to mark the depositor permanent.
    function addDepositor(address depositor, bool core) external;

    /// @notice Revokes a non core depositor.
    /// @dev Owner only. Reverts `CoreDepositor` for a core depositor and `NotDepositor`
    ///      when `depositor` is not authorized.
    /// @param depositor Account to revoke.
    function removeDepositor(address depositor) external;

    /// @notice Sends funds held above `totalOwed[token]` to `to`.
    /// @dev Owner only. Reverts `ZeroAddress` when `to` is zero, `RescueExceedsExcess` when
    ///      `amount` exceeds `balance - totalOwed[token]`, and `NativeTransferFailed`.
    /// @param token Token to send, `address(0)` for eth.
    /// @param to Receiver.
    /// @param amount Amount in base units.
    function rescue(address token, address to, uint256 amount) external;

    /// @notice Stack version tag (Constants.STACK_VERSION).
    function STACK_VERSION() external view returns (uint16);
}
