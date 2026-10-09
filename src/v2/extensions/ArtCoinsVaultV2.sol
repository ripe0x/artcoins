// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsExtensionV2} from "../interfaces/IArtCoinsExtensionV2.sol";
import {IArtCoinsFactoryV2} from "../interfaces/IArtCoinsFactoryV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";
import {IArtCoinsVaultV2} from "./interfaces/IArtCoinsVaultV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  ArtCoinsVaultV2
/// @notice Locks a launch allocation behind a cliff then releases it linearly
///         to a beneficiary fixed in the launch tx.
///
///         Schedule (as v1): nothing before `lockupEnd`; from `lockupEnd`
///         the allocation vests linearly and is fully vested at
///         `vestingEnd = lockupEnd + vestingDuration`. Rounds down, monotone,
///         exactly 100% at the end.
///
///         Frozen at launch (D7): beneficiary, cliff, vesting, amount. There is
///         no owner, no admin, no `editAllocationAdmin` and no early unlock.
///         Fixes against the v1 review:
///         - V1: a zero beneficiary reverts at launch (v1 let the admin be
///           set to zero, bricking claims).
///         - V2: the `AllocationClaimed` remaining amount is
///           `amountTotal - amountClaimed` after the claim.
///         - claim is callable by anyone and always pays the beneficiary, so a
///           beneficiary that is a contract needs no key to trigger it.
///         - allocations are keyed by `(token, extensionIndex)`.
contract ArtCoinsVaultV2 is ReentrancyGuard, IArtCoinsVaultV2 {
    using SafeERC20 for IERC20;

    /// @notice The only caller of `receiveTokens`.
    address public immutable factory;

    /// @notice Minimum cliff (7 days).
    uint256 public constant MIN_LOCKUP_DURATION = 7 days;
    /// @notice Minimum linear vesting after the cliff (90 days): no instant dump.
    uint256 public constant MIN_VESTING_DURATION = 90 days;
    /// @notice Sanity bound on each configured duration.
    uint256 public constant MAX_DURATION = 3650 days;

    mapping(address token => mapping(uint256 index => Allocation)) private _allocations;

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }

    /// @param factory_ The v2 factory. Immutable.
    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /// @inheritdoc IArtCoinsExtensionV2
    function receiveTokens(
        IArtCoinsFactoryV2.DeploymentConfigV2 calldata config,
        PoolKey calldata,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable nonReentrant onlyFactory {
        IArtCoinsFactoryV2.ExtensionConfigV2 calldata e = config.extensions[extensionIndex];
        if (e.extension != address(this)) revert WrongExtensionEntry();
        if (e.msgValue != 0 || msg.value != 0) revert InvalidMsgValue();
        if (e.extensionBps == 0) revert InvalidVaultBps();
        if (extensionSupply == 0) revert ZeroExtensionSupply();
        if (e.extensionData.length != 96) revert InvalidExtensionData();

        (address beneficiary, uint256 lockup, uint256 vesting) =
            abi.decode(e.extensionData, (address, uint256, uint256));
        if (beneficiary == address(0) || beneficiary == token || beneficiary == address(this)) {
            revert InvalidBeneficiary();
        }
        if (lockup < MIN_LOCKUP_DURATION) revert VaultLockupDurationTooShort();
        if (vesting < MIN_VESTING_DURATION) revert VaultVestingDurationTooShort();
        if (lockup > MAX_DURATION || vesting > MAX_DURATION) revert DurationTooLong();

        Allocation storage a = _allocations[token][extensionIndex];
        if (a.amountTotal != 0) revert AllocationAlreadyExists();

        uint256 lockupEnd = block.timestamp + lockup;
        uint256 vestingEnd = lockupEnd + vesting;
        a.beneficiary = beneficiary;
        a.amountTotal = extensionSupply;
        a.lockupEndTime = lockupEnd;
        a.vestingEndTime = vestingEnd;

        IERC20(token).safeTransferFrom(msg.sender, address(this), extensionSupply);

        emit AllocationCreated(
            token, extensionIndex, beneficiary, extensionSupply, lockupEnd, vestingEnd
        );
    }

    /// @inheritdoc IArtCoinsVaultV2
    function claim(address token, uint256 index) external nonReentrant {
        Allocation storage a = _allocations[token][index];
        if (a.amountTotal == 0) revert NoBalanceToClaim();
        if (block.timestamp < a.lockupEndTime) revert AllocationNotUnlocked();

        uint256 amount = _claimable(a);
        if (amount == 0) revert NoBalanceToClaim();

        uint256 claimed = a.amountClaimed + amount;
        a.amountClaimed = claimed;
        address to = a.beneficiary;
        IERC20(token).safeTransfer(to, amount);

        emit AllocationClaimed(token, index, to, amount, a.amountTotal - claimed);
    }

    /// @inheritdoc IArtCoinsVaultV2
    function amountAvailableToClaim(address token, uint256 index) external view returns (uint256) {
        return _claimable(_allocations[token][index]);
    }

    /// @inheritdoc IArtCoinsVaultV2
    function allocation(address token, uint256 index) external view returns (Allocation memory) {
        return _allocations[token][index];
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsExtensionV2).interfaceId
            || interfaceId == type(IArtCoinsVaultV2).interfaceId
            || interfaceId == type(IConstantsBound).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function _claimable(Allocation storage a) private view returns (uint256) {
        uint256 start = a.lockupEndTime;
        if (a.amountTotal == 0 || block.timestamp < start) return 0;
        uint256 end = a.vestingEndTime;
        uint256 vested = block.timestamp >= end
            ? a.amountTotal
            : a.amountTotal * (block.timestamp - start) / (end - start);
        return vested - a.amountClaimed;
    }
}
