// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IReferralPayoutForHook
/// @notice Receives the referral leg from the hook. Called with a capped gas
///         stipend; on failure the hook credits `referrer` in the fee escrow.
interface IReferralPayoutForHook {
    /// @notice Pays `msg.value` to `referrer`.
    function notify(address referrer) external payable;
}
