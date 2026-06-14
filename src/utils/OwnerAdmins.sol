// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOwnerAdmins} from "../interfaces/IOwnerAdmins.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title OwnerAdmins
/// @notice Access-control base combining OpenZeppelin `Ownable` with a mutable admin allowlist.
abstract contract OwnerAdmins is Ownable, IOwnerAdmins {
    /// @notice Mapping of addresses to admin status.
    mapping(address => bool) public admins;

    /// @param owner_ Initial owner.
    constructor(address owner_) Ownable(owner_) {}

    /// @notice Grants or revokes admin access. Owner only.
    /// @param admin The address to update.
    /// @param enabled True to grant, false to revoke.
    function setAdmin(address admin, bool enabled) external onlyOwner {
        admins[admin] = enabled;
        emit SetAdmin(admin, enabled);
    }

    /// @dev Reverts if `msg.sender` is neither the owner nor an admin.
    modifier onlyOwnerOrAdmin() {
        if (!admins[msg.sender] && msg.sender != owner()) revert Unauthorized();
        _;
    }
}
