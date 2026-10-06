// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFeeLocker} from "../../interfaces/IArtCoinsFeeLocker.sol";
import {IArtCoinsLpLocker} from "../../interfaces/IArtCoinsLpLocker.sol";
import {IFeeAutoSwapper} from "../../interfaces/IFeeAutoSwapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

interface ILockerPositionManager {
    function positionManager() external view returns (IPositionManager);
}

/// @title  CollectFlushKeeperV1
/// @notice Stateless keeper pinned to the live coin 111 stack (v1 locker, escrow, fee swapper).
///         `run` collects LP fees, flushes the swapper's escrowed eth, optionally converts coin side
///         fees, then forwards anything it received (locker, flush and convert keeper rewards) to the
///         caller. Holds no funds between calls and has no owner.
/// @dev    Narrows the v1 stranding window (a third party `escrow.claim(swapper, 0)` pushes eth into the
///         swapper where `flushPaired` cannot see it) by doing collect then flush in one tx. It cannot
///         recover eth already stranded. Every step is try/catch so one failing step never blocks the rest.
contract CollectFlushKeeperV1 {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    IArtCoinsLpLocker public immutable locker;
    address public immutable token;
    IFeeAutoSwapper public immutable swapper;
    IArtCoinsFeeLocker public immutable escrow;

    event KeeperRun(address indexed caller, uint256 collected, uint256 flushed, uint256 converted);

    constructor(address locker_, address token_, address swapper_, address escrow_) {
        locker = IArtCoinsLpLocker(locker_);
        token = token_;
        swapper = IFeeAutoSwapper(swapper_);
        escrow = IArtCoinsFeeLocker(escrow_);
    }

    receive() external payable {}

    /// @param doConvert also swap the swapper's coin side fees (reverts inside are swallowed, e.g. min blocks)
    /// @param minOut min eth out for `convert`; ignored when `doConvert` is false
    /// @return collected eth credited to the swapper's escrow slot by the collect step
    /// @return flushed gross eth drained by `flushPaired`
    /// @return converted gross eth received by `convert`
    function run(bool doConvert, uint256 minOut)
        external
        returns (uint256 collected, uint256 flushed, uint256 converted)
    {
        uint256 before_ = escrow.availableFees(address(swapper), address(0));
        try locker.collectRewards(token) {
            collected = escrow.availableFees(address(swapper), address(0)) - before_;
        } catch {}
        try swapper.flushPaired() returns (uint256 out) {
            flushed = out;
        } catch {}
        if (doConvert) {
            try swapper.convert(minOut) returns (uint256 out) {
                converted = out;
            } catch {}
        }
        // forward rewards received (eth from locker, flush, convert) and any coin sent to us
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

    /// @notice Runner view. `uncollectedHint` is the gross eth (currency0) LP fee owed to the locker's
    ///         positions, before the locker keeper reward. `escrowed` is eth claimable by the swapper at
    ///         the escrow (what `flushPaired` drains). `swapperPaired` is eth sitting in the swapper (should
    ///         be 0; above 0 means a third party claim stranded it).
    function preview()
        external
        view
        returns (uint256 uncollectedHint, uint256 escrowed, uint256 swapperPaired)
    {
        escrowed = escrow.availableFees(address(swapper), address(0));
        swapperPaired = address(swapper).balance;
        IArtCoinsLpLocker.TokenRewardInfo memory info = locker.tokenRewards(token);
        IPositionManager pm = ILockerPositionManager(address(locker)).positionManager();
        for (uint256 i; i < info.numPositions; ++i) {
            uint256 id = info.positionId + i;
            PositionInfo p = pm.positionInfo(id);
            (uint256 g0,) = POOL_MANAGER.getFeeGrowthInside(info.poolKey.toId(), p.tickLower(), p.tickUpper());
            (uint128 liq, uint256 last0,) = POOL_MANAGER.getPositionInfo(
                info.poolKey.toId(), address(pm), p.tickLower(), p.tickUpper(), bytes32(id)
            );
            unchecked {
                uncollectedHint += FullMath.mulDiv(g0 - last0, liq, FixedPoint128.Q128);
            }
        }
    }
}
