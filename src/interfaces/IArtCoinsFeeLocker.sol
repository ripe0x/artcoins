// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IArtCoinsFeeLocker
/// @notice Interface for an ERC20 fee escrow keyed by (feeOwner, token).
interface IArtCoinsFeeLocker {
    /// @notice Reverts when claiming with a zero balance.
    error NoFeesToClaim();
    /// @notice Reverts when the caller is not authorized (e.g., not an allowlisted depositor).
    error Unauthorized();

    /// @notice Emitted when fees are stored for a fee owner.
    /// @param sender The depositor that called `storeFees`.
    /// @param feeOwner The account credited.
    /// @param token The ERC20 token deposited.
    /// @param balance Updated total balance after the deposit.
    /// @param amount Amount requested to transfer in.
    event StoreTokens(
        address indexed sender,
        address indexed feeOwner,
        address indexed token,
        uint256 balance,
        uint256 amount
    );
    /// @notice Emitted when a permissioned third party claims on behalf of a fee owner.
    /// @param feeOwner Owner of the fees.
    /// @param token Token claimed.
    /// @param recipient Address funds were sent to.
    /// @param amountClaimed Amount transferred.
    event ClaimTokensPermissioned(
        address indexed feeOwner, address indexed token, address recipient, uint256 amountClaimed
    );
    /// @notice Emitted on a normal claim where funds go to the fee owner.
    /// @param feeOwner Owner of the fees.
    /// @param token Token claimed.
    /// @param amountClaimed Amount transferred.
    event ClaimTokens(address indexed feeOwner, address indexed token, uint256 amountClaimed);
    /// @notice Emitted when a depositor is added to the allowlist.
    /// @param depositor The newly allowed depositor.
    event AddDepositor(address indexed depositor);

    /// @notice Stores `amount` of `token` (pulled from `msg.sender`) against `feeOwner`'s balance.
    /// @param feeOwner The fee owner to credit.
    /// @param token The ERC20 token.
    /// @param amount Amount requested.
    function storeFees(address feeOwner, address token, uint256 amount) external;

    /// @notice Transfers all of `feeOwner`'s claimable `token` balance to them.
    /// @param feeOwner Owner of the fees.
    /// @param token The ERC20 token.
    function claim(address feeOwner, address token) external;

    /// @notice Adds an allowlisted depositor.
    /// @param depositor The depositor address.
    function addDepositor(address depositor) external;

    /// @notice Returns how much of `token` is claimable by `feeOwner`.
    /// @param feeOwner Owner of the fees.
    /// @param token The ERC20 token.
    /// @return Claimable balance.
    function availableFees(address feeOwner, address token) external view returns (uint256);

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}
