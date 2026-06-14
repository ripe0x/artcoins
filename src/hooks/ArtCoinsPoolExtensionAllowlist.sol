// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsPoolExtensionAllowlist} from "./interfaces/IArtCoinsPoolExtensionAllowlist.sol";

import {OwnerAdmins} from "../utils/OwnerAdmins.sol";

/// @title ArtCoinsPoolExtensionAllowlist
/// @notice Allowlist of pool extension contracts that ArtCoinsHook will accept on initialization.
contract ArtCoinsPoolExtensionAllowlist is IArtCoinsPoolExtensionAllowlist, OwnerAdmins {
    /// @notice Whether an extension address is currently allowed.
    mapping(address extension => bool enabled) public enabledExtensions;

    /// @param owner_ Initial owner.
    constructor(address owner_) OwnerAdmins(owner_) {}

    /// @notice Enables or disables a pool extension. Owner or admin only.
    /// @param extension The pool extension contract.
    /// @param enabled True to allow, false to disallow.
    function setPoolExtension(address extension, bool enabled) external onlyOwnerOrAdmin {
        enabledExtensions[extension] = enabled;
        emit SetPoolExtension(extension, enabled);
    }
}
