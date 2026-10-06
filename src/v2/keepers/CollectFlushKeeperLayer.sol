// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFeeLocker} from "../../interfaces/IArtCoinsFeeLocker.sol";
import {IArtCoinsLpLocker} from "../../interfaces/IArtCoinsLpLocker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {
    PositionInfo,
    PositionInfoLibrary
} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

/// @dev shared by the three live LAYER routers; the current stack one has no `minLayerOutPerWeth` (spot floor)
interface ILayerBurnRouter {
    function processBurnLayer() external returns (uint256);
    function processBurnWeth(uint256 minLayerOut) external returns (uint256, uint256);
    function minProcessThreshold() external view returns (uint256);
    function minLayerOutPerWeth() external view returns (uint256);
}

interface ILayerFeeController {
    function processFees(address token) external;
    function positionManager() external view returns (IPositionManager); // on the locker
}

/// @title  CollectFlushKeeperLayer
/// @notice Stateless keeper for the live LAYER fee path (legacy stack): collect lp fees into the fee locker,
///         push the controller and burn router slots, split the controller, burn LAYER and (optionally) weth
///         at the routers, forward what the keeper received to the caller. No owner, holds nothing.
/// @dev    D49: each step starts only above its gas floor and then gets all remaining gas. A collect revert
///         bubbles, any other step's revert is reported (`StepSkipped`), a revert that leaves gas under the
///         floor reverts `InsufficientGas(step)`. The owner slot (eoa) is never claimed, that is the owner's call.
contract CollectFlushKeeperLayer {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    IPoolManager internal constant POOL_MANAGER =
        IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    IArtCoinsLpLocker public immutable locker;
    address public immutable layer;
    address public immutable weth;
    IArtCoinsFeeLocker public immutable feeLocker;
    address public immutable controller; // locker recipient, sends 40% of what it holds to router0
    /// @dev router0 is the locker recipient and controller burn router; 1 and 2 are other routers on the
    ///      same pool (zero disables a slot)
    address public immutable router0;
    address public immutable router1;
    address public immutable router2;

    /// @dev floors, not caps, from fork measurements (docs/v2/review/keeper-111.md). a weth burn is a swap,
    ///      and every LAYER swap runs the hook's own lp collect, so it costs a collect too.
    uint256 internal constant COLLECT_GAS = 640_000;
    uint256 internal constant CLAIM_GAS = 60_000;
    uint256 internal constant FEES_GAS = 80_000;
    uint256 internal constant BURN_LAYER_GAS = 60_000;
    uint256 internal constant BURN_WETH_GAS = 900_000;
    uint256 internal constant MARGIN = 50_000;

    event KeeperRun(address indexed caller, uint256[5] amounts); // same order as `run` returns
    /// @dev step 2 claim, 3 processFees, 4 processBurnLayer, 5 processBurnWeth; `reason` is the revert data
    event StepSkipped(uint8 indexed step, address indexed target, bytes reason);
    /// @dev gas shortfall at `step` (1 collect .. 5 burn weth): reverts so estimateGas never finds a skip path
    error InsufficientGas(uint8 step);
    error EthTransferFailed();

    /// @dev (legacy locker, LAYER, weth, fee locker, controller, [router0, router1, router2])
    constructor(address lk, address lyr, address w, address fl, address pfc, address[3] memory r) {
        (locker, layer, weth) = (IArtCoinsLpLocker(lk), lyr, w);
        (feeLocker, controller) = (IArtCoinsFeeLocker(fl), pfc);
        (router0, router1, router2) = (r[0], r[1], r[2]);
    }

    receive() external payable {}

    /// @param doBurn also `processBurnWeth` on every router at or above its threshold
    /// @param minLayerOutPerWeth caller floor in LAYER per 1e18 weth (the routers' unit); the keeper passes
    ///        `max(it, router owner floor) * balance / 1e18`, so 0 means the router's own floor
    /// @param unwrap send weth the keeper received as eth
    /// @return lCol LAYER and `wCol` weth the collect credited to the fee locker (all three slots)
    /// @return lBurn LAYER burned directly (`processBurnLayer`); `wBurn` weth in and `lBought` LAYER out of burns
    function run(bool doBurn, uint256 minLayerOutPerWeth, bool unwrap)
        external
        returns (uint256 lCol, uint256 wCol, uint256 lBurn, uint256 wBurn, uint256 lBought)
    {
        uint256 l0 = IERC20(layer).balanceOf(address(feeLocker));
        uint256 w0 = IERC20(weth).balanceOf(address(feeLocker));
        _gas(1, COLLECT_GAS);
        try locker.collectRewards(layer) {}
        catch (bytes memory r) {
            if (gasleft() < COLLECT_GAS + MARGIN) revert InsufficientGas(1);
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
        lCol = IERC20(layer).balanceOf(address(feeLocker)) - l0;
        wCol = IERC20(weth).balanceOf(address(feeLocker)) - w0;

        address[2] memory tokens = [layer, weth];
        address[2] memory slots = [controller, router0];
        for (uint256 i; i < 4; ++i) {
            (address slot, address token) = (slots[i / 2], tokens[i % 2]);
            bytes memory c = abi.encodeCall(IArtCoinsFeeLocker.claim, (slot, token));
            if (feeLocker.availableFees(slot, token) > 0) {
                _step(2, CLAIM_GAS, address(feeLocker), c);
            }
        }
        for (uint256 i; i < 2; ++i) {
            bytes memory c = abi.encodeCall(ILayerFeeController.processFees, (tokens[i]));
            if (IERC20(tokens[i]).balanceOf(controller) > 0) _step(3, FEES_GAS, controller, c);
        }
        address[3] memory routers = [router0, router1, router2];
        for (uint256 i; i < 3; ++i) {
            address r = routers[i];
            if (r == address(0)) continue;
            bytes memory c = abi.encodeCall(ILayerBurnRouter.processBurnLayer, ());
            if (IERC20(layer).balanceOf(r) > 0) {
                (bool ok, bytes memory ret) = _step(4, BURN_LAYER_GAS, r, c);
                if (ok) lBurn += abi.decode(ret, (uint256));
            }
            uint256 bal = IERC20(weth).balanceOf(r) + r.balance;
            if (!doBurn || bal == 0 || bal < ILayerBurnRouter(r).minProcessThreshold()) continue;
            uint256 minOut = Math.mulDiv(bal, minLayerOutPerWeth, 1e18);
            // owner floor 0 (paused) reverts `SlippageFloorNotSet` in the router; no floor getter: spot floor
            try ILayerBurnRouter(r).minLayerOutPerWeth() returns (uint256 f) {
                minOut = Math.max(minOut, Math.mulDiv(bal, f, 1e18));
            } catch {}
            c = abi.encodeCall(ILayerBurnRouter.processBurnWeth, (minOut));
            (bool ok2, bytes memory ret2) = _step(5, BURN_WETH_GAS, r, c);
            if (ok2) {
                (uint256 wIn, uint256 lOut) = abi.decode(ret2, (uint256, uint256));
                wBurn += wIn;
                lBought += lOut;
            }
        }
        _forward(unwrap);
        emit KeeperRun(msg.sender, [lCol, wCol, lBurn, wBurn, lBought]);
    }

    function _step(uint8 step, uint256 floor, address target, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        _gas(step, floor);
        (ok, ret) = target.call(data);
        if (!ok) {
            if (gasleft() < floor + MARGIN) revert InsufficientGas(step);
            emit StepSkipped(step, target, ret);
        }
    }

    function _gas(uint8 step, uint256 cost) internal view {
        uint256 g = cost + MARGIN;
        if (gasleft() < g + g / 63 + 20_000) revert InsufficientGas(step);
    }

    /// @dev router rewards arrive as eth, dust can arrive as anything: all of it leaves now
    function _forward(bool unwrap) internal {
        uint256 w = IERC20(weth).balanceOf(address(this));
        if (w > 0 && unwrap) IWETH9(payable(weth)).withdraw(w);
        else if (w > 0) IERC20(weth).transfer(msg.sender, w);
        uint256 l = IERC20(layer).balanceOf(address(this));
        if (l > 0) IERC20(layer).transfer(msg.sender, l);
        if (address(this).balance > 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            if (!ok) revert EthTransferFailed();
        }
    }

    /// @notice Runner view. `uncollected*`: lp fees owed to the locker positions, both currencies. `claimable`:
    ///         fee locker slots the keeper pushes [controller LAYER, controller weth, router0 LAYER, router0
    ///         weth]. `routerWeth`: weth plus eth per router (what a burn swaps) vs its `minProcessThreshold`.
    function preview()
        external
        view
        returns (
            uint256 uncollectedLayer,
            uint256 uncollectedWeth,
            uint256[4] memory claimable,
            uint256[3] memory routerWeth,
            uint256[3] memory routerThreshold
        )
    {
        IArtCoinsLpLocker.TokenRewardInfo memory info = locker.tokenRewards(layer);
        IPositionManager pm = ILayerFeeController(address(locker)).positionManager();
        PoolId pid = info.poolKey.toId();
        uint256 f0;
        uint256 f1;
        for (uint256 i; i < info.numPositions; ++i) {
            PositionInfo p = pm.positionInfo(info.positionId + i);
            (uint256 g0, uint256 g1) =
                POOL_MANAGER.getFeeGrowthInside(pid, p.tickLower(), p.tickUpper());
            (uint128 liq, uint256 a0, uint256 a1) = POOL_MANAGER.getPositionInfo(
                pid, address(pm), p.tickLower(), p.tickUpper(), bytes32(info.positionId + i)
            );
            unchecked {
                f0 += FullMath.mulDiv(g0 - a0, liq, FixedPoint128.Q128);
                f1 += FullMath.mulDiv(g1 - a1, liq, FixedPoint128.Q128);
            }
        }
        bool layer0 = Currency.unwrap(info.poolKey.currency0) == layer;
        (uncollectedLayer, uncollectedWeth) = layer0 ? (f0, f1) : (f1, f0);
        for (uint256 i; i < 4; ++i) {
            claimable[i] = feeLocker.availableFees(i < 2 ? controller : router0, i % 2 == 0 ? layer : weth);
        }
        address[3] memory rs = [router0, router1, router2];
        for (uint256 i; i < 3; ++i) {
            if (rs[i] == address(0)) continue;
            routerWeth[i] = IERC20(weth).balanceOf(rs[i]) + rs[i].balance;
            routerThreshold[i] = ILayerBurnRouter(rs[i]).minProcessThreshold();
        }
    }
}
