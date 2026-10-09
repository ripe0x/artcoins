// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsExtensionV2} from "../../interfaces/IArtCoinsExtensionV2.sol";

/// @title  IArtCoinsVaultV2
/// @notice Cliff plus linear vesting vault launch extension. The beneficiary,
///         the cliff and the vesting period are fixed in the launch tx. There
///         is no admin, no beneficiary change and no early unlock.
/// @dev    Allocations are keyed by `(token, extensionIndex)`.
interface IArtCoinsVaultV2 is IArtCoinsExtensionV2 {
    /// @notice `extensionData` layout: `abi.encode(beneficiary, lockupDuration, vestingDuration)`.
    /// @param beneficiary Receives every claim. Nonzero.
    /// @param lockupDuration Cliff in seconds, nothing is claimable before it ends. >= MIN_LOCKUP_DURATION.
    /// @param vestingDuration Seconds of linear release after the cliff. >= MIN_VESTING_DURATION.
    struct VaultDataV2 {
        address beneficiary;
        uint256 lockupDuration;
        uint256 vestingDuration;
    }

    /// @notice Frozen allocation record. `amountTotal == 0` means it does not exist.
    /// @param beneficiary Receives every claim.
    /// @param amountTotal Coin amount received at launch, in coin base units.
    /// @param amountClaimed Cumulative amount claimed, in coin base units.
    /// @param lockupEndTime Timestamp in seconds when the cliff ends.
    /// @param vestingEndTime Timestamp in seconds when the allocation is fully vested.
    struct Allocation {
        address beneficiary;
        uint256 amountTotal;
        uint256 amountClaimed;
        uint256 lockupEndTime;
        uint256 vestingEndTime;
    }

    /// @notice `extensionData` is not exactly 96 bytes.
    error InvalidExtensionData();
    /// @notice The extension entry has `extensionBps == 0`.
    error InvalidVaultBps();
    /// @notice The launcher passed a zero supply share to the extension.
    error ZeroExtensionSupply();
    /// @notice `beneficiary` is zero, the coin or the vault contract.
    error InvalidBeneficiary();
    /// @notice `lockupDuration` is below `MIN_LOCKUP_DURATION`.
    error VaultLockupDurationTooShort();
    /// @notice `vestingDuration` is below `MIN_VESTING_DURATION`.
    error VaultVestingDurationTooShort();
    /// @notice `lockupDuration` or `vestingDuration` exceeds `MAX_DURATION`.
    error DurationTooLong();
    /// @notice The config entry at `extensionIndex` is not this contract.
    error WrongExtensionEntry();
    /// @notice An allocation already exists for `(token, index)`.
    error AllocationAlreadyExists();
    /// @notice The call precedes `lockupEndTime`.
    error AllocationNotUnlocked();
    /// @notice The allocation does not exist or has nothing vested and unclaimed.
    error NoBalanceToClaim();
    /// @notice The caller of `receiveTokens` is not the factory.
    error Unauthorized();
    /// @notice The constructor factory argument is zero.
    error ZeroAddress();

    /// @notice An allocation was created at launch.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    /// @param beneficiary Receives every claim.
    /// @param supply Allocation amount in coin base units.
    /// @param lockupEndTime Timestamp in seconds when the cliff ends.
    /// @param vestingEndTime Timestamp in seconds when the allocation is fully vested.
    event AllocationCreated(
        address indexed token,
        uint256 indexed index,
        address indexed beneficiary,
        uint256 supply,
        uint256 lockupEndTime,
        uint256 vestingEndTime
    );
    /// @notice Vested coin was sent to the beneficiary.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    /// @param beneficiary Receiver.
    /// @param amount Coin amount paid by this claim, in coin base units.
    /// @param remainingAmount `amountTotal - amountClaimed` after the claim, in coin base units.
    event AllocationClaimed(
        address indexed token,
        uint256 indexed index,
        address indexed beneficiary,
        uint256 amount,
        uint256 remainingAmount
    );

    /// @notice Sends the vested and unclaimed amount to the beneficiary. Callable by anyone.
    /// @dev    Reverts `AllocationNotUnlocked` before `lockupEndTime` and `NoBalanceToClaim`
    ///         when nothing is claimable.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    function claim(address token, uint256 index) external;

    /// @notice Vested and unclaimed amount. Returns 0 before `lockupEndTime` and for a missing allocation.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    /// @return Claimable amount in coin base units.
    function amountAvailableToClaim(address token, uint256 index) external view returns (uint256);

    /// @notice Stored allocation record. All fields are zero when no allocation exists.
    /// @param token Launched coin.
    /// @param index Extension index in the launch config.
    /// @return The allocation.
    function allocation(address token, uint256 index) external view returns (Allocation memory);
}
