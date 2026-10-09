// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IBurnableCoin
/// @notice The burn entrypoint the protocol fee controller and burn router call
///         to destroy coin supply.
interface IBurnableCoin {
    /// @notice Burn `amount` from the caller's balance.
    function burn(uint256 amount) external;
}
