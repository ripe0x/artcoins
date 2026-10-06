// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactoryV2} from "../interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsKeeperV2} from "../interfaces/IArtCoinsKeeperV2.sol";
import {IArtCoinsLpLockerV2} from "../interfaces/IArtCoinsLpLockerV2.sol";
import {IFeeAutoSwapperV2} from "../interfaces/IFeeAutoSwapperV2.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title  ArtCoinsKeeperV2
/// @notice Permissionless, stateless, ownerless keeper for any v2 art coin. One call collects the coin's locker
///         rewards, flushes (and optionally converts) every locker reward recipient that is a fee swapper,
///         then forwards every wei and coin it received to the caller. Holds nothing between calls.
/// @dev    Step gas values are floors, not caps (D49). Before a step `gasleft()` must exceed floor plus margin or
///         the call reverts `InsufficientGas(step)`; the step then gets all remaining gas, so a collect that
///         grows past the old figure still runs. A step that reverts with `gasleft()` back under its floor is out
///         of gas and reports `InsufficientGas(step)`. Otherwise the revert is real: collect bubbles its revert
///         data, flush and convert are swallowed and reported (`FlushSkipped`, `ConvertSkipped`) so one idle or
///         broken slot does not block the rest (`NothingToFlush`, `ConvertTooEarly` are the common ones). Revert
///         data is copied up to 256 bytes (no return bomb). The floor figures are the v1 measurements (collect
///         658k for 14 positions, convert 299k, flush 72k) with room added, to be re measured on the v2 stack.
///         Recipients are the locker's frozen reward list (bounded by Constants.MAX_REWARD_PARTICIPANTS).
contract ArtCoinsKeeperV2 is IArtCoinsKeeperV2, ReentrancyGuardTransient {
    address public immutable factory;

    // step ids used by `InsufficientGas`
    uint8 internal constant STEP_COLLECT = 1;
    uint8 internal constant STEP_FLUSH = 2;
    uint8 internal constant STEP_CONVERT = 3;
    uint8 internal constant STEP_PROBE = 4;

    uint256 internal constant COLLECT_GAS = 900_000;
    uint256 internal constant FLUSH_GAS = 150_000;
    uint256 internal constant CONVERT_GAS = 400_000;
    uint256 internal constant PROBE_GAS = 30_000; // erc165 recommends 30k for supportsInterface
    uint256 internal constant MARGIN = 50_000;
    uint256 internal constant MAX_REASON = 256;

    /// @dev gas shortfall for `step` (1 collect, 2 flush, 3 convert, 4 erc165 probe).
    error InsufficientGas(uint8 step);
    error ZeroAddress();
    error CoinTransferFailed();

    /// @notice One fee swapper serviced. `flushed` and `converted` are gross eth, 0 when the step reverted.
    event SwapperServiced(
        address indexed token, address indexed swapper, uint256 flushed, uint256 converted
    );
    /// @notice A swapper's `convert` reverted for a reason other than gas (too early, nothing to convert, ...).
    event ConvertSkipped(address indexed token, address indexed swapper, bytes reason);
    /// @notice A swapper's `flushPaired` reverted for a reason other than gas (usually `NothingToFlush`).
    event FlushSkipped(address indexed token, address indexed swapper, bytes reason);

    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /// @dev Locker keeper rewards and swapper keeper rewards arrive here, then leave in the same call.
    receive() external payable {}

    /// @inheritdoc IArtCoinsKeeperV2
    function collectAndForward(address token, bool doConvert, uint256 minOut)
        external
        nonReentrant
    {
        IArtCoinsLpLockerV2 locker = _lockerOf(token);

        // collect: a real failure surfaces (bubbles), only a gas shortfall maps to InsufficientGas
        {
            (bool ok,, bytes memory reason) = _step(
                STEP_COLLECT,
                address(locker),
                abi.encodeCall(IArtCoinsLpLockerV2.collectRewards, (token)),
                COLLECT_GAS
            );
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }

        address[] memory recipients = locker.rewardRecipients(token);
        uint256 n = recipients.length;
        for (uint256 i; i < n; ++i) {
            address r = recipients[i];
            if (_seenBefore(recipients, i) || !_isSwapper(r)) continue;

            (bool ok, uint256 flushed, bytes memory reason) =
                _step(STEP_FLUSH, r, abi.encodeCall(IFeeAutoSwapperV2.flushPaired, ()), FLUSH_GAS);
            if (!ok) emit FlushSkipped(token, r, reason);
            uint256 converted;
            if (doConvert) {
                (ok, converted, reason) = _step(
                    STEP_CONVERT,
                    r,
                    abi.encodeCall(IFeeAutoSwapperV2.convert, (minOut)),
                    CONVERT_GAS
                );
                if (!ok) emit ConvertSkipped(token, r, reason);
            }
            emit SwapperServiced(token, r, flushed, converted);
        }

        // forward everything received (locker reward, flush and convert rewards, any coin)
        uint256 eth = address(this).balance;
        if (eth > 0) {
            (bool ok,) = msg.sender.call{value: eth}("");
            if (!ok) revert EthTransferFailed();
        }
        uint256 coin = _balanceOf(token);
        if (coin > 0) _sendCoin(token, msg.sender, coin);
        emit KeeperRun(msg.sender, token, eth, coin);
    }

    /// @notice What a run could service for `token`: the swapper recipients and what they hold. Uncollected lp
    ///         fees are not readable through the locker interface, so they are not included; run on a schedule.
    /// @return swappers Reward recipients that are fee swappers.
    /// @return accruedPaired Sum of eth held plus escrowed across them (what `flushPaired` drains).
    /// @return accruedArtCoin Sum of coin held plus escrowed across them (what `convert` can swap).
    /// @return nextConvertibleBlock Earliest block at which any of them can convert (0 when none).
    function preview(address token)
        external
        view
        returns (
            uint256 swappers,
            uint256 accruedPaired,
            uint256 accruedArtCoin,
            uint256 nextConvertibleBlock
        )
    {
        IArtCoinsLpLockerV2 locker = _lockerOf(token);
        address[] memory recipients = locker.rewardRecipients(token);
        for (uint256 i; i < recipients.length; ++i) {
            address r = recipients[i];
            if (_seenBefore(recipients, i) || !_isSwapper(r)) continue;
            ++swappers;
            try IFeeAutoSwapperV2(r).accruedPaired() returns (uint256 p) {
                accruedPaired += p;
            } catch {}
            try IFeeAutoSwapperV2(r).accruedArtCoin() returns (uint256 c) {
                accruedArtCoin += c;
            } catch {}
            try IFeeAutoSwapperV2(r).nextConvertibleBlock() returns (uint256 b) {
                if (nextConvertibleBlock == 0 || b < nextConvertibleBlock) {
                    nextConvertibleBlock = b;
                }
            } catch {}
        }
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _lockerOf(address token) internal view returns (IArtCoinsLpLockerV2) {
        IArtCoinsFactoryV2.DeploymentInfoV2 memory info =
            IArtCoinsFactoryV2(factory).deploymentInfo(token);
        if (info.token != token || info.locker == address(0)) revert NotArtCoin(token);
        return IArtCoinsLpLockerV2(info.locker);
    }

    /// @dev One step with all remaining gas; `cost` is the floor. Success returns the first returned word (one
    ///      word copied only). Failure returns the revert data (at most `MAX_REASON` bytes), unless `gasleft()`
    ///      fell back under the floor: that is out of gas and reverts `InsufficientGas(step)`.
    function _step(uint8 step, address target, bytes memory data, uint256 cost)
        internal
        returns (bool ok, uint256 out, bytes memory reason)
    {
        _gas(step, cost);
        uint256 size;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            ok := call(gas(), target, 0, add(data, 0x20), mload(data), ptr, 0x20)
            size := returndatasize()
            if and(ok, iszero(lt(size, 0x20))) { out := mload(ptr) }
        }
        if (ok) return (true, out, reason);
        if (gasleft() < cost + MARGIN) revert InsufficientGas(step);
        if (size > MAX_REASON) size = MAX_REASON;
        reason = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(reason, 0x20), 0, size)
        }
    }

    /// @dev Reverts rather than skips on a gas shortfall (63/64 rule plus 20k for the work after the call).
    function _gas(uint8 step, uint256 cost) internal view returns (uint256 g) {
        g = cost + MARGIN;
        if (gasleft() < g + g / 63 + 20_000) revert InsufficientGas(step);
    }

    /// @dev erc165 probe, gas capped, copies at most one word of returndata. A recipient that is an eoa, has
    ///      no `supportsInterface`, reverts, or returns anything but 1 is not a swapper.
    function _isSwapper(address r) internal view returns (bool yes) {
        _gas(STEP_PROBE, PROBE_GAS);
        bytes4 id = type(IFeeAutoSwapperV2).interfaceId;
        bytes memory data = abi.encodeCall(IERC165.supportsInterface, (id));
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let ok := staticcall(PROBE_GAS, r, add(data, 0x20), mload(data), ptr, 0x20)
            yes := and(and(ok, eq(returndatasize(), 0x20)), eq(mload(ptr), 1))
        }
    }

    function _seenBefore(address[] memory a, uint256 i) internal pure returns (bool) {
        for (uint256 j; j < i; ++j) {
            if (a[j] == a[i]) return true;
        }
        return false;
    }

    function _balanceOf(address token) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        if (ok && ret.length >= 32) bal = abi.decode(ret, (uint256));
    }

    function _sendCoin(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert CoinTransferFailed();
    }
}
