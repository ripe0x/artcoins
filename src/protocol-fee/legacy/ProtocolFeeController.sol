// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBurnRouter} from "../IBurnRouter.sol";

/// @title ProtocolFeeController
/// @notice The stable, canonical recipient of every artcoin's protocol-fee
///         share (default 20% of the trading fee). Splits incoming fees among
///         three downstream sinks:
///
///           - `treasury`            → artcoins protocol treasury
///           - `burnRouter`          → LAYER buy-and-burn engine
///           - `rewardsReceiver`     → optional supporter rewards (initially address(0))
///
///         The controller's address itself never changes — it's the stable
///         point that the factory's `teamFeeRecipient` is set to, and that
///         the locker reward array embeds into every coin's protocol slot.
///         Only its downstream wiring and split bps are mutable, and only by
///         the controller's admin (presumed multisig).
///
/// @dev    Bounds (enforced):
///           - treasuryBps ≥ 4000  (treasury share ≥ 40%)
///           - burnBps ≥ 2000      (burn share ≥ 20%)
///           - rewardsBps ≤ 2500   (supporter rewards ≤ 25%)
///           - sum == 10_000       (always 100%)
///
///         When `rewardsReceiver == address(0)`, `rewardsBps` must equal 0.
///         Setting a real receiver is required before increasing rewardsBps.
///
///         `processFees(token)` is permissionless and forwards the contract's
///         current balance of `token` to the three sinks per the active split.
///         Any token can be processed — most commonly LAYER and WETH for the
///         LAYER pool, but any future artcoin's protocol fee will arrive here
///         and be processable the same way. WETH and ETH destined for "burn"
///         are forwarded to `burnRouter` to be swapped for LAYER and burned;
///         LAYER destined for "burn" is forwarded to `burnRouter` and burned
///         directly via `processBurnLayer()` (which the burn router exposes
///         permissionlessly for any caller).
contract ProtocolFeeController is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error InvalidSplit(uint16 treasuryBps, uint16 burnBps, uint16 rewardsBps);
    error TreasuryShareTooLow(uint16 treasuryBps, uint16 minBps);
    error BurnShareTooLow(uint16 burnBps, uint16 minBps);
    error RewardsShareTooHigh(uint16 rewardsBps, uint16 maxBps);
    error RewardsReceiverNotSet();
    error EthTransferFailed();
    error InsufficientEthBalance();
    error NothingToProcess();

    // ─── constants ───────────────────────────────────────────────────────

    uint16 public constant BPS = 10_000;
    uint16 public constant MIN_TREASURY_BPS = 4000; // 40%
    uint16 public constant MIN_BURN_BPS = 2000; // 20%
    uint16 public constant MAX_REWARDS_BPS = 2500; // 25%

    // ─── events ──────────────────────────────────────────────────────────

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event BurnRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event RewardsReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event SplitUpdated(uint16 treasuryBps, uint16 burnBps, uint16 rewardsBps);
    event FeesProcessed(
        address indexed token,
        uint256 totalAmount,
        uint256 treasuryAmount,
        uint256 burnAmount,
        uint256 rewardsAmount
    );
    event EthReceived(address indexed from, uint256 amount);
    event AdminRescue(address indexed token, address indexed recipient, uint256 amount);
    event AdminRescueEth(address indexed recipient, uint256 amount);

    // ─── state ───────────────────────────────────────────────────────────

    /// @notice The artcoins protocol treasury.
    address public treasury;
    /// @notice The LAYER BurnRouter. May be replaced (e.g. for upgrades) — the
    ///         new router must report the same `layerToken` as the current one
    ///         (or the controller is being initialized and there is no current
    ///         router yet).
    address public burnRouter;
    /// @notice The supporter-rewards receiver. Initially `address(0)` (disabled).
    address public rewardsReceiver;

    /// @notice Treasury share of incoming fees, in bps. Default 6000 (60%).
    uint16 public treasuryBps = 6000;
    /// @notice LAYER burn share of incoming fees, in bps. Default 4000 (40%).
    uint16 public burnBps = 4000;
    /// @notice Supporter-rewards share, in bps. Default 0 (disabled).
    uint16 public rewardsBps = 0;

    // ─── construction ────────────────────────────────────────────────────

    /// @param owner_ Initial admin (recommend multisig).
    /// @param treasury_ Initial protocol treasury.
    /// @param burnRouter_ Initial LAYER burn router (already pointed at LAYER).
    constructor(address owner_, address treasury_, address burnRouter_) Ownable(owner_) {
        if (owner_ == address(0) || treasury_ == address(0) || burnRouter_ == address(0)) {
            revert ZeroAddress();
        }
        treasury = treasury_;
        burnRouter = burnRouter_;
        emit TreasuryUpdated(address(0), treasury_);
        emit BurnRouterUpdated(address(0), burnRouter_);
        emit SplitUpdated(treasuryBps, burnBps, rewardsBps);
    }

    // ─── admin: downstream wiring ────────────────────────────────────────

    /// @notice Updates the protocol treasury. Admin only.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    /// @notice Updates the LAYER burn router. Admin only.
    /// @dev    The new router must report the same `layerToken` as the current
    ///         one (sanity check guarding against pointing at a wrong-LAYER
    ///         processor). If `IBurnRouter(newRouter).layerToken()` reverts,
    ///         this call reverts too — by design.
    function setBurnRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        address currentLayer = IBurnRouter(burnRouter).layerToken();
        address newLayer = IBurnRouter(newRouter).layerToken();
        if (currentLayer != newLayer) revert ZeroAddress();
        address old = burnRouter;
        burnRouter = newRouter;
        emit BurnRouterUpdated(old, newRouter);
    }

    /// @notice Sets the supporter-rewards receiver. Admin only. Pass `address(0)`
    ///         to disable rewards (also forces `rewardsBps == 0`).
    function setRewardsReceiver(address newReceiver) external onlyOwner {
        // If clearing receiver, also clear rewardsBps to keep invariants sane.
        if (newReceiver == address(0) && rewardsBps != 0) {
            uint16 newRewardsBps = 0;
            // Re-allocate rewardsBps to treasury by default.
            uint16 newTreasuryBps = treasuryBps + rewardsBps;
            _setSplit(newTreasuryBps, burnBps, newRewardsBps);
        }
        address old = rewardsReceiver;
        rewardsReceiver = newReceiver;
        emit RewardsReceiverUpdated(old, newReceiver);
    }

    // ─── admin: split ────────────────────────────────────────────────────

    /// @notice Updates the split among treasury / burn / rewards. Admin only.
    /// @dev    Bounds:
    ///           - treasuryBps_ ≥ 4000
    ///           - burnBps_ ≥ 2000
    ///           - rewardsBps_ ≤ 2500
    ///           - sum == 10_000
    ///         Setting `rewardsBps_ > 0` requires `rewardsReceiver != 0`.
    function setSplit(uint16 treasuryBps_, uint16 burnBps_, uint16 rewardsBps_) external onlyOwner {
        _setSplit(treasuryBps_, burnBps_, rewardsBps_);
    }

    function _setSplit(uint16 treasuryBps_, uint16 burnBps_, uint16 rewardsBps_) internal {
        if (uint256(treasuryBps_) + uint256(burnBps_) + uint256(rewardsBps_) != BPS) {
            revert InvalidSplit(treasuryBps_, burnBps_, rewardsBps_);
        }
        if (treasuryBps_ < MIN_TREASURY_BPS) {
            revert TreasuryShareTooLow(treasuryBps_, MIN_TREASURY_BPS);
        }
        if (burnBps_ < MIN_BURN_BPS) revert BurnShareTooLow(burnBps_, MIN_BURN_BPS);
        if (rewardsBps_ > MAX_REWARDS_BPS) {
            revert RewardsShareTooHigh(rewardsBps_, MAX_REWARDS_BPS);
        }
        if (rewardsBps_ > 0 && rewardsReceiver == address(0)) revert RewardsReceiverNotSet();

        treasuryBps = treasuryBps_;
        burnBps = burnBps_;
        rewardsBps = rewardsBps_;
        emit SplitUpdated(treasuryBps_, burnBps_, rewardsBps_);
    }

    // ─── processing ──────────────────────────────────────────────────────

    /// @notice Forwards this contract's balance of `token` to the three sinks
    ///         per the active split. Permissionless. Reverts if balance is 0.
    /// @dev    `treasury` and `rewardsReceiver` simply receive the ERC20
    ///         transfer. `burnRouter` receives the burn share — for LAYER
    ///         this means a direct burn (the router exposes `processBurnLayer`
    ///         permissionlessly); for WETH (or other tokens) the router will
    ///         later swap them for LAYER and burn.
    /// @param token The ERC20 to process.
    function processFees(address token) external nonReentrant {
        uint256 total = IERC20(token).balanceOf(address(this));
        if (total == 0) revert NothingToProcess();

        // Compute splits with largest-remainder rounding so dust stays in the
        // contract rather than being silently truncated.
        uint256 treasuryAmt = total * treasuryBps / BPS;
        uint256 rewardsAmt = total * rewardsBps / BPS;
        uint256 burnAmt = total - treasuryAmt - rewardsAmt; // takes the rounding remainder

        if (treasuryAmt > 0) {
            IERC20(token).safeTransfer(treasury, treasuryAmt);
        }
        if (rewardsAmt > 0 && rewardsReceiver != address(0)) {
            IERC20(token).safeTransfer(rewardsReceiver, rewardsAmt);
        } else if (rewardsAmt > 0) {
            // Defensive: rewardsBps > 0 should have prevented receiver == 0,
            // but if state is inconsistent, route to treasury.
            IERC20(token).safeTransfer(treasury, rewardsAmt);
            treasuryAmt += rewardsAmt;
            rewardsAmt = 0;
        }
        if (burnAmt > 0) {
            IERC20(token).safeTransfer(burnRouter, burnAmt);
        }

        emit FeesProcessed(token, total, treasuryAmt, burnAmt, rewardsAmt);
    }

    /// @notice Admin-only escape hatch for tokens that get stuck or arrive in
    ///         error (e.g. someone transfers an unrelated NFT-claim token).
    /// @param token The ERC20 to rescue.
    /// @param recipient The recipient.
    /// @param amount The amount.
    function adminRescue(address token, address recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (recipient == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(recipient, amount);
        emit AdminRescue(token, recipient, amount);
    }

    /// @notice Admin-only escape hatch for ETH sent here as flat deploy fees
    ///         or accidental transfers. ERC20 fee processing is unchanged.
    /// @param recipient The recipient.
    /// @param amount Wei to rescue.
    function adminRescueEth(address payable recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount > address(this).balance) revert InsufficientEthBalance();
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit AdminRescueEth(recipient, amount);
    }

    // ─── ETH receive ─────────────────────────────────────────────────────

    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }
}
