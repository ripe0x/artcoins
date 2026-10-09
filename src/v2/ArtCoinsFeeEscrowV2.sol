// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../Constants.sol";
import {IArtCoinsFeeEscrowV2} from "./interfaces/IArtCoinsFeeEscrowV2.sol";
import {IConstantsBound} from "./interfaces/IConstantsBound.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title  ArtCoinsFeeEscrowV2
/// @notice Fallback store for fees whose push failed. Balances are keyed by
///         (feeOwner, token), `token == address(0)` is native eth. Credited
///         balances are owed: the owner can rescue at most `balance - totalOwed`.
/// @dev    `claim` pays the fee owner and is callable by anyone unless the fee
///         owner set `selfClaimOnly` (`FeeAutoSwapperV2` sets it).
///         `claimTo` is callable by the fee owner only.
///         Core depositors (hook, locker) are permanent, so the push fallback
///         of those contracts stays available.
contract ArtCoinsFeeEscrowV2 is IArtCoinsFeeEscrowV2, Ownable2Step, ReentrancyGuardTransient {
    /// @inheritdoc IArtCoinsFeeEscrowV2
    mapping(address feeOwner => mapping(address token => uint256)) public balances;
    /// @inheritdoc IArtCoinsFeeEscrowV2
    mapping(address token => uint256) public totalOwed;
    /// @inheritdoc IArtCoinsFeeEscrowV2
    mapping(address feeOwner => bool) public selfClaimOnly;
    /// @inheritdoc IArtCoinsFeeEscrowV2
    mapping(address depositor => bool) public isDepositor;
    /// @inheritdoc IArtCoinsFeeEscrowV2
    mapping(address depositor => bool) public isCoreDepositor;

    constructor(address owner_) Ownable(owner_) {}

    modifier onlyDepositor() {
        if (!isDepositor[msg.sender]) revert NotDepositor();
        _;
    }

    /// @inheritdoc IArtCoinsFeeEscrowV2
    uint16 public constant STACK_VERSION = Constants.STACK_VERSION;

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    // ── depositors ────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsFeeEscrowV2
    /// @dev Credits the amount actually received (balance delta). A zero
    ///      amount returns without effect.
    function storeFees(address feeOwner, address token, uint256 amount)
        external
        onlyDepositor
        nonReentrant
    {
        if (feeOwner == address(0)) revert ZeroRecipient();
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) return;

        uint256 before = SafeTransferLib.balanceOf(token, address(this));
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 received = SafeTransferLib.balanceOf(token, address(this)) - before;

        _credit(feeOwner, token, received);
    }

    /// @inheritdoc IArtCoinsFeeEscrowV2
    /// @dev Makes no external call. A reentrancy lock would revert a core
    ///      depositor's fallback that runs inside a claim callback.
    function storeFeesNative(address feeOwner) external payable onlyDepositor {
        if (feeOwner == address(0)) revert ZeroRecipient();
        if (msg.value == 0) revert ZeroNativeDeposit();
        _credit(feeOwner, address(0), msg.value);
    }

    function _credit(address feeOwner, address token, uint256 amount) private {
        uint256 bal = balances[feeOwner][token] + amount;
        balances[feeOwner][token] = bal;
        totalOwed[token] += amount;
        emit FeesStored(msg.sender, feeOwner, token, amount, bal);
    }

    // ── claims ────────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsFeeEscrowV2
    function claim(address feeOwner, address token) external nonReentrant {
        if (selfClaimOnly[feeOwner] && msg.sender != feeOwner) revert Unauthorized();
        _payout(feeOwner, token, feeOwner);
    }

    /// @inheritdoc IArtCoinsFeeEscrowV2
    function claimTo(address feeOwner, address token, address payable recipient)
        external
        nonReentrant
    {
        if (msg.sender != feeOwner) revert Unauthorized();
        if (recipient == address(0)) revert ZeroRecipient();
        _payout(feeOwner, token, recipient);
    }

    /// @inheritdoc IArtCoinsFeeEscrowV2
    function setSelfClaimOnly(bool on) external {
        selfClaimOnly[msg.sender] = on;
        emit SelfClaimOnlySet(msg.sender, on);
    }

    /// @dev State is updated before the transfer. Native eth is sent with all
    ///      remaining gas and a failed send reverts the claim. Erc20 uses
    ///      `SafeTransferLib.safeTransfer`.
    function _payout(address feeOwner, address token, address recipient) private {
        if (feeOwner == address(0)) revert ZeroRecipient();
        uint256 amount = balances[feeOwner][token];
        if (amount == 0) revert NoFeesToClaim();

        balances[feeOwner][token] = 0;
        totalOwed[token] -= amount;

        if (token == address(0)) {
            (bool ok,) = recipient.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            SafeTransferLib.safeTransfer(token, recipient, amount);
        }
        emit FeesClaimed(feeOwner, token, recipient, amount);
    }

    // ── owner ─────────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsFeeEscrowV2
    /// @dev A core depositor keeps core status. Re adding a non core depositor
    ///      as core upgrades it.
    function addDepositor(address depositor, bool core) external onlyOwner {
        if (depositor == address(0)) revert ZeroAddress();
        if (isCoreDepositor[depositor] && !core) revert CoreDepositor(depositor);
        isDepositor[depositor] = true;
        if (core) isCoreDepositor[depositor] = true;
        emit DepositorAdded(depositor, core);
    }

    /// @inheritdoc IArtCoinsFeeEscrowV2
    function removeDepositor(address depositor) external onlyOwner {
        if (isCoreDepositor[depositor]) revert CoreDepositor(depositor);
        if (!isDepositor[depositor]) revert NotDepositor();
        isDepositor[depositor] = false;
        emit DepositorRemoved(depositor);
    }

    /// @inheritdoc IArtCoinsFeeEscrowV2
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 held = token == address(0)
            ? address(this).balance
            : SafeTransferLib.balanceOf(token, address(this));
        uint256 owed = totalOwed[token];
        uint256 excess = held > owed ? held - owed : 0;
        if (amount > excess) revert RescueExceedsExcess(amount, excess);

        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
        emit Rescued(token, to, amount);
    }
}
