// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IProtocolFeeControllerV2
/// @notice Protocol fee recipient. Splits what it receives between the
///         treasury and the burn router, each share at or above its minimum.
///         `token == address(0)` is native eth.
interface IProtocolFeeControllerV2 {
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);
    event BurnRouterSet(address indexed oldRouter, address indexed newRouter);
    event SplitSet(uint16 treasuryBps, uint16 burnBps);
    event FeesProcessed(
        address indexed token, uint256 totalAmount, uint256 treasuryAmount, uint256 burnAmount
    );
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error TreasuryShareTooLow(uint16 treasuryBps, uint16 minBps);
    error BurnShareTooLow(uint16 burnBps, uint16 minBps);
    error NothingToProcess();
    error EthTransferFailed();

    /// @notice Splits the held balance of `token` (0 = eth) and delivers both shares.
    function processFees(address token) external;

    function treasury() external view returns (address);
    function burnRouter() external view returns (address);
    function treasuryBps() external view returns (uint16);
    function burnBps() external view returns (uint16);

    function setTreasury(address treasury_) external;
    function setBurnRouter(address burnRouter_) external;
    /// @dev treasuryBps >= Constants.PFC_MIN_TREASURY_BPS, burn share >= Constants.PFC_MIN_BURN_BPS.
    function setSplit(uint16 treasuryBps_) external;
    function rescue(address token, address to, uint256 amount) external;
}
