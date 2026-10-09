// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IArtCoinsKeeperV2
/// @notice Permissionless collect and forward for v2 coins: collects locker
///         rewards, flushes (and optionally converts) every fee swapper
///         recipient, and forwards keeper rewards to the caller. Holds nothing.
interface IArtCoinsKeeperV2 {
    /// @notice One keeper run: `nativeForwarded` eth and `coinForwarded` coin
    ///         were sent to `caller`.
    event KeeperRun(
        address indexed caller,
        address indexed token,
        uint256 nativeForwarded,
        uint256 coinForwarded
    );

    /// @notice `token` was not launched by this keeper's factory.
    error NotCoin(address token);
    /// @notice An eth transfer to the caller failed.
    error NativeTransferFailed();

    /// @notice Collect `token`'s locker rewards, flush every fee swapper reward
    ///         recipient (and, when `doConvert`, convert its coin to eth at a
    ///         floor of at least `minOut`), then forward all eth and coin
    ///         received to the caller. Permissionless; holds nothing.
    function collectAndForward(address token, bool doConvert, uint256 minOut) external;

    /// @notice The factory whose coins this keeper serves.
    function factory() external view returns (address);

    /// @notice Stack version tag (Constants.STACK_VERSION).
    function STACK_VERSION() external view returns (uint16);
}
