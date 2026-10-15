// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IProtocolFeeControllerV2
/// @notice Protocol fee recipient for every coin. Splits the eth it holds between the treasury
///         and the burn router.
/// @dev    Owner setters apply to every coin. The treasury share is 1000 to 9000 bps and the
///         burn share is the remainder, so each share stays at or above its Constants minimum
///         (PFC_MIN_TREASURY_BPS 1000, PFC_MIN_BURN_BPS 1000). Bps are 1/10,000.
interface IProtocolFeeControllerV2 {
    /// @notice The owner changed the treasury.
    /// @param oldTreasury Previous treasury, zero at construction.
    /// @param newTreasury New treasury.
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);

    /// @notice The owner changed the burn router.
    /// @param oldRouter Previous router, zero at construction.
    /// @param newRouter New router.
    event BurnRouterSet(address indexed oldRouter, address indexed newRouter);

    /// @notice The split changed.
    /// @param treasuryBps Treasury share in bps.
    /// @param burnBps Burn share in bps.
    event SplitSet(uint16 treasuryBps, uint16 burnBps);

    /// @notice The eth balance was split and delivered.
    /// @param totalAmount Eth processed, in wei.
    /// @param treasuryAmount Eth delivered to the treasury, in wei.
    /// @param burnAmount Eth delivered to the burn router, in wei.
    event FeesProcessed(uint256 totalAmount, uint256 treasuryAmount, uint256 burnAmount);

    /// @notice The owner withdrew funds.
    /// @param token Withdrawn erc20.
    /// @param to Receiver.
    /// @param amount Amount in base units.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice An address argument is the zero address.
    error ZeroAddress();
    /// @notice The treasury share is below the Constants minimum.
    /// @param treasuryBps Supplied share in bps.
    /// @param minBps Minimum share in bps.
    error TreasuryShareTooLow(uint16 treasuryBps, uint16 minBps);
    /// @notice The implied burn share is below the Constants minimum.
    /// @param burnBps Implied share in bps.
    /// @param minBps Minimum share in bps.
    error BurnShareTooLow(uint16 burnBps, uint16 minBps);
    /// @notice No eth is held and none is credited in the escrow.
    error NothingToProcess();
    /// @notice A recipient is this contract, or the treasury and the burn router are the same
    ///         address, or the router reports a zero `coin()` or `poolManager()`.
    /// @param recipient Offending address.
    error InvalidRecipient(address recipient);
    /// @notice `rescue` was called for eth. Held eth is split by `processFees`.
    /// @param token The refused token, `address(0)`.
    error CannotRescue(address token);

    /// @notice Claims the controller's eth credit from the fee escrow, then splits the whole eth
    ///         balance and delivers both shares.
    /// @dev Callable by anyone. Each share is pushed with `PUSH_GAS` and credited to its
    ///      recipient in the escrow when the push fails. Reverts `NothingToProcess`.
    function processFees() external;

    /// @notice Recipient of the treasury share.
    function treasury() external view returns (address);

    /// @notice Recipient of the burn share.
    function burnRouter() external view returns (address);

    /// @notice Treasury share in bps.
    function treasuryBps() external view returns (uint16);

    /// @notice Burn share in bps, `10,000 - treasuryBps`.
    function burnBps() external view returns (uint16);

    /// @notice Eth the next `processFees` would split, in wei: the balance plus the escrow credit.
    function pending() external view returns (uint256);

    /// @notice Sets the treasury.
    /// @dev Owner only. Reverts `ZeroAddress`, and `InvalidRecipient` when `treasury_` is this
    ///      contract or the burn router.
    /// @param treasury_ New treasury.
    function setTreasury(address treasury_) external;

    /// @notice Sets the burn router. The old router is not called.
    /// @dev Owner only. Reverts `ZeroAddress`, `InvalidRecipient` when the router is this contract,
    ///      the treasury, or reports a zero `coin()` or `poolManager()`, and `ConstantsMismatch`
    ///      when it does not report this build's constants hash.
    /// @param burnRouter_ New router.
    function setBurnRouter(address burnRouter_) external;

    /// @notice Sets the treasury share; the burn share becomes the remainder.
    /// @dev Owner only. Reverts `TreasuryShareTooLow` below 1000 bps and `BurnShareTooLow`
    ///      above 9000 bps.
    /// @param treasuryBps_ New treasury share in bps.
    function setSplit(uint16 treasuryBps_) external;

    /// @notice Sends a held erc20 balance to `to`.
    /// @dev Owner only. Reverts `ZeroAddress` when `to` is zero and `CannotRescue` for eth, which
    ///      `processFees` splits.
    /// @param token Erc20 to send.
    /// @param to Receiver.
    /// @param amount Amount in base units.
    function rescue(address token, address to, uint256 amount) external;

    /// @notice Fee escrow credited when a push fails and claimed by `processFees`. Immutable.
    function feeEscrow() external view returns (address);

    /// @notice Gas forwarded on each push to the treasury or burn router.
    function PUSH_GAS() external view returns (uint256);

    /// @notice Stack version tag (Constants.STACK_VERSION).
    function STACK_VERSION() external view returns (uint16);
}
