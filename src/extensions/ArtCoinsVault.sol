// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsExtension} from "../interfaces/IArtCoinsExtension.sol";
import {IArtCoinsFactory} from "../interfaces/IArtCoinsFactory.sol";
import {IArtCoinsVault} from "./interfaces/IArtCoinsVault.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ArtCoinsVault
/// @notice Extension that locks an allocation of newly deployed tokens for a configured admin
///         and releases them linearly after a lockup period.
contract ArtCoinsVault is ReentrancyGuard, IArtCoinsVault {
    /// @notice The factory authorized to call `receiveTokens`.
    address public immutable factory;

    /// @notice Per-token vault allocation.
    mapping(address => Allocation) public allocation;

    /// @notice Minimum lockup duration (7 days).
    uint256 public constant MIN_LOCKUP_DURATION = 7 days;

    /// @notice Minimum vesting duration (90 days). Anti-rug guarantee for
    ///         buyers: even after lockup, the dev allocation releases linearly
    ///         over at least this period — preventing instant dump.
    uint256 public constant MIN_VESTING_DURATION = 90 days;

    /// @dev Restricts a function to the factory.
    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }

    /// @param factory_ The factory that will call `receiveTokens`.
    constructor(address factory_) {
        factory = factory_;
    }

    /// @notice Called by the factory during deployment to lock the vault allocation.
    /// @param deploymentConfig Full deployment config.
    /// @param token The newly deployed token.
    /// @param extensionSupply Token amount allocated to the vault.
    /// @param extensionIndex Index of this extension in the deployment config.
    function receiveTokens(
        IArtCoinsFactory.DeploymentConfig calldata deploymentConfig,
        PoolKey memory,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable nonReentrant onlyFactory {
        VaultExtensionData memory vaultData = abi.decode(
            deploymentConfig.extensionConfigs[extensionIndex].extensionData, (VaultExtensionData)
        );

        // ensure that the msgValue is zero
        if (deploymentConfig.extensionConfigs[extensionIndex].msgValue != 0 || msg.value != 0) {
            revert IArtCoinsExtension.InvalidMsgValue();
        }

        uint256 lockupEndTime = block.timestamp + vaultData.lockupDuration;

        // check the vault percentage is not zero
        if (deploymentConfig.extensionConfigs[extensionIndex].extensionBps == 0) {
            revert InvalidVaultBps();
        }

        // check that minimum lockup duration is met
        if (vaultData.lockupDuration < MIN_LOCKUP_DURATION) {
            revert VaultLockupDurationTooShort();
        }

        // check that minimum vesting duration is met (anti-rug)
        if (vaultData.vestingDuration < MIN_VESTING_DURATION) {
            revert VaultVestingDurationTooShort();
        }

        // check the admin is set
        if (vaultData.admin == address(0)) {
            revert InvalidVaultAdmin();
        }

        // only one allocation per token
        if (allocation[token].lockupEndTime != 0) revert AllocationAlreadyExists();

        allocation[token] = Allocation({
            token: token,
            amountTotal: extensionSupply,
            amountClaimed: 0,
            lockupEndTime: lockupEndTime,
            vestingEndTime: lockupEndTime + vaultData.vestingDuration,
            admin: vaultData.admin
        });

        // pull in token
        if (!IERC20(token).transferFrom(msg.sender, address(this), extensionSupply)) {
            revert TransferFailed();
        }

        emit AllocationCreated({
            token: token,
            admin: vaultData.admin,
            supply: extensionSupply,
            lockupDuration: vaultData.lockupDuration,
            vestingDuration: vaultData.vestingDuration
        });
    }

    /// @notice Transfers admin/recipient rights for an allocation. Current admin only.
    /// @param token The token whose allocation to update.
    /// @param newAdmin The new admin/recipient.
    function editAllocationAdmin(address token, address newAdmin) external {
        if (msg.sender != allocation[token].admin) revert Unauthorized();
        allocation[token].admin = newAdmin;

        emit AllocationAdminUpdated(token, msg.sender, newAdmin);
    }

    /// @notice Returns the currently claimable amount for a token's allocation.
    /// @param token The token address.
    /// @return Amount claimable now.
    function amountAvailableToClaim(address token) external view returns (uint256) {
        return _getAmountToClaim(token);
    }

    /// @notice Claims the currently vested-and-unclaimed amount to the allocation admin.
    /// @param token The token whose allocation to claim.
    function claim(address token) external nonReentrant {
        // ensure lockup period has passed
        if (block.timestamp < allocation[token].lockupEndTime) {
            revert AllocationNotUnlocked();
        }

        uint256 amountToClaim;

        // check amount to claim
        amountToClaim = _getAmountToClaim(token);
        if (amountToClaim == 0) revert NoBalanceToClaim();

        // update the amount claimed
        allocation[token].amountClaimed += amountToClaim;

        if (!IERC20(token).transfer(allocation[token].admin, amountToClaim)) {
            revert TransferFailed();
        }

        emit AllocationClaimed(token, amountToClaim, allocation[token].amountTotal - amountToClaim);
    }

    function _getAmountToClaim(address token) internal view returns (uint256) {
        if (block.timestamp < allocation[token].lockupEndTime) {
            // still in lockup period
            return 0;
        } else if (block.timestamp >= allocation[token].vestingEndTime) {
            // if the vesting period has passed, claim the remaining balance
            return allocation[token].amountTotal - allocation[token].amountClaimed;
        } else {
            // if the vesting period has not passed, calculate the amount to claim based on the
            // vesting period and how much has already been claimed
            uint256 totalAmountAvailable = allocation[token].amountTotal
                * (block.timestamp - allocation[token].lockupEndTime)
                / (allocation[token].vestingEndTime - allocation[token].lockupEndTime);

            return totalAmountAvailable - allocation[token].amountClaimed;
        }
    }

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsExtension).interfaceId;
    }
}
