// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsFeeEscrowV2} from "../interfaces/IArtCoinsFeeEscrowV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";
import {IProtocolFeeControllerV2} from "../interfaces/IProtocolFeeControllerV2.sol";
import {FeeDelivery} from "../libraries/FeeDelivery.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title  ProtocolFeeControllerV2
/// @notice Protocol fee recipient. The hook pushes the protocol leg of every
///         swap here with the eth stipend; a failed push credits this contract
///         in the fee escrow. `processFees` claims that credit and splits the
///         eth balance between `treasury` and `burnRouter`.
/// @dev    Properties:
///         - the owner sets the treasury share within [PFC_MIN_TREASURY_BPS,
///           BPS - PFC_MIN_BURN_BPS] (4000 to 9000 bps). Owner setters apply
///           to every coin.
///         - `setBurnRouter` does not call the old router, so a faulty router
///           can be replaced.
///         - each share is pushed with `PUSH_GAS` and credited in the escrow on
///           failure (FeeDelivery), which requires this contract to be an escrow
///           depositor. Until it is, a failed push reverts `processFees` and the
///           eth stays here for a retry.
///         - erc20 sent here is rescuable by the owner; the split is eth only.
contract ProtocolFeeControllerV2 is
    IProtocolFeeControllerV2,
    IConstantsBound,
    Ownable2Step,
    ReentrancyGuardTransient
{
    /// @inheritdoc IProtocolFeeControllerV2
    uint256 public constant PUSH_GAS = Constants.PUSH_GAS_MAX;
    /// @inheritdoc IProtocolFeeControllerV2
    uint16 public constant STACK_VERSION = Constants.STACK_VERSION;

    /// @inheritdoc IProtocolFeeControllerV2
    address public immutable feeEscrow;

    /// @inheritdoc IProtocolFeeControllerV2
    address public treasury;
    /// @inheritdoc IProtocolFeeControllerV2
    address public burnRouter;
    /// @inheritdoc IProtocolFeeControllerV2
    uint16 public treasuryBps;

    constructor(
        address owner_,
        address feeEscrow_,
        address treasury_,
        address burnRouter_,
        uint16 treasuryBps_
    ) Ownable(owner_) {
        if (feeEscrow_ == address(0) || treasury_ == address(0) || burnRouter_ == address(0)) {
            revert ZeroAddress();
        }
        feeEscrow = feeEscrow_;
        treasury = treasury_;
        burnRouter = burnRouter_;
        emit TreasurySet(address(0), treasury_);
        emit BurnRouterSet(address(0), burnRouter_);
        _setSplit(treasuryBps_);
    }

    /// @notice Accepts eth from the hook, the locker, the escrow and anyone else.
    receive() external payable {}

    // ── processing ────────────────────────────────────────────────────────

    /// @inheritdoc IProtocolFeeControllerV2
    function processFees() external nonReentrant {
        IArtCoinsFeeEscrowV2 escrow = IArtCoinsFeeEscrowV2(feeEscrow);
        if (escrow.balances(address(this), address(0)) != 0) {
            escrow.claim(address(this), address(0));
        }
        uint256 total = address(this).balance;
        if (total == 0) revert NothingToProcess();

        uint256 treasuryAmount = (total * treasuryBps) / Constants.BPS;
        uint256 burnAmount = total - treasuryAmount;
        FeeDelivery.sendNative(feeEscrow, treasury, treasuryAmount, PUSH_GAS);
        FeeDelivery.sendNative(feeEscrow, burnRouter, burnAmount, PUSH_GAS);
        emit FeesProcessed(total, treasuryAmount, burnAmount);
    }

    // ── reads ─────────────────────────────────────────────────────────────

    /// @inheritdoc IProtocolFeeControllerV2
    function burnBps() external view returns (uint16) {
        return uint16(Constants.BPS) - treasuryBps;
    }

    /// @inheritdoc IProtocolFeeControllerV2
    function pending() external view returns (uint256) {
        return
            address(this).balance
                + IArtCoinsFeeEscrowV2(feeEscrow).balances(address(this), address(0));
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    // ── owner ─────────────────────────────────────────────────────────────

    /// @inheritdoc IProtocolFeeControllerV2
    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        emit TreasurySet(treasury, treasury_);
        treasury = treasury_;
    }

    /// @inheritdoc IProtocolFeeControllerV2
    function setBurnRouter(address burnRouter_) external onlyOwner {
        if (burnRouter_ == address(0)) revert ZeroAddress();
        _checkConstants(burnRouter_);
        emit BurnRouterSet(burnRouter, burnRouter_);
        burnRouter = burnRouter_;
    }

    /// @inheritdoc IProtocolFeeControllerV2
    function setSplit(uint16 treasuryBps_) external onlyOwner {
        _setSplit(treasuryBps_);
    }

    /// @inheritdoc IProtocolFeeControllerV2
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
        emit Rescued(token, to, amount);
    }

    // ── internals ─────────────────────────────────────────────────────────

    /// @dev `target.constantsHash()` must equal this build's hash.
    function _checkConstants(address target) private view {
        (bool ok, bytes memory ret) =
            target.staticcall(abi.encodeCall(IConstantsBound.constantsHash, ()));
        if (!ok || ret.length != 32 || abi.decode(ret, (bytes32)) != Constants.hash()) {
            revert ConstantsMismatch(target);
        }
    }

    function _setSplit(uint16 treasuryBps_) internal {
        if (treasuryBps_ < Constants.PFC_MIN_TREASURY_BPS) {
            revert TreasuryShareTooLow(treasuryBps_, Constants.PFC_MIN_TREASURY_BPS);
        }
        if (treasuryBps_ > Constants.BPS - Constants.PFC_MIN_BURN_BPS) {
            uint16 b = treasuryBps_ > Constants.BPS ? 0 : uint16(Constants.BPS - treasuryBps_);
            revert BurnShareTooLow(b, Constants.PFC_MIN_BURN_BPS);
        }
        treasuryBps = treasuryBps_;
        emit SplitSet(treasuryBps_, uint16(Constants.BPS - treasuryBps_));
    }
}
