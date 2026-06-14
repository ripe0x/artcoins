// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IBurnRouter
/// @notice Minimal interface used by `ProtocolFeeController` to validate that
///         a candidate burn router reports a sane `layerToken`. Kept tiny on
///         purpose — this is the only method the controller relies on for
///         router-replacement integrity.
interface IBurnRouter {
    /// @notice The LAYER token address bound at initialization.
    function layerToken() external view returns (address);
}
