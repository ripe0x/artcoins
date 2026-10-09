// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IProtocolFeeControllerV2
/// @notice Protocol fee recipient for every coin. Splits the balance it holds between
///         the treasury and the burn router. `token == address(0)` is native eth.
/// @dev    Owner setters apply to every coin. The treasury share is 4000 to 9000 bps and the
///         burn share is the remainder, so each share stays at or above its Constants minimum
///         (PFC_MIN_TREASURY_BPS 4000, PFC_MIN_BURN_BPS 1000). Bps are 1/10,000.
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

    /// @notice A balance was split and delivered.
    /// @param token Processed token, `address(0)` for eth.
    /// @param totalAmount Balance processed, in base units.
    /// @param treasuryAmount Amount delivered to the treasury.
    /// @param burnAmount Amount delivered to the burn router or burned directly.
    event FeesProcessed(
        address indexed token, uint256 totalAmount, uint256 treasuryAmount, uint256 burnAmount
    );

    /// @notice The owner withdrew funds.
    /// @param token Withdrawn token, `address(0)` for eth.
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
    /// @notice The held balance of the token is zero.
    error NothingToProcess();
    /// @notice The native eth transfer in `rescue` failed.
    error NativeTransferFailed();

    /// @notice Splits the held balance of `token` and delivers both shares.
    /// @dev Callable by anyone. Eth and erc20 shares are pushed with an escrow fallback
    ///      (FeeDelivery). Erc20 treatment: when `token` is the burn router's coin the burn
    ///      share is burned here, and a coin that refuses the burn is sent to the router;
    ///      any other erc20 goes wholly to the treasury. Reverts `NothingToProcess` and
    ///      `InvalidTransferReturn` (FeeDelivery) for an erc20 `transfer` that returns false
    ///      or malformed data.
    /// @param token Token to process, `address(0)` for eth.
    function processFees(address token) external;

    /// @notice Recipient of the treasury share.
    function treasury() external view returns (address);

    /// @notice Recipient of the burn share.
    function burnRouter() external view returns (address);

    /// @notice Treasury share in bps.
    function treasuryBps() external view returns (uint16);

    /// @notice Burn share in bps, `10,000 - treasuryBps`.
    function burnBps() external view returns (uint16);

    /// @notice Sets the treasury.
    /// @dev Owner only. Reverts `ZeroAddress`.
    /// @param treasury_ New treasury.
    function setTreasury(address treasury_) external;

    /// @notice Sets the burn router. The old router is not called.
    /// @dev Owner only. Reverts `ZeroAddress`.
    /// @param burnRouter_ New router.
    function setBurnRouter(address burnRouter_) external;

    /// @notice Sets the treasury share; the burn share becomes the remainder.
    /// @dev Owner only. Reverts `TreasuryShareTooLow` below 4000 bps and `BurnShareTooLow`
    ///      above 9000 bps.
    /// @param treasuryBps_ New treasury share in bps.
    function setSplit(uint16 treasuryBps_) external;

    /// @notice Sends any held balance, including eth, to `to`.
    /// @dev Owner only. Reverts `ZeroAddress` when `to` is zero and `NativeTransferFailed`.
    /// @param token Token to send, `address(0)` for eth.
    /// @param to Receiver.
    /// @param amount Amount in base units.
    function rescue(address token, address to, uint256 amount) external;

    /// @notice Fee escrow credited when a push fails. Immutable.
    function feeEscrow() external view returns (address);

    /// @notice Gas forwarded on each push to the treasury or burn router.
    function PUSH_GAS() external view returns (uint256);

    /// @notice `receive` splits on arrival only with at least this much gas.
    function RECEIVE_SPLIT_MIN_GAS() external view returns (uint256);

    /// @notice Stack version tag (Constants.STACK_VERSION).
    function STACK_VERSION() external view returns (uint16);
}
