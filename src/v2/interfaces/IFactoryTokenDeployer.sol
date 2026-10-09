// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IFactoryTokenDeployer
/// @notice The factory read the hook and locker use to resolve the CREATE2
///         token deployer for their recipient reject sets.
interface IFactoryTokenDeployer {
    /// @notice The factory's current token deployer.
    function tokenDeployer() external view returns (address);
}
