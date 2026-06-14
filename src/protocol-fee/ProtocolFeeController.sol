// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBurnRouter} from "./IBurnRouter.sol";

/// @title  ProtocolFeeController
/// @notice Fixed two-sink protocol-fee splitter. Routes the protocol's fee
///         slice to exactly two sinks — `treasury` and `burnRouter` — per a
///         split that is fixed at construction and immutable thereafter.
///         Exposes both `processFees(token)` for ERC20 fees and
///         `processNativeFees()` for native-ETH fees, because artcoins can be
///         paired with native ETH, so their protocol-slot payouts arrive here
///         as native ETH (claimed via the fee escrow's
///         `claim(this, address(0))` path).
///
/// @dev    Design notes:
///
///         - **The split is immutable.** `treasuryBps`/`burnBps` are set once
///           per instance in the constructor and can never be changed. There
///           is no owner knob to redirect fees between treasury and burn. Each
///           protocol that needs a different ratio deploys its own instance
///           (LAYER 6000/4000, permanent-collection 8667/1333); the split and
///           treasury are global to the instance by design, so a separate
///           instance is how two protocols get independent routing.
///         - **The two sinks always sum to 100%.** `burnBps` is derived as
///           `BPS - treasuryBps`, so the split cannot be configured to a
///           non-100% total. Construction validates the floors only
///           (treasury ≥ 40%, burn ≥ 10%).
///         - **The only mutable surface is recipient rotation** (`setTreasury`,
///           `setBurnRouter`). There is no rescue or withdrawal hatch, so
///           in-transit fee principal can only leave through the immutable
///           split, never to an owner-chosen address; the owner can rotate the
///           two recipients but cannot directly grab the balance. `setBurnRouter`
///           requires the replacement to report the same `layerToken()` so the
///           burn share can never be re-pointed at a different token.
///
///         `processFees(token)` assumes `token` is an ERC20 and starts with
///         `IERC20(token).balanceOf(this)`. Passing `address(0)` reverts, so a
///         parallel `processNativeFees()` splits `address(this).balance` per the
///         same bps and forwards the burn share to `BurnRouter` as native ETH
///         (BurnRouter accepts it via `receive()` and wraps to WETH internally
///         on processBurnWeth).
contract ProtocolFeeController is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error LayerTokenMismatch();
    error TreasuryShareTooLow(uint16 treasuryBps, uint16 minBps);
    error BurnShareTooLow(uint16 burnBps, uint16 minBps);
    error EthTransferFailed();
    error NothingToProcess();

    // ─── constants ───────────────────────────────────────────────────────

    uint16 public constant BPS = 10_000;
    uint16 public constant MIN_TREASURY_BPS = 4000;
    uint16 public constant MIN_BURN_BPS = 1000;

    // ─── events ──────────────────────────────────────────────────────────

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event BurnRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event FeesProcessed(
        address indexed token, uint256 totalAmount, uint256 treasuryAmount, uint256 burnAmount
    );
    /// @notice Emitted by `processNativeFees()` — parallel to `FeesProcessed`
    ///         but for native ETH. `token` is implicit (`address(0)`).
    event NativeFeesProcessed(uint256 totalAmount, uint256 treasuryAmount, uint256 burnAmount);
    event EthReceived(address indexed from, uint256 amount);

    // ─── state ───────────────────────────────────────────────────────────

    address public treasury;
    address public burnRouter;

    /// @notice Treasury share of incoming fees, in bps. Fixed at construction.
    uint16 public immutable treasuryBps;
    /// @notice Burn share of incoming fees, in bps. Derived as `BPS -
    ///         treasuryBps` at construction, so the two shares always sum to
    ///         100%.
    uint16 public immutable burnBps;

    // ─── construction ────────────────────────────────────────────────────

    /// @param owner_       Admin (presumed multisig) for recipient rotation.
    /// @param treasury_    Treasury sink.
    /// @param burnRouter_  Burn sink (LAYER buy-and-burn engine).
    /// @param treasuryBps_ Treasury share in bps. The burn share is the
    ///                     remainder (`BPS - treasuryBps_`). Must satisfy
    ///                     `MIN_TREASURY_BPS ≤ treasuryBps_ ≤ BPS - MIN_BURN_BPS`,
    ///                     i.e. treasury ∈ [40%, 90%] and burn ∈ [10%, 60%].
    constructor(address owner_, address treasury_, address burnRouter_, uint16 treasuryBps_)
        Ownable(owner_)
    {
        if (owner_ == address(0) || treasury_ == address(0) || burnRouter_ == address(0)) {
            revert ZeroAddress();
        }
        if (treasuryBps_ < MIN_TREASURY_BPS) {
            revert TreasuryShareTooLow(treasuryBps_, MIN_TREASURY_BPS);
        }
        // Upper bound: the derived burn share must clear MIN_BURN_BPS. This
        // also rejects treasuryBps_ > BPS (which would underflow below).
        if (treasuryBps_ > BPS - MIN_BURN_BPS) {
            revert BurnShareTooLow(treasuryBps_ <= BPS ? BPS - treasuryBps_ : 0, MIN_BURN_BPS);
        }

        treasury = treasury_;
        burnRouter = burnRouter_;
        treasuryBps = treasuryBps_;
        burnBps = BPS - treasuryBps_;

        emit TreasuryUpdated(address(0), treasury_);
        emit BurnRouterUpdated(address(0), burnRouter_);
    }

    // ─── admin: downstream wiring ────────────────────────────────────────

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function setBurnRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        address currentLayer = IBurnRouter(burnRouter).layerToken();
        address newLayer = IBurnRouter(newRouter).layerToken();
        if (currentLayer != newLayer) revert LayerTokenMismatch();
        address old = burnRouter;
        burnRouter = newRouter;
        emit BurnRouterUpdated(old, newRouter);
    }

    // ─── processing ──────────────────────────────────────────────────────

    /// @notice ERC20 path. Forwards this contract's balance of `token` to the
    ///         two sinks per the fixed split. Permissionless. Reverts if
    ///         balance is 0 OR if `token == address(0)` (use `processNativeFees`
    ///         instead).
    function processFees(address token) external nonReentrant {
        if (token == address(0)) revert NothingToProcess(); // see processNativeFees
        uint256 total = IERC20(token).balanceOf(address(this));
        if (total == 0) revert NothingToProcess();

        uint256 treasuryAmt = total * treasuryBps / BPS;
        uint256 burnAmt = total - treasuryAmt; // burn absorbs the rounding dust

        if (treasuryAmt > 0) {
            IERC20(token).safeTransfer(treasury, treasuryAmt);
        }
        if (burnAmt > 0) {
            IERC20(token).safeTransfer(burnRouter, burnAmt);
        }

        emit FeesProcessed(token, total, treasuryAmt, burnAmt);
    }

    /// @notice Native-ETH path. Forwards `address(this).balance` to the two
    ///         sinks per the fixed split as native ETH. Permissionless. Reverts
    ///         if balance is 0.
    /// @dev    The burn share is sent to `burnRouter` as native ETH;
    ///         BurnRouter's `receive()` accepts it, and `processBurnWeth(...)`
    ///         wraps any contract ETH balance to WETH at the top before
    ///         swapping to LAYER. The treasury must be payable (have
    ///         `receive()` or a payable fallback). If a recipient rejects ETH,
    ///         this whole call reverts and the balance stays for retry.
    function processNativeFees() external nonReentrant {
        uint256 total = address(this).balance;
        if (total == 0) revert NothingToProcess();

        uint256 treasuryAmt = total * treasuryBps / BPS;
        uint256 burnAmt = total - treasuryAmt; // burn absorbs the rounding dust

        if (treasuryAmt > 0) {
            (bool okT,) = payable(treasury).call{value: treasuryAmt}("");
            if (!okT) revert EthTransferFailed();
        }
        if (burnAmt > 0) {
            (bool okB,) = payable(burnRouter).call{value: burnAmt}("");
            if (!okB) revert EthTransferFailed();
        }

        emit NativeFeesProcessed(total, treasuryAmt, burnAmt);
    }

    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }
}
