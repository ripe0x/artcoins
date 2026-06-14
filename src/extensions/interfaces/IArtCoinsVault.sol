// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsExtension} from "../../interfaces/IArtCoinsExtension.sol";

/// @title IArtCoinsVault
/// @notice Interface for the vault extension that lockups + linearly vests a token allocation
///         to a configured admin.
interface IArtCoinsVault is IArtCoinsExtension {
    /// @notice Init data for a vault allocation.
    /// @param admin Recipient/admin of the allocation.
    /// @param lockupDuration Seconds before claims can begin.
    /// @param vestingDuration Seconds over which the allocation linearly vests after lockup.
    struct VaultExtensionData {
        address admin;
        uint256 lockupDuration;
        uint256 vestingDuration;
    }

    /// @notice Persistent allocation state.
    /// @param token The locked token.
    /// @param amountTotal Total locked amount.
    /// @param amountClaimed Amount already claimed.
    /// @param lockupEndTime Timestamp lockup ends.
    /// @param vestingEndTime Timestamp vesting completes.
    /// @param admin Recipient/admin of the allocation.
    struct Allocation {
        address token;
        uint256 amountTotal;
        uint256 amountClaimed;
        uint256 lockupEndTime;
        uint256 vestingEndTime;
        address admin;
    }

    /// @notice Reverts when the caller is not the allocation admin.
    error Unauthorized();
    /// @notice Reverts when there is nothing claimable.
    error NoBalanceToClaim();
    /// @notice Reverts when claims are still in lockup.
    error AllocationNotUnlocked();
    /// @notice Reverts when the configured vault bps is zero.
    error InvalidVaultBps();
    /// @notice Reverts when the configured vault admin is zero.
    error InvalidVaultAdmin();
    /// @notice Reverts when an allocation already exists for the token.
    error AllocationAlreadyExists();
    /// @notice Reverts when the underlying ERC20 transfer fails.
    error TransferFailed();
    /// @notice Reverts when the configured lockup is shorter than `MIN_LOCKUP_DURATION`.
    error VaultLockupDurationTooShort();
    /// @notice Reverts when the configured vesting is shorter than `MIN_VESTING_DURATION`.
    error VaultVestingDurationTooShort();

    /// @notice Emitted when a vault allocation is created.
    /// @param token Locked token.
    /// @param admin Allocation admin.
    /// @param supply Locked supply.
    /// @param lockupDuration Configured lockup duration.
    /// @param vestingDuration Configured vesting duration.
    event AllocationCreated(
        address indexed token,
        address indexed admin,
        uint256 supply,
        uint256 lockupDuration,
        uint256 vestingDuration
    );

    /// @notice Emitted when the admin/recipient is changed.
    /// @param token Locked token.
    /// @param oldAdmin Previous admin.
    /// @param newAdmin New admin.
    event AllocationAdminUpdated(
        address indexed token, address indexed oldAdmin, address indexed newAdmin
    );

    /// @notice Emitted on claim.
    /// @param token Locked token.
    /// @param amount Amount claimed.
    /// @param remainingAmount Remaining locked.
    event AllocationClaimed(address indexed token, uint256 amount, uint256 remainingAmount);

    /// @notice Returns the stored allocation fields for a token.
    /// @param token The token.
    /// @return tokenAddress The locked token.
    /// @return amountTotal Total locked amount.
    /// @return amountClaimed Amount claimed so far.
    /// @return lockupEndTime Timestamp lockup ends.
    /// @return vestingEndTime Timestamp vesting completes.
    /// @return admin Allocation admin.
    function allocation(address token)
        external
        view
        returns (
            address tokenAddress,
            uint256 amountTotal,
            uint256 amountClaimed,
            uint256 lockupEndTime,
            uint256 vestingEndTime,
            address admin
        );

    /// @notice Transfers admin/recipient rights for an allocation.
    /// @param token The token.
    /// @param newAdmin New admin.
    function editAllocationAdmin(address token, address newAdmin) external;
    /// @notice Returns the amount currently claimable.
    /// @param token The token.
    /// @return Currently claimable amount.
    function amountAvailableToClaim(address token) external view returns (uint256);
    /// @notice Claims the currently vested portion to the admin.
    /// @param token The token.
    function claim(address token) external;
}
