// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFeeLocker} from "../interfaces/IArtCoinsFeeLocker.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ArtCoinsFeeLocker
/// @notice Escrow for ERC20 fees where allowlisted depositors park balances for fee owners.
/// @dev Fee owners pull their balances via `claim`. Uses balance deltas to support
///      fee-on-transfer tokens.
contract ArtCoinsFeeLocker is IArtCoinsFeeLocker, ReentrancyGuard, Ownable {
    /// @notice Balance of claimable fees for each (feeOwner, token) pair.
    mapping(address feeOwner => mapping(address token => uint256 balance)) public feesToClaim;
    /// @notice Allowlist of addresses that may call `storeFees`.
    mapping(address depositor => bool isAllowed) public allowedDepositors;

    /// @param owner_ Initial owner.
    constructor(address owner_) Ownable(owner_) {}

    /// @notice Adds an allowlisted depositor that can call `storeFees`.
    /// @param depositor The depositor to allow.
    function addDepositor(address depositor) external onlyOwner {
        allowedDepositors[depositor] = true;
        emit AddDepositor(depositor);
    }

    /// @notice Pulls `amount` of `token` from `msg.sender` and credits it to `feeOwner`.
    /// @dev Requires `msg.sender` to be an allowlisted depositor. Uses balance deltas so
    ///      fee-on-transfer tokens credit the actual received amount.
    /// @param feeOwner The account to credit the received fees to.
    /// @param token The ERC20 token being deposited.
    /// @param amount The amount to transferFrom `msg.sender`.
    function storeFees(address feeOwner, address token, uint256 amount) external nonReentrant {
        if (!allowedDepositors[msg.sender]) revert Unauthorized();

        // use balance deltas to support fee on transfer and weird tokens
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        uint256 receivedAmount = balanceAfter - balanceBefore;

        feesToClaim[feeOwner][token] += receivedAmount;
        emit StoreTokens(msg.sender, feeOwner, token, feesToClaim[feeOwner][token], amount);
    }

    /// @notice Returns how much of `token` is claimable by `feeOwner`.
    /// @param feeOwner The fee owner.
    /// @param token The ERC20 token.
    /// @return The claimable balance.
    function availableFees(address feeOwner, address token) external view returns (uint256) {
        return feesToClaim[feeOwner][token];
    }

    /// @notice Transfers the entire escrowed `token` balance to `feeOwner`.
    /// @dev Permissionless — anyone may trigger a claim on behalf of a fee owner.
    ///      Reverts with `NoFeesToClaim` if there is nothing to claim.
    /// @param feeOwner The account to send the balance to.
    /// @param token The ERC20 token being claimed.
    function claim(address feeOwner, address token) external nonReentrant {
        uint256 balance = feesToClaim[feeOwner][token];
        if (balance == 0) revert NoFeesToClaim();

        // debit account
        feesToClaim[feeOwner][token] = 0;

        // transfer funds
        SafeERC20.safeTransfer(IERC20(token), feeOwner, balance);

        emit ClaimTokens(feeOwner, token, balance);
    }

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface identifier to query.
    /// @return True if the interface is supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsFeeLocker).interfaceId;
    }
}
