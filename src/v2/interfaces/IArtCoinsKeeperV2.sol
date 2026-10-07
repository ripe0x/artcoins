// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IArtCoinsKeeperV2
/// @notice Permissionless collect and forward for v2 coins: collects locker
///         rewards, flushes (and optionally converts) every fee swapper
///         recipient, and forwards keeper rewards to the caller. Holds nothing.
interface IArtCoinsKeeperV2 {
    event KeeperRun(
        address indexed caller,
        address indexed token,
        uint256 nativeForwarded,
        uint256 coinForwarded
    );

    error NotArtCoin(address token);
    error EthTransferFailed();

    function collectAndForward(address token, bool doConvert, uint256 minOut) external;

    function factory() external view returns (address);
}
