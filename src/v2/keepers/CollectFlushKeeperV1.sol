// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFeeLocker} from "../../interfaces/IArtCoinsFeeLocker.sol";
import {IArtCoinsLpLocker} from "../../interfaces/IArtCoinsLpLocker.sol";
import {IFeeAutoSwapper} from "../../interfaces/IFeeAutoSwapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {
    PositionInfo,
    PositionInfoLibrary
} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

interface ILockerPositionManager {
    function positionManager() external view returns (IPositionManager);
}

/// @title  CollectFlushKeeperV1
/// @notice Stateless keeper pinned to the live coin 111 stack (v1 locker, escrow, fee swapper). `run` collects
///         LP fees, flushes escrowed eth, optionally converts coin fees, forwards all rewards to the caller.
/// @dev    Narrows the v1 stranding window (a third party `escrow.claim(swapper, 0)` pushes eth into the
///         swapper where `flushPaired` cannot see it) by collecting and flushing in one tx; it cannot recover
///         eth already stranded. Non-gas reverts of a step are swallowed, gas shortfalls revert.
contract CollectFlushKeeperV1 {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    IPoolManager internal constant POOL_MANAGER =
        IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    IArtCoinsLpLocker public immutable locker;
    address public immutable token;
    IFeeAutoSwapper public immutable swapper;
    IArtCoinsFeeLocker public immutable escrow;

    /// @dev step gas measured on a mainnet fork, MARGIN added on top
    uint256 internal constant COLLECT_GAS = 658_000;
    uint256 internal constant CONVERT_GAS = 299_000;
    uint256 internal constant FLUSH_GAS = 72_000;
    uint256 internal constant MARGIN = 50_000;

    event KeeperRun(address indexed caller, uint256 collected, uint256 flushed, uint256 converted);

    /// @dev gas shortfall for `step` (1 collect, 2 flush, 3 convert). Reverts rather than skips so an
    ///      estimateGas search cannot land on a path that silently skips a step.
    error InsufficientGas(uint8 step);

    constructor(address locker_, address token_, address swapper_, address escrow_) {
        locker = IArtCoinsLpLocker(locker_);
        token = token_;
        swapper = IFeeAutoSwapper(swapper_);
        escrow = IArtCoinsFeeLocker(escrow_);
    }

    receive() external payable {}

    /// @param doConvert also run `convert(minOut)` (e.g. min blocks reverts are swallowed, converted is 0)
    /// @return collected eth credited to the swapper's escrow slot, flushed gross eth drained, converted gross eth
    function run(bool doConvert, uint256 minOut)
        external
        returns (uint256 collected, uint256 flushed, uint256 converted)
    {
        uint256 before_ = escrow.availableFees(address(swapper), address(0));
        uint256 g = _gas(1, COLLECT_GAS);
        try locker.collectRewards{gas: g}(token) {
            collected = escrow.availableFees(address(swapper), address(0)) - before_;
        } catch (bytes memory r) {
            if (r.length == 0) revert InsufficientGas(1);
        }
        g = _gas(2, FLUSH_GAS);
        try swapper.flushPaired{gas: g}() returns (uint256 out) {
            flushed = out;
        } catch (bytes memory r) {
            if (r.length == 0) revert InsufficientGas(2);
        }
        if (doConvert) {
            g = _gas(3, CONVERT_GAS);
            try swapper.convert{gas: g}(minOut) returns (uint256 out) {
                converted = out;
            } catch (bytes memory r) {
                if (r.length == 0) revert InsufficientGas(3);
            }
        }
        // forward rewards (locker, flush, convert) and any coin sent to us
        if (address(this).balance > 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "eth forward failed");
        }
        uint256 coin = IERC20(token).balanceOf(address(this));
        if (coin > 0) {
            try IERC20(token).transfer(msg.sender, coin) {} catch {}
        }
        emit KeeperRun(msg.sender, collected, flushed, converted);
    }

    function _gas(uint8 step, uint256 cost) internal view returns (uint256 g) {
        g = cost + MARGIN;
        if (gasleft() < g + g / 63 + 20_000) revert InsufficientGas(step);
    }

    /// @notice Runner view (pool currency0 eth, currency1 coin). `uncollected*`: gross LP fees owed to the locker
    ///         positions. `escrowedEth`: what flush drains. `swapperEth` above 0 means a third party claim
    ///         stranded eth. `swapperCoin`: coin the swapper can convert (held plus escrowed).
    function preview()
        external
        view
        returns (
            uint256 uncollectedEth,
            uint256 uncollectedCoin,
            uint256 escrowedEth,
            uint256 swapperEth,
            uint256 swapperCoin
        )
    {
        escrowedEth = escrow.availableFees(address(swapper), address(0));
        swapperEth = address(swapper).balance;
        swapperCoin = swapper.accruedArtCoin();
        IArtCoinsLpLocker.TokenRewardInfo memory info = locker.tokenRewards(token);
        IPositionManager pm = ILockerPositionManager(address(locker)).positionManager();
        PoolId pid = info.poolKey.toId();
        for (uint256 i; i < info.numPositions; ++i) {
            PositionInfo p = pm.positionInfo(info.positionId + i);
            (uint256 g0, uint256 g1) =
                POOL_MANAGER.getFeeGrowthInside(pid, p.tickLower(), p.tickUpper());
            (uint128 liq, uint256 l0, uint256 l1) = POOL_MANAGER.getPositionInfo(
                pid, address(pm), p.tickLower(), p.tickUpper(), bytes32(info.positionId + i)
            );
            unchecked {
                uncollectedEth += FullMath.mulDiv(g0 - l0, liq, FixedPoint128.Q128);
                uncollectedCoin += FullMath.mulDiv(g1 - l1, liq, FixedPoint128.Q128);
            }
        }
    }
}
