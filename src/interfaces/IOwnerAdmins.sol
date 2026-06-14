// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IOwnerAdmins
/// @notice Interface for contracts that combine owner-based access control with a separate admin set.
interface IOwnerAdmins {
    /// @notice Reverts when the caller is not authorized (neither owner nor admin).
    error Unauthorized();

    /// @notice Emitted when an admin's access state is changed.
    /// @param admin The address whose admin flag was updated.
    /// @param enabled The new admin state.
    event SetAdmin(address indexed admin, bool enabled);

    /// @notice Grants or revokes admin access for an address.
    /// @param admin The address to update.
    /// @param isAdmin True to grant, false to revoke.
    function setAdmin(address admin, bool isAdmin) external;
}
