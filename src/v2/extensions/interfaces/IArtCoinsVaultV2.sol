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
    struct Allocation {
        address beneficiary;
        uint256 amountTotal;
        uint256 amountClaimed;
        uint256 lockupEndTime;
        uint256 vestingEndTime;
    }

    error InvalidExtensionData();
    error InvalidVaultBps();
    /// @notice The launcher passed a zero supply share to the extension.
    error ZeroExtensionSupply();
    error InvalidBeneficiary();
    error VaultLockupDurationTooShort();
    error VaultVestingDurationTooShort();
    error DurationTooLong();
    error WrongExtensionEntry();
    error AllocationAlreadyExists();
    error AllocationNotUnlocked();
    error NoBalanceToClaim();
    error Unauthorized();
    error ZeroAddress();

    event AllocationCreated(
        address indexed token,
        uint256 indexed index,
        address indexed beneficiary,
        uint256 supply,
        uint256 lockupEndTime,
        uint256 vestingEndTime
    );
    event AllocationClaimed(
        address indexed token,
        uint256 indexed index,
        address indexed beneficiary,
        uint256 amount,
        uint256 remainingAmount
    );

    /// @notice Sends the vested and unclaimed amount to the beneficiary. Callable by anyone.
    function claim(address token, uint256 index) external;

    function amountAvailableToClaim(address token, uint256 index) external view returns (uint256);

    function allocation(address token, uint256 index) external view returns (Allocation memory);
}
