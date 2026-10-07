// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IConstantsBound} from "./IConstantsBound.sol";

/// @title  IArtCoinsFeeEscrowV2
/// @notice Fallback store for fees whose push failed. Balances are owed and
///         untouchable by the owner. Claims are permissionless unless the fee
///         owner opts into `selfClaimOnly`. `token == address(0)` is native eth.
interface IArtCoinsFeeEscrowV2 is IConstantsBound {
    // ── events ────────────────────────────────────────────────────────────

    event FeesStored(
        address indexed depositor,
        address indexed feeOwner,
        address indexed token,
        uint256 amount,
        uint256 balance
    );
    event FeesClaimed(
        address indexed feeOwner, address indexed token, address indexed recipient, uint256 amount
    );
    event SelfClaimOnlySet(address indexed feeOwner, bool on);
    event DepositorAdded(address indexed depositor, bool core);
    event DepositorRemoved(address indexed depositor);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ── errors ────────────────────────────────────────────────────────────

    error Unauthorized();
    error NotDepositor();
    error ZeroAddress();
    error ZeroRecipient();
    error ZeroNativeDeposit();
    error NoFeesToClaim();
    error NativeTransferFailed();
    error CoreDepositor(address depositor);
    error RescueExceedsExcess(uint256 requested, uint256 excess);

    // ── depositors ────────────────────────────────────────────────────────

    /// @notice Pulls `amount` of `token` from the depositor and credits `feeOwner`.
    function storeFees(address feeOwner, address token, uint256 amount) external;
    /// @notice Credits `msg.value` native eth to `feeOwner`.
    function storeFeesNative(address feeOwner) external payable;

    // ── claims ────────────────────────────────────────────────────────────

    /// @notice Sends `feeOwner`'s whole `token` balance to `feeOwner`.
    ///         Reverts `Unauthorized` when `selfClaimOnly[feeOwner]` and caller is not `feeOwner`.
    function claim(address feeOwner, address token) external;
    /// @notice Fee owner only. Sends the whole balance to `recipient`.
    function claimTo(address feeOwner, address token, address payable recipient) external;
    /// @notice Caller sets its own self claim flag.
    function setSelfClaimOnly(bool on) external;

    // ── reads ─────────────────────────────────────────────────────────────

    function balances(address feeOwner, address token) external view returns (uint256);
    function totalOwed(address token) external view returns (uint256);
    function selfClaimOnly(address feeOwner) external view returns (bool);
    function isDepositor(address depositor) external view returns (bool);
    function isCoreDepositor(address depositor) external view returns (bool);

    // ── owner ─────────────────────────────────────────────────────────────

    /// @notice `core` depositors (hook, locker) can never be removed.
    function addDepositor(address depositor, bool core) external;
    /// @notice Removes a non core depositor.
    function removeDepositor(address depositor) external;
    /// @notice Sends at most `balance - totalOwed[token]` (stray funds only).
    function rescue(address token, address to, uint256 amount) external;
}
