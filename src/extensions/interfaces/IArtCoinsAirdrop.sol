// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsExtension} from "../../interfaces/IArtCoinsExtension.sol";

/// @title IArtCoinsAirdrop
/// @notice Interface for the airdrop extension.
interface IArtCoinsAirdrop is IArtCoinsExtension {
    /// @notice Init data for an airdrop allocation.
    /// @param admin Admin authorized to manage and sweep the airdrop.
    /// @param merkleRoot Merkle root of allowlisted recipients/amounts.
    /// @param lockupDuration Seconds before claims open.
    /// @param vestingDuration Seconds over which the allocation linearly vests.
    struct AirdropV2ExtensionData {
        address admin;
        bytes32 merkleRoot;
        uint256 lockupDuration;
        uint256 vestingDuration;
    }

    /// @notice Persistent airdrop state.
    /// @param admin Admin of the airdrop.
    /// @param merkleRoot Active merkle root.
    /// @param totalSupply Total tokens escrowed.
    /// @param totalClaimed Total tokens claimed so far.
    /// @param lockupEndTime Timestamp when claims open.
    /// @param vestingEndTime Timestamp when vesting completes.
    /// @param adminClaimTime Timestamp after which the admin may sweep remaining.
    /// @param adminClaimed Whether the admin has already swept.
    /// @param amountClaimed Per-recipient amount claimed so far.
    struct AirdropV2 {
        address admin;
        bytes32 merkleRoot;
        uint256 totalSupply;
        uint256 totalClaimed;
        uint256 lockupEndTime;
        uint256 vestingEndTime;
        uint256 adminClaimTime;
        bool adminClaimed;
        mapping(address => uint256) amountClaimed;
    }

    /// @notice Reverts when the airdrop's bps allocation is zero.
    error InvalidAirdropPercentage();
    /// @notice Reverts when the caller is not authorized.
    error Unauthorized();
    /// @notice Reverts when the supplied merkle proof is invalid.
    error InvalidProof();
    /// @notice Reverts when the airdrop's total supply has been fully claimed.
    error TotalMaxClaimed();
    /// @notice Reverts when the recipient has already claimed their full allocation.
    error UserMaxClaimed();
    /// @notice Reverts when called with a zero `allocatedAmount`.
    error ZeroClaim();
    /// @notice Reverts when there is currently nothing claimable for the recipient.
    error ZeroToClaim();
    /// @notice Reverts when claims are still in lockup.
    error AirdropNotUnlocked();
    /// @notice Reverts when an airdrop already exists for the token.
    error AirdropAlreadyExists();
    /// @notice Reverts when the configured lockup is below `MIN_LOCKUP_DURATION`.
    error AirdropLockupDurationTooShort();
    /// @notice Reverts when no airdrop exists for the token.
    error AirdropNotCreated();
    /// @notice Reverts when updating the merkle root after at least one claim.
    error AirdropClaimsOccurred();
    /// @notice Reverts when updating the merkle root is not currently permitted.
    error UpdateMerkleRootNotAllowed();
    /// @notice Reverts when an action is blocked because the admin has already swept.
    error AdminClaimed();
    /// @notice Reverts when the admin tries to sweep before the claim expiration interval.
    error ClaimNotEnded();

    /// @notice Emitted when an airdrop's merkle root is replaced.
    /// @param token Airdropped token.
    /// @param oldMerkleRoot Previous root.
    /// @param newMerkleRoot New root.
    event AirdropMerkleRootUpdated(
        address indexed token, bytes32 oldMerkleRoot, bytes32 newMerkleRoot
    );

    /// @notice Emitted when an airdrop is escrowed.
    /// @param token Airdropped token.
    /// @param admin Airdrop admin.
    /// @param merkleRoot Initial merkle root.
    /// @param supply Total supply escrowed.
    /// @param lockupDuration Seconds before claims open.
    /// @param vestingDuration Seconds over which the allocation linearly vests.
    event AirdropCreated(
        address indexed token,
        address indexed admin,
        bytes32 merkleRoot,
        uint256 supply,
        uint256 lockupDuration,
        uint256 vestingDuration
    );
    /// @notice Emitted when a recipient claims tokens from an airdrop.
    /// @param token Airdropped token.
    /// @param user Recipient.
    /// @param totalUserAmountClaimed New cumulative amount claimed by the recipient.
    /// @param userAmountStillLocked Remaining locked allocation for the recipient.
    event AirdropClaimed(
        address indexed token,
        address indexed user,
        uint256 totalUserAmountClaimed,
        uint256 userAmountStillLocked
    );
    /// @notice Emitted when the airdrop admin is updated.
    /// @param token Airdropped token.
    /// @param oldAdmin Previous admin.
    /// @param newAdmin New admin.
    event AirdropAdminUpdated(
        address indexed token, address indexed oldAdmin, address indexed newAdmin
    );
    /// @notice Emitted when the admin sweeps the unclaimed remainder.
    /// @param token Airdropped token.
    /// @param amount Amount swept.
    event AirdropAdminClaimed(address indexed token, uint256 amount);

    /// @notice Claims the currently vested portion of `recipient`'s airdrop allocation.
    /// @param token Airdropped token.
    /// @param recipient Recipient.
    /// @param allocatedAmount Total allocated amount for the recipient.
    /// @param proof Merkle proof of (recipient, allocatedAmount).
    function claim(
        address token,
        address recipient,
        uint256 allocatedAmount,
        bytes32[] calldata proof
    ) external;

    /// @notice Returns the amount currently claimable for `recipient`.
    /// @param token Airdropped token.
    /// @param recipient Recipient.
    /// @param allocatedAmount Recipient's total allocated amount.
    /// @return Amount claimable now.
    function amountAvailableToClaim(address token, address recipient, uint256 allocatedAmount)
        external
        view
        returns (uint256);
}
