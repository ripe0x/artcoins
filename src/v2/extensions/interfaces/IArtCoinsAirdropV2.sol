// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsExtensionV2} from "../../interfaces/IArtCoinsExtensionV2.sol";

/// @title  IArtCoinsAirdropV2
/// @notice Merkle airdrop launch extension. Every field of a tranche is fixed
///         in the launch tx: there is no admin, no root replacement and no
///         setter. Unclaimed tokens go to a sweep recipient fixed at launch.
/// @dev    Tranches are keyed by `(token, extensionIndex)`, so two airdrop
///         entries in one launch are independent.
interface IArtCoinsAirdropV2 is IArtCoinsExtensionV2 {
    /// @notice `extensionData` layout: `abi.encode(sweepRecipient, merkleRoot, lockupDuration, vestingDuration)`.
    /// @param sweepRecipient Receives the unclaimed remainder once the claim window closes. Nonzero.
    /// @param merkleRoot Root of an OpenZeppelin StandardMerkleTree over `["address","uint256"]`. Nonzero.
    /// @param lockupDuration Seconds before claims open.
    /// @param vestingDuration Seconds over which each allocation vests linearly after the lockup.
    struct AirdropDataV2 {
        address sweepRecipient;
        bytes32 merkleRoot;
        uint256 lockupDuration;
        uint256 vestingDuration;
    }

    /// @notice Frozen tranche record. `supply == 0` means the tranche does not exist.
    struct Tranche {
        address sweepRecipient;
        bytes32 merkleRoot;
        uint256 supply;
        uint256 totalClaimed;
        uint256 lockupEnd;
        uint256 vestingEnd;
        uint256 sweepTime;
        bool swept;
    }

    error InvalidExtensionData();
    error InvalidAirdropBps();
    error InvalidMerkleRoot();
    error ZeroSweepRecipient();
    error DurationTooLong();
    error WrongExtensionEntry();
    error AirdropAlreadyExists();
    error AirdropNotCreated();
    error AirdropNotUnlocked();
    error ClaimWindowClosed();
    error InvalidProof();
    error ZeroClaim();
    error TotalMaxClaimed();
    error UserMaxClaimed();
    error ZeroToClaim();
    error SweepNotReady();
    error AlreadySwept();
    error Unauthorized();
    error ZeroAddress();

    event AirdropCreated(
        address indexed token,
        uint256 indexed index,
        address indexed sweepRecipient,
        bytes32 merkleRoot,
        uint256 supply,
        uint256 lockupEnd,
        uint256 vestingEnd,
        uint256 sweepTime
    );
    event AirdropClaimed(
        address indexed token,
        uint256 indexed index,
        address indexed recipient,
        uint256 amount,
        uint256 leafClaimed,
        uint256 allocatedAmount
    );
    event AirdropSwept(
        address indexed token, uint256 indexed index, address indexed recipient, uint256 amount
    );

    /// @notice Claims the vested portion of the leaf `(recipient, allocatedAmount)` to `recipient`.
    ///         Callable by anyone; funds can only go to the leaf's own address.
    function claim(
        address token,
        uint256 index,
        address recipient,
        uint256 allocatedAmount,
        bytes32[] calldata proof
    ) external;

    /// @notice After the claim window, sends the unclaimed remainder to the
    ///         fixed sweep recipient. Callable by anyone, once.
    function sweep(address token, uint256 index) external;

    /// @notice Vested and unclaimed amount for a leaf (assumes the leaf is in the tree).
    function amountAvailableToClaim(
        address token,
        uint256 index,
        address recipient,
        uint256 allocatedAmount
    ) external view returns (uint256);

    /// @notice Amount already claimed against the leaf `(recipient, allocatedAmount)`.
    function leafClaimed(address token, uint256 index, address recipient, uint256 allocatedAmount)
        external
        view
        returns (uint256);

    /// @notice OpenZeppelin StandardMerkleTree leaf: `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`.
    function leafHash(address account, uint256 amount) external pure returns (bytes32);

    function tranche(address token, uint256 index) external view returns (Tranche memory);
}
