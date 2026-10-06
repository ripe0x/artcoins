// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IFeeAutoSwapperV2
/// @notice Sits in a locker reward slot for one art coin. `convert` swaps the
///         coin side fees to native eth through the coin's pool; `flushPaired`
///         forwards the eth side. Both forward to the frozen `endRecipient`.
///         The swapper opts into escrow `selfClaimOnly` and holds no paired
///         funds between calls. `supportsInterface` returns true for
///         `type(IFeeAutoSwapperV2).interfaceId`.
interface IFeeAutoSwapperV2 is IERC165 {
    // ── events ────────────────────────────────────────────────────────────

    event ArtCoinBound(address indexed artCoin);
    event Converted(
        address indexed caller,
        uint256 artCoinIn,
        uint256 pairedOut,
        uint256 pairedToRecipient,
        uint256 pairedToKeeper
    );
    event Flushed(
        address indexed caller, uint256 pairedOut, uint256 pairedToRecipient, uint256 pairedToKeeper
    );
    event MaxSlippageBpsSet(uint256 oldBps, uint256 newBps);
    event MinBlocksBetweenConvertsSet(uint256 oldBlocks, uint256 newBlocks);
    event MaxStepInSet(uint256 oldMax, uint256 newMax);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ── errors ────────────────────────────────────────────────────────────

    error ZeroAddress(string field);
    error InvalidEndRecipient();
    error NotDeployer();
    error AlreadyFinalized();
    error NotFinalized();
    error ConvertTooEarly(uint256 nextBlock);
    error NothingToConvert();
    error NothingToFlush();
    error InsufficientOutput(uint256 received, uint256 minOut);
    error MinOutBelowFloor(uint256 minOut, uint256 floor);
    error ExcessInputSpent(uint256 spent, uint256 requested);
    error OutOfBounds(uint256 value, uint256 lo, uint256 hi);
    error BadDelta();
    error NativeSendFailed();
    error CannotRescue(address token);

    // ── permissionless ────────────────────────────────────────────────────

    /// @notice Claims escrowed coin, swaps up to `maxStepIn` to eth, forwards
    ///         the output plus any held eth, pays a bounded keeper reward.
    /// @return pairedOut Gross eth received from the swap.
    function convert(uint256 minOut) external returns (uint256 pairedOut);
    /// @notice Claims escrowed eth if any, then forwards the whole eth balance.
    /// @return pairedOut Gross eth forwarded (before keeper reward).
    function flushPaired() external returns (uint256 pairedOut);

    // ── setup ─────────────────────────────────────────────────────────────

    /// @notice Deployer only, once. Binds the coin after the factory launch.
    function setup(address artCoin_) external;
    function setupFinalized() external view returns (bool);

    // ── reads ─────────────────────────────────────────────────────────────

    function artCoin() external view returns (address);
    function endRecipient() external view returns (address);
    function feeEscrow() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
    function maxSlippageBps() external view returns (uint256);
    function minBlocksBetweenConverts() external view returns (uint256);
    function maxStepIn() external view returns (uint256);
    function nextConvertibleBlock() external view returns (uint256);
    /// @notice Coin held plus coin escrowed.
    function accruedArtCoin() external view returns (uint256);
    /// @notice Eth held plus eth escrowed.
    function accruedPaired() external view returns (uint256);

    // ── owner (within Constants bounds) ───────────────────────────────────

    function setMaxSlippageBps(uint256 bps) external;
    function setMinBlocksBetweenConverts(uint256 blocks) external;
    function setMaxStepIn(uint256 maxIn) external;
    /// @notice Sends tokens other than the paired currency and the art coin.
    function rescue(address token, address to, uint256 amount) external;
}
