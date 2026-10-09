// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IBurnableCoin
/// @notice Burn entrypoint that the protocol fee controller and burn router call
///         to destroy coin supply.
interface IBurnableCoin {
    /// @notice Burns `amount` from the caller's balance.
    /// @dev Reverts when the caller's balance is below `amount`.
    /// @param amount Coin to burn, in coin base units.
    function burn(uint256 amount) external;
}
