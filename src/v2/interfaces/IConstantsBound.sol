// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IConstantsBound
/// @notice Implemented by every v2 contract that is wired to another. Wiring
///         reverts `ConstantsMismatch` unless both sides return the same hash.
interface IConstantsBound {
    /// @notice A wired contract was built against a different `Constants` set.
    error ConstantsMismatch(address module);

    /// @notice `Constants.hash()` of the build this contract was compiled with.
    function constantsHash() external pure returns (bytes32);
}
