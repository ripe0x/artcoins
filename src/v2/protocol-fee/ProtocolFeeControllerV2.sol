// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsFeeEscrowV2} from "../interfaces/IArtCoinsFeeEscrowV2.sol";
import {IBurnRouterV2} from "../interfaces/IBurnRouterV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";
import {IProtocolFeeControllerV2} from "../interfaces/IProtocolFeeControllerV2.sol";
import {FeeDelivery} from "../libraries/FeeDelivery.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title  ProtocolFeeControllerV2
/// @notice Protocol fee recipient for every v2 coin. Splits its eth between
///         `treasury` and `burnRouter` by `treasuryBps`.
/// @dev    The hook pushes the protocol leg of each swap here. A failed push
///         credits this contract in the fee escrow. `processFees` claims that
///         credit and splits the whole eth balance. It is callable by anyone.
///         Each share is pushed with `PUSH_GAS`. A failed push credits the
///         share's recipient in the escrow, which requires this contract to be
///         an escrow depositor. Until it is, a failed push reverts
///         `processFees` and the eth stays here for a retry.
///         The split covers eth: every wei of the balance is split by `processFees`.
///         Erc20 sent here is recoverable with `rescue`.
///         Owner powers apply to every coin: `treasury`, `burnRouter`,
///         `treasuryBps` within [PFC_MIN_TREASURY_BPS, BPS - PFC_MIN_BURN_BPS]
///         (1000 to 9000 bps), and `rescue` of any erc20. `setBurnRouter` does not
///         call the old router, so a faulty router can be replaced. The treasury
///         and the router differ from each other and from this contract, the treasury
///         differs from `feeEscrow`, and the router answers `constantsHash()` with this
///         build's hash and reports the `coin` and `poolManager` fixed at construction from
///         the initial router.
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
    address public immutable coin;
    /// @inheritdoc IProtocolFeeControllerV2
    address public immutable poolManager;

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
        coin = _readAddress(burnRouter_, IBurnRouterV2.coin.selector);
        poolManager = _readAddress(burnRouter_, IBurnRouterV2.poolManager.selector);
        if (coin == address(0) || poolManager == address(0)) revert InvalidRecipient(burnRouter_);
        _checkRecipients(treasury_, burnRouter_);
        _checkRouter(burnRouter_);
        treasury = treasury_;
        burnRouter = burnRouter_;
        emit TreasurySet(address(0), treasury_);
        emit BurnRouterSet(address(0), burnRouter_);
        _setSplit(treasuryBps_);
    }

    /// @notice Accepts eth from any sender, including the hook and the escrow.
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
        _checkRecipients(treasury_, burnRouter);
        emit TreasurySet(treasury, treasury_);
        treasury = treasury_;
    }

    /// @inheritdoc IProtocolFeeControllerV2
    function setBurnRouter(address burnRouter_) external onlyOwner {
        if (burnRouter_ == address(0)) revert ZeroAddress();
        _checkRecipients(treasury, burnRouter_);
        _checkRouter(burnRouter_);
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
        if (token == address(0)) revert CannotRescue(token);
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Rescued(token, to, amount);
    }

    // ── internals ─────────────────────────────────────────────────────────

    /// @dev The recipients differ from each other and from this contract.
    function _checkRecipients(address treasury_, address router_) private view {
        if (treasury_ == address(this) || treasury_ == feeEscrow) {
            revert InvalidRecipient(treasury_);
        }
        if (router_ == address(this) || router_ == treasury_) revert InvalidRecipient(router_);
    }

    /// @dev `router_.constantsHash()` must equal this build's hash, and `coin()` and
    ///      `poolManager()` must equal the values fixed at construction (nonzero).
    function _checkRouter(address router_) private view {
        (bool ok, bytes memory ret) =
            router_.staticcall(abi.encodeCall(IConstantsBound.constantsHash, ()));
        if (!ok || ret.length != 32 || abi.decode(ret, (bytes32)) != Constants.hash()) {
            revert ConstantsMismatch(router_);
        }
        if (
            _readAddress(router_, IBurnRouterV2.coin.selector) != coin
                || _readAddress(router_, IBurnRouterV2.poolManager.selector) != poolManager
        ) revert InvalidRecipient(router_);
    }

    function _readAddress(address target, bytes4 selector) private view returns (address a) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSelector(selector));
        if (ok && ret.length == 32) a = abi.decode(ret, (address));
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
