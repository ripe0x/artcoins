// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOwnerAdmins} from "../../interfaces/IOwnerAdmins.sol";

/// @title IArtCoinsPoolExtensionAllowlist
/// @notice Interface for the contract that gates which pool extensions a hook will accept.
interface IArtCoinsPoolExtensionAllowlist is IOwnerAdmins {
    /// @notice Emitted when an extension's allowlist state changes.
    /// @param extension The extension contract address.
    /// @param allowed The new state.
    event SetPoolExtension(address extension, bool allowed);

    /// @notice Sets a pool extension's allowlist state.
    /// @param extension The extension contract address.
    /// @param allowed True to allow, false to disallow.
    function setPoolExtension(address extension, bool allowed) external;

    /// @notice Returns whether an extension is currently on the allowlist.
    /// @param extension The extension contract address.
    /// @return enabled True if allowlisted.
    function enabledExtensions(address extension) external view returns (bool enabled);
}
