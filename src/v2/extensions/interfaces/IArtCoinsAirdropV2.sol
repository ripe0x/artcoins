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
    /// @param sweepRecipient Receives the unclaimed remainder at `sweepTime`.
    /// @param merkleRoot Root of the allocation tree.
    /// @param supply Coin amount received at launch, in coin base units.
    /// @param totalClaimed Cumulative coin amount paid out by `claim` or moved by `sweep`, in coin base units.
    /// @param lockupEnd Timestamp in seconds when claims open.
    /// @param vestingEnd Timestamp in seconds when every allocation is fully vested.
    /// @param sweepTime Timestamp in seconds when claims close and `sweep` opens.
    /// @param swept Whether `sweep` has run.
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

    /// @notice `extensionData` is not exactly 128 bytes.
    error InvalidExtensionData();
    /// @notice The extension entry has `extensionBps == 0`.
    error InvalidAirdropBps();
    /// @notice The launcher passed a zero supply share to the extension.
    error ZeroExtensionSupply();
    /// @notice `merkleRoot` is zero.
    error InvalidMerkleRoot();
    /// @notice `sweepRecipient` is zero, the coin or the airdrop contract.
    error ZeroSweepRecipient();
    /// @notice `lockupDuration` or `vestingDuration` exceeds `MAX_DURATION`.
    error DurationTooLong();
    /// @notice The config entry at `extensionIndex` is not this contract.
    error WrongExtensionEntry();
    /// @notice A tranche already exists for `(token, index)`.
    error AirdropAlreadyExists();
    /// @notice No tranche exists for `(token, index)`.
    error AirdropNotCreated();
    /// @notice The call precedes `lockupEnd`.
    error AirdropNotUnlocked();
    /// @notice The call is at or after `sweepTime`.
    error ClaimWindowClosed();
    /// @notice The merkle proof does not verify against the root.
    error InvalidProof();
    /// @notice `allocatedAmount` is zero.
    error ZeroClaim();
    /// @notice The tranche supply is fully claimed.
    error TotalMaxClaimed();
    /// @notice The leaf is fully claimed.
    error UserMaxClaimed();
    /// @notice The claimable amount is zero.
    error ZeroToClaim();
    /// @notice The call precedes `sweepTime`.
    error SweepNotReady();
    /// @notice The tranche was already swept.
    error AlreadySwept();
    /// @notice The caller of `receiveTokens` is not the factory.
    error Unauthorized();
    /// @notice The constructor factory argument is zero.
    error ZeroAddress();

    /// @notice A tranche was created at launch.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    /// @param sweepRecipient Receives the unclaimed remainder.
    /// @param merkleRoot Root of the allocation tree.
    /// @param supply Tranche supply in coin base units.
    /// @param lockupEnd Timestamp in seconds when claims open.
    /// @param vestingEnd Timestamp in seconds when allocations are fully vested.
    /// @param sweepTime Timestamp in seconds when claims close.
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
    /// @notice A leaf claimed vested coin.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    /// @param recipient Leaf address that was paid.
    /// @param amount Coin amount paid by this claim, in coin base units.
    /// @param leafClaimed Cumulative amount claimed against the leaf, in coin base units.
    /// @param allocatedAmount Leaf allocation, in coin base units.
    event AirdropClaimed(
        address indexed token,
        uint256 indexed index,
        address indexed recipient,
        uint256 amount,
        uint256 leafClaimed,
        uint256 allocatedAmount
    );
    /// @notice The unclaimed remainder was sent to the sweep recipient.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    /// @param recipient Sweep recipient.
    /// @param amount Coin amount sent, in coin base units.
    event AirdropSwept(
        address indexed token, uint256 indexed index, address indexed recipient, uint256 amount
    );

    /// @notice Claims the vested portion of the leaf `(recipient, allocatedAmount)` to `recipient`.
    ///         Callable by anyone; funds can only go to the leaf's own address.
    /// @dev    Reverts `AirdropNotCreated`, `AirdropNotUnlocked`, `ClaimWindowClosed`, `ZeroClaim`,
    ///         `TotalMaxClaimed`, `InvalidProof`, `UserMaxClaimed` or `ZeroToClaim`.
    ///         The payout is capped at the tranche supply not yet claimed.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    /// @param recipient Leaf address.
    /// @param allocatedAmount Leaf allocation in coin base units.
    /// @param proof Merkle proof for the leaf.
    function claim(
        address token,
        uint256 index,
        address recipient,
        uint256 allocatedAmount,
        bytes32[] calldata proof
    ) external;

    /// @notice After the claim window, sends the unclaimed remainder to the
    ///         fixed sweep recipient. Callable by anyone, once.
    /// @dev    Reverts `AirdropNotCreated`, `SweepNotReady` or `AlreadySwept`.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    function sweep(address token, uint256 index) external;

    /// @notice Vested and unclaimed amount for a leaf (assumes the leaf is in the tree).
    /// @dev    Returns 0 before `lockupEnd` and from `sweepTime`. Reverts `AirdropNotCreated`.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    /// @param recipient Leaf address.
    /// @param allocatedAmount Leaf allocation in coin base units.
    /// @return Claimable amount in coin base units.
    function amountAvailableToClaim(
        address token,
        uint256 index,
        address recipient,
        uint256 allocatedAmount
    ) external view returns (uint256);

    /// @notice Amount already claimed against the leaf `(recipient, allocatedAmount)`.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    /// @param recipient Leaf address.
    /// @param allocatedAmount Leaf allocation in coin base units.
    /// @return Claimed amount in coin base units.
    function leafClaimed(address token, uint256 index, address recipient, uint256 allocatedAmount)
        external
        view
        returns (uint256);

    /// @notice OpenZeppelin StandardMerkleTree leaf: `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`.
    /// @param account Leaf address.
    /// @param amount Leaf allocation in coin base units.
    /// @return The leaf hash.
    function leafHash(address account, uint256 amount) external pure returns (bytes32);

    /// @notice Stored tranche record. All fields are zero when no tranche exists.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    /// @return The tranche.
    function tranche(address token, uint256 index) external view returns (Tranche memory);
}
