// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IFeeAutoSwapper
/// @notice Auto-swap of accrued artcoin-side fees into WETH for a single
///         (artcoin, fee-locker, pool) triple. Permissionless `convert`
///         pulls escrowed artcoin out of the fee locker, swaps to WETH via
///         the same V4 pool, and forwards WETH to a pre-configured
///         `endRecipient` (either back into the fee locker for that recipient,
///         or as a direct ERC20 transfer). The caller earns a small WETH
///         keeper reward.
interface IFeeAutoSwapper {
    /// @notice Emitted on a successful `convert`. `wethOut` is the total
    ///         received from the V4 swap; `wethToRecipient` is the amount
    ///         delivered to `endRecipient` after the keeper share.
    event Converted(
        address indexed caller,
        uint256 artcoinIn,
        uint256 wethOut,
        uint256 wethToRecipient,
        uint256 wethToKeeper
    );

    /// @notice Emitted on a successful `flushPaired`. The swapper, as the
    ///         registered slot recipient, may also accrue paired-side
    ///         (WETH or ETH) fees at the escrow from buy-side LP fees;
    ///         `flushPaired` drains those to `endRecipient` minus a keeper
    ///         reward, mirroring `convert` for the artcoin-side path.
    event Flushed(
        address indexed caller, uint256 pairedOut, uint256 pairedToRecipient, uint256 pairedToKeeper
    );

    /// @notice Zero-address constructor argument for a required field.
    error ZeroAddress(string field);
    /// @notice `endRecipient` cannot be the swapper itself (would loop).
    error InvalidEndRecipient();
    /// @notice `artCoin` and `weth` must be distinct addresses.
    error InvalidWeth();
    /// @notice `convert` called before `nextConvertibleBlock()`.
    error ConvertTooEarly(uint256 nextBlock);
    /// @notice No artcoin balance available to convert (neither in escrow nor held).
    error NothingToConvert();
    /// @notice No paired-side balance available to flush at the escrow.
    error NothingToFlush();
    /// @notice V4 swap returned fewer WETH than the caller's `minOut`.
    error InsufficientOutput(uint256 received, uint256 minOut);
    /// @notice Caller-supplied `minOut` is below the configured per-token floor.
    error MinOutBelowFloor(uint256 minOut, uint256 floor);
    /// @notice V4 swap reported more input was spent than the contract requested.
    ///         Defends against a hook returning a delta that bypasses the per-call cap.
    error ExcessInputSpent(uint256 spent, uint256 requested);
    /// @notice Setter argument outside its admin-bounded range.
    error OutOfBounds(uint256 value, uint256 lo, uint256 hi);
    /// @notice Unlock callback called by something other than the PoolManager.
    error NotPoolManager();
    /// @notice Internal sanity check on V4 swap delta sign.
    error BadDelta();
    /// @notice Native-ETH transfer to `endRecipient` or `msg.sender` failed.
    error NativeSendFailed();
    /// @notice `convert` or `flushPaired` called before `setup` bound the
    ///         artcoin token. Setup runs exactly once, post-construction,
    ///         to break the deploy-time cycle where the artcoin is created
    ///         by the artcoins factory in the same transaction that
    ///         registers this swapper as a reward recipient.
    error NotFinalized();
    /// @notice `setup` called by a non-deployer or after it already ran.
    error NotDeployer();
    /// @notice `setup` called a second time. Once is the contract.
    error AlreadyFinalized();

    /// @notice Permissionless. Pulls escrowed artcoin out of the fee locker,
    ///         swaps to the paired currency via the configured V4 pool,
    ///         forwards the net to `endRecipient`, and pays the caller a
    ///         bounded reward.
    /// @param  minOut Caller's own slippage threshold on the swap output.
    ///         The contract enforces an additional post-swap floor against
    ///         a spot-derived expected output (see `convert`'s NatSpec on
    ///         the implementation contract and the threat-model notes for
    ///         the same-tx manipulation caveat). A caller passing `minOut = 0`
    ///         relies entirely on the contract's spot floor; setting `minOut`
    ///         from an off-chain reference rate is stronger.
    /// @return wethOut Gross paired amount received from the swap
    ///         (pre-keeper-reward). On native-ETH-paired pools this is wei of
    ///         native ETH delivered to the contract via `poolManager.take`.
    function convert(uint256 minOut) external returns (uint256 wethOut);

    /// @notice Permissionless. Drains paired-side (WETH or ETH) fees the
    ///         swapper has accrued at the escrow as the registered slot
    ///         recipient, and forwards them to `endRecipient` minus the
    ///         keeper reward. Sibling to `convert` for the no-swap path —
    ///         buy-side LP fees go straight through without touching the
    ///         pool. Reverts with `NothingToFlush` if there's nothing to
    ///         drain.
    /// @return pairedOut Gross paired-side amount drained (pre-keeper-reward).
    function flushPaired() external returns (uint256 pairedOut);

    /// @notice One-shot bind of the artcoin token. Deployer-only, callable
    ///         once. Required before `convert` / `flushPaired` can run.
    ///         Breaks the deploy-time cycle on a factory-deployed token:
    ///         the swapper is constructed with the pool topology (paired
    ///         side, hook, fee, tick spacing) and registered with the LP
    ///         locker as a reward recipient before the artcoin exists; the
    ///         deployer then calls `setup(token)` once the factory returns
    ///         the address.
    /// @param  artCoin_ The deployed artcoin token address.
    function setup(address artCoin_) external;

    /// @notice True after `setup` has run.
    function setupFinalized() external view returns (bool);

    /// @notice Total artcoin currently swappable: balance held + balance escrowed.
    function accruedArtCoin() external view returns (uint256);

    /// @notice Total paired-side currency the swapper has accrued at the
    ///         escrow (claimable via `flushPaired`).
    function accruedPaired() external view returns (uint256);

    /// @notice Earliest block at which `convert` will succeed.
    function nextConvertibleBlock() external view returns (uint256);

    /// @notice The V4 `PoolKey` for this swapper's pool.
    function poolKey() external view returns (PoolKey memory);
}
