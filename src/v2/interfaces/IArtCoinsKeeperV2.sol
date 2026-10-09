// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IArtCoinsKeeperV2
/// @notice Permissionless collect and forward for v2 coins: collects locker
///         rewards, flushes (and optionally converts) every fee swapper
///         recipient, and forwards keeper rewards to the caller. It forwards all eth it receives; on a restricted coin the coin reward stays in the keeper (CoinForwardSkipped).
interface IArtCoinsKeeperV2 {
    /// @notice One keeper run: `nativeForwarded` eth and `coinForwarded` coin
    ///         were sent to `caller`.
    event KeeperRun(
        address indexed caller,
        address indexed token,
        uint256 nativeForwarded,
        uint256 coinForwarded
    );
    /// @notice One fee swapper serviced; `flushed` and `converted` are gross eth,
    ///         0 when that step reverted.
    event SwapperServiced(
        address indexed token, address indexed swapper, uint256 flushed, uint256 converted
    );
    /// @notice A swapper's `convert` reverted for a reason other than gas.
    event ConvertSkipped(address indexed token, address indexed swapper, bytes reason);
    /// @notice A swapper's `flushPaired` reverted for a reason other than gas.
    event FlushSkipped(address indexed token, address indexed swapper, bytes reason);
    /// @notice A restricted coin's keeper reward coin was not forwarded, because
    ///         the keeper is not on the coin allowlist; the coin stays in the keeper.
    event CoinForwardSkipped(address indexed token, uint256 amount);

    /// @notice `token` was not launched by this keeper's factory.
    error NotCoin(address token);
    /// @notice An eth transfer to the caller failed.
    error NativeTransferFailed();
    /// @notice Too little gas remained before `step` (1 collect, 2 flush, 3
    ///         convert, 4 erc165 probe).
    error InsufficientGas(uint8 step);
    /// @notice A required address argument is the zero address.
    error ZeroAddress();
    /// @notice Forwarding the coin reward to the caller failed on an unrestricted coin.
    error CoinTransferFailed();

    /// @notice Collect `token`'s locker rewards, flush every fee swapper reward
    ///         recipient (and, when `doConvert`, convert its coin to eth at a
    ///         floor of at least `minOut`), then forward all eth and coin
    ///         received to the caller. Permissionless. On a
    ///         restricted coin whose allowlist excludes the keeper, the coin
    ///         reward cannot be forwarded and stays here (CoinForwardSkipped).
    function collectAndForward(address token, bool doConvert, uint256 minOut) external;

    /// @notice What a run could service for `token` now. Uncollected lp fees are
    ///         not readable through the locker, so they are excluded.
    /// @return swappers Reward recipients that are fee swappers.
    /// @return accruedPaired Eth held plus escrowed across them.
    /// @return accruedCoin Coin held plus escrowed across them.
    /// @return nextConvertibleBlock Earliest block any of them can convert (0 when none).
    function preview(address token)
        external
        view
        returns (
            uint256 swappers,
            uint256 accruedPaired,
            uint256 accruedCoin,
            uint256 nextConvertibleBlock
        );

    /// @notice The factory whose coins this keeper serves.
    function factory() external view returns (address);

    /// @notice Stack version tag (Constants.STACK_VERSION).
    function STACK_VERSION() external view returns (uint16);
}
