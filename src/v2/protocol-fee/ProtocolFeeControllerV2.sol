// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IBurnRouterV2} from "../interfaces/IBurnRouterV2.sol";
import {IBurnableCoin} from "../interfaces/IBurnableCoin.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";
import {IProtocolFeeControllerV2} from "../interfaces/IProtocolFeeControllerV2.sol";
import {FeeDelivery} from "../libraries/FeeDelivery.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title  ProtocolFeeControllerV2
/// @notice Protocol fee recipient. Splits what it holds between `treasury`
///         and `burnRouter`; each share is at or above its Constants minimum.
///         Delivery is push with escrow fallback (FeeDelivery).
/// @dev    Properties:
///         - the owner sets the treasury share within [PFC_MIN_TREASURY_BPS,
///           BPS - PFC_MIN_BURN_BPS] (4000 to 9000 bps). Owner setters apply
///           to every coin.
///         - `setBurnRouter` does not call the old router, so a faulty router
///           can be replaced.
///         - erc20 burn share: when `token` is the router's coin, the burn
///           share is burned here with the coin's `burn`. Any other erc20 goes
///           wholly to the treasury.
///         - the owner can rescue any balance, including eth.
///         - `receive` does not revert. It splits eth on arrival when the
///           call has at least RECEIVE_SPLIT_MIN_GAS gas, through a try wrapped
///           self call, and otherwise holds the eth for a later
///           `processFees(address(0))`. The hook and locker push with a gas cap
///           below that, so their pushes succeed.
///         Escrow fallback requires this contract to be an escrow depositor.
///         Until it is, a failed push reverts `processFees` and the funds stay
///         here for a retry.
contract ProtocolFeeControllerV2 is
    IProtocolFeeControllerV2,
    IConstantsBound,
    Ownable2Step,
    ReentrancyGuardTransient
{
    /// @inheritdoc IProtocolFeeControllerV2
    uint256 public constant PUSH_GAS = Constants.PUSH_GAS_MAX;
    /// @inheritdoc IProtocolFeeControllerV2
    uint256 public constant RECEIVE_SPLIT_MIN_GAS = 500_000;
    /// @notice Gas for reading `burnRouter.coin()`.
    uint256 internal constant COIN_READ_GAS = 30_000;

    /// @inheritdoc IProtocolFeeControllerV2
    address public immutable feeEscrow;

    /// @inheritdoc IProtocolFeeControllerV2
    address public treasury;
    /// @inheritdoc IProtocolFeeControllerV2
    address public burnRouter;
    /// @inheritdoc IProtocolFeeControllerV2
    uint16 public treasuryBps;
    /// @inheritdoc IProtocolFeeControllerV2
    uint16 public burnBps;

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

    /// @notice Accepts eth. With at least RECEIVE_SPLIT_MIN_GAS gas, splits the
    ///         whole eth balance; otherwise holds it for `processFees(address(0))`.
    receive() external payable {
        if (gasleft() >= RECEIVE_SPLIT_MIN_GAS) {
            try this.processFees(address(0)) {} catch {}
        }
    }

    // ── processing ────────────────────────────────────────────────────────

    /// @inheritdoc IProtocolFeeControllerV2
    function processFees(address token) external nonReentrant {
        uint256 total = token == address(0)
            ? address(this).balance
            : SafeTransferLib.balanceOf(token, address(this));
        if (total == 0) revert NothingToProcess();

        address t = treasury;
        address r = burnRouter;
        uint256 burnAmt;
        if (token == address(0)) {
            burnAmt = total - (total * treasuryBps) / Constants.BPS;
            FeeDelivery.sendNative(feeEscrow, t, total - burnAmt, PUSH_GAS);
            FeeDelivery.sendNative(feeEscrow, r, burnAmt, PUSH_GAS);
        } else {
            if (token == _routerCoin(r)) {
                burnAmt = total - (total * treasuryBps) / Constants.BPS;
                // A coin whose burn reverts goes to the router, which burns
                // every coin it holds on its next burn.
                if (burnAmt > 0) {
                    try IBurnableCoin(token).burn(burnAmt) {}
                    catch {
                        FeeDelivery.sendErc20(feeEscrow, token, r, burnAmt);
                    }
                }
            }
            FeeDelivery.sendErc20(feeEscrow, token, t, total - burnAmt);
        }
        emit FeesProcessed(token, total, total - burnAmt, burnAmt);
    }

    // ── owner ─────────────────────────────────────────────────────────────

    /// @inheritdoc IProtocolFeeControllerV2
    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        emit TreasurySet(treasury, treasury_);
        treasury = treasury_;
    }

    /// @inheritdoc IProtocolFeeControllerV2
    /// @dev The old router is not called.
    function setBurnRouter(address burnRouter_) external onlyOwner {
        if (burnRouter_ == address(0)) revert ZeroAddress();
        emit BurnRouterSet(burnRouter, burnRouter_);
        burnRouter = burnRouter_;
    }

    /// @inheritdoc IProtocolFeeControllerV2
    function setSplit(uint16 treasuryBps_) external onlyOwner {
        _setSplit(treasuryBps_);
    }

    /// @inheritdoc IProtocolFeeControllerV2
    /// @dev Any token, including native eth (`token == address(0)`). Reverts
    ///      `NativeTransferFailed` when the eth send fails.
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

    /// @inheritdoc IProtocolFeeControllerV2
    uint16 public constant STACK_VERSION = Constants.STACK_VERSION;

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _setSplit(uint16 treasuryBps_) internal {
        if (treasuryBps_ < Constants.PFC_MIN_TREASURY_BPS) {
            revert TreasuryShareTooLow(treasuryBps_, Constants.PFC_MIN_TREASURY_BPS);
        }
        if (treasuryBps_ > Constants.BPS - Constants.PFC_MIN_BURN_BPS) {
            uint16 b = treasuryBps_ > Constants.BPS ? 0 : uint16(Constants.BPS - treasuryBps_);
            revert BurnShareTooLow(b, Constants.PFC_MIN_BURN_BPS);
        }
        treasuryBps = treasuryBps_;
        burnBps = uint16(Constants.BPS - treasuryBps_);
        emit SplitSet(treasuryBps_, burnBps);
    }

    /// @dev `router.coin()`, or zero when the router does not answer. Uses a
    ///      gas capped staticcall so a router without code or without `coin()`
    ///      returns zero.
    function _routerCoin(address r) internal view returns (address c) {
        bytes4 sel = IBurnRouterV2.coin.selector;
        uint256 g = COIN_READ_GAS;
        assembly ("memory-safe") {
            mstore(0x00, sel)
            let ok := staticcall(g, r, 0x00, 0x04, 0x00, 0x20)
            if and(ok, gt(returndatasize(), 0x1f)) {
                c := and(mload(0x00), 0xffffffffffffffffffffffffffffffffffffffff)
            }
        }
    }
}
