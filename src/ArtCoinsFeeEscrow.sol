// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFeeEscrow} from "./interfaces/IArtCoinsFeeEscrow.sol";
import {IArtCoinsFeeLocker} from "./interfaces/IArtCoinsFeeLocker.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  ArtCoinsFeeEscrow
/// @notice Escrow for fees keyed by (feeOwner, token). Currency-agnostic:
///         supports both ERC20 fees (via `storeFees` / `claim`) and native ETH
///         (via `storeFeesNative` / `claim` with `token = address(0)`).
/// @dev    Fee owners pull their balances via `claim(feeOwner, token)`; pass
///         `token = address(0)` to claim native ETH from the same address-
///         keyed storage slot.
contract ArtCoinsFeeEscrow is IArtCoinsFeeEscrow, ReentrancyGuard, Ownable {
    /// @notice Balance of claimable fees for each (feeOwner, token) pair.
    ///         `token == address(0)` is the native-ETH slot (V4 sentinel).
    mapping(address feeOwner => mapping(address token => uint256 balance)) public feesToClaim;
    /// @notice Allowlist of addresses that may call `storeFees` / `storeFeesNative`.
    mapping(address depositor => bool isAllowed) public allowedDepositors;

    /// @param owner_ Initial owner.
    constructor(address owner_) Ownable(owner_) {}

    /// @notice Adds an allowlisted depositor.
    function addDepositor(address depositor) external onlyOwner {
        allowedDepositors[depositor] = true;
        emit AddDepositor(depositor);
    }

    /// @notice Pulls `amount` of `token` from `msg.sender` and credits it to `feeOwner`.
    /// @dev Allowlist-gated. Uses balance deltas so fee-on-transfer tokens
    ///      credit the actual received amount. For native ETH, use
    ///      `storeFeesNative` instead — this function rejects `token == address(0)`
    ///      implicitly via the ERC20 transferFrom on the zero address.
    /// @param feeOwner Account credited.
    /// @param token ERC20 token deposited.
    /// @param amount Amount to transferFrom `msg.sender`.
    function storeFees(address feeOwner, address token, uint256 amount) external nonReentrant {
        if (!allowedDepositors[msg.sender]) revert Unauthorized();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        uint256 receivedAmount = balanceAfter - balanceBefore;

        feesToClaim[feeOwner][token] += receivedAmount;
        emit StoreTokens(msg.sender, feeOwner, token, feesToClaim[feeOwner][token], amount);
    }

    /// @inheritdoc IArtCoinsFeeEscrow
    function storeFeesNative(address feeOwner) external payable nonReentrant {
        if (!allowedDepositors[msg.sender]) revert Unauthorized();
        if (msg.value == 0) revert ZeroNativeDeposit();

        // Native-ETH slot lives under `address(0)` in the same map. No balance-
        // delta accounting needed — `msg.value` is authoritative and ETH has
        // no fee-on-transfer.
        feesToClaim[feeOwner][address(0)] += msg.value;
        emit StoreNative(msg.sender, feeOwner, feesToClaim[feeOwner][address(0)], msg.value);
    }

    /// @notice Returns claimable balance of `token` for `feeOwner`. Pass
    ///         `token = address(0)` for native ETH.
    function availableFees(address feeOwner, address token) external view returns (uint256) {
        return feesToClaim[feeOwner][token];
    }

    /// @notice Transfers the entire escrowed `token` balance to `feeOwner`.
    ///         If `token == address(0)`, sends native ETH; otherwise sends the
    ///         ERC20 via SafeERC20. Permissionless.
    /// @dev Reverts with `NoFeesToClaim` if balance is zero, or
    ///      `NativeTransferFailed` if the native-ETH send fails (e.g. the
    ///      feeOwner is a contract that rejects ETH). If the feeOwner cannot
    ///      receive the asset, the feeOwner itself can call `claimTo` to
    ///      redirect their balance to a usable recipient.
    /// @param feeOwner Account to receive the balance.
    /// @param token Token claimed (`address(0)` = native ETH).
    function claim(address feeOwner, address token) external nonReentrant {
        uint256 balance = feesToClaim[feeOwner][token];
        if (balance == 0) revert NoFeesToClaim();

        feesToClaim[feeOwner][token] = 0;

        if (token == address(0)) {
            (bool ok,) = payable(feeOwner).call{value: balance}("");
            if (!ok) revert NativeTransferFailed();
            emit ClaimNative(feeOwner, balance);
        } else {
            SafeERC20.safeTransfer(IERC20(token), feeOwner, balance);
            emit ClaimTokens(feeOwner, token, balance);
        }
    }

    /// @inheritdoc IArtCoinsFeeEscrow
    function claimTo(address feeOwner, address token, address payable recipient)
        external
        nonReentrant
    {
        // Only the credited owner may redirect their balance. Prevents griefing
        // (a third party can't force a feeOwner's balance to a chosen recipient)
        // while still solving the "feeOwner can't receive" problem.
        if (msg.sender != feeOwner) revert Unauthorized();
        if (recipient == address(0)) revert ZeroRecipient();

        uint256 balance = feesToClaim[feeOwner][token];
        if (balance == 0) revert NoFeesToClaim();

        feesToClaim[feeOwner][token] = 0;

        if (token == address(0)) {
            (bool ok,) = recipient.call{value: balance}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            SafeERC20.safeTransfer(IERC20(token), recipient, balance);
        }

        emit ClaimedTo(feeOwner, recipient, token, balance);
    }

    /// @notice ERC-165 introspection.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsFeeLocker).interfaceId
            || interfaceId == type(IArtCoinsFeeEscrow).interfaceId;
    }
}
