// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IConstantsBound
/// @notice Implemented by every v2 contract that is wired to another. A setter or check that
///         links a contract to another reverts `ConstantsMismatch` unless the target returns
///         this build's `Constants.hash()`.
interface IConstantsBound {
    /// @notice A wired contract was built against a different `Constants` set.
    error ConstantsMismatch(address module);

    /// @notice `Constants.hash()` of the build this contract was compiled with.
    function constantsHash() external pure returns (bytes32);
}
