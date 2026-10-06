// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFeeLocker} from "../../interfaces/IArtCoinsFeeLocker.sol";
import {IArtCoinsLpLocker} from "../../interfaces/IArtCoinsLpLocker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {
    PositionInfo,
    PositionInfoLibrary
} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

/// @dev the three live LAYER routers; the current stack one has no `minLayerOutPerWeth` (spot floor instead)
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
/// @notice Stateless keeper for the live LAYER fee path (legacy stack): collect, push the controller and
///         router fee locker slots, split, burn LAYER and weth, forward what it got to the caller. No owner.
/// @dev    D49 floors (see `_step`). The owner slot (eoa) is never claimed, that is the owner's call.
contract CollectFlushKeeperLayer {
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    IPoolManager internal constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IArtCoinsLpLocker public immutable locker;
    address public immutable layer;
    address public immutable weth;
    IArtCoinsFeeLocker public immutable feeLocker;
    address public immutable controller; // locker recipient, sends 40% of what it holds to router0
    /// @dev router0: locker recipient and controller burn router. 1, 2: other routers on the LAYER pool
    address public immutable router0;
    address public immutable router1;
    address public immutable router2;
    /// @dev gas floors, not caps (docs/v2/review/keeper-111.md). a weth burn swaps, so it pays a hook collect
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
    /// @param minLayerOutPerWeth LAYER per 1e18 weth; a router with an owner floor gets
    ///        `max(it, floor) * balance / 1e18`, one without gets 0 (its own spot floor)
    /// @param unwrap send weth the keeper received as eth
    /// @dev returns collect credits (LAYER, weth; all slots), LAYER burned directly, weth burns in and out
    function run(bool doBurn, uint256 minLayerOutPerWeth, bool unwrap)
        external
        returns (uint256 lCol, uint256 wCol, uint256 lBurn, uint256 wBurn, uint256 lBought)
    {
        uint256 l0 = IERC20(layer).balanceOf(address(feeLocker));
        uint256 w0 = IERC20(weth).balanceOf(address(feeLocker));
        _step(1, COLLECT_GAS, address(locker), abi.encodeCall(locker.collectRewards, (layer)));
        lCol = IERC20(layer).balanceOf(address(feeLocker)) - l0;
        wCol = IERC20(weth).balanceOf(address(feeLocker)) - w0;
        address[2] memory tokens = [layer, weth]; // controller first, its burn share lands at router0
        for (uint256 i; i < 4; ++i) {
            (address s, address t) = (i < 2 ? controller : router0, tokens[i % 2]);
            bytes memory c = abi.encodeCall(IArtCoinsFeeLocker.claim, (s, t));
            if (feeLocker.availableFees(s, t) > 0) _step(2, CLAIM_GAS, address(feeLocker), c);
        }
        for (uint256 i; i < 2; ++i) {
            bytes memory c = abi.encodeCall(ILayerFeeController.processFees, (tokens[i]));
            if (IERC20(tokens[i]).balanceOf(controller) > 0) _step(3, FEES_GAS, controller, c);
        }
        address[3] memory routers = [router0, router1, router2];
        for (uint256 i; i < 3; ++i) {
            address r = routers[i];
            bytes memory c = abi.encodeCall(ILayerBurnRouter.processBurnLayer, ());
            if (IERC20(layer).balanceOf(r) > 0) {
                (bool ok, bytes memory ret) = _step(4, BURN_LAYER_GAS, r, c);
                if (ok) lBurn += abi.decode(ret, (uint256));
            }
            uint256 bal = IERC20(weth).balanceOf(r) + r.balance;
            if (!doBurn || bal == 0 || bal < ILayerBurnRouter(r).minProcessThreshold()) continue;
            uint256 minOut = FullMath.mulDiv(bal, minLayerOutPerWeth, 1e18);
            // owner floor 0 reverts `SlippageFloorNotSet` in the router. no floor getter (0x0EB2): pass 0, its
            // 1% impact clamp and spot floor on the consumed amount apply (a partial fill would trip a minimum)
            try ILayerBurnRouter(r).minLayerOutPerWeth() returns (uint256 f) {
                uint256 need = FullMath.mulDiv(bal, f, 1e18);
                if (need > minOut) minOut = need;
            } catch {
                minOut = 0;
            }
            c = abi.encodeCall(ILayerBurnRouter.processBurnWeth, (minOut));
            (bool ok2, bytes memory ret2) = _step(5, BURN_WETH_GAS, r, c);
            if (ok2) {
                (uint256 wIn, uint256 lOut) = abi.decode(ret2, (uint256, uint256));
                (wBurn, lBought) = (wBurn + wIn, lBought + lOut);
            }
        }
        _forward(unwrap);
        emit KeeperRun(msg.sender, [lCol, wCol, lBurn, wBurn, lBought]);
    }

    /// @dev D49: starts only above `floor` plus margin, then gets all remaining gas. A revert that leaves gas
    ///      under that reverts `InsufficientGas`, else collect (step 1) bubbles and the rest are reported.
    function _step(uint8 step, uint256 floor, address target, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        uint256 g = floor + MARGIN;
        if (gasleft() < g + g / 63 + 20_000) revert InsufficientGas(step);
        (ok, ret) = target.call(data);
        if (ok) return (ok, ret);
        if (gasleft() < g) revert InsufficientGas(step);
        if (step == 1) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        emit StepSkipped(step, target, ret);
    }

    /// @dev router rewards arrive as eth, dust as anything: all of it leaves now
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

    /// @notice `uncollected*`: lp fees owed to the positions. `claimable`: [controller LAYER, controller weth,
    ///         router0 LAYER, router0 weth]. `routerWeth`: weth plus eth per router vs `minProcessThreshold`.
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
        PoolId pid = PoolIdLibrary.toId(info.poolKey);
        uint256[2] memory f;
        for (uint256 i; i < info.numPositions; ++i) {
            PositionInfo p = pm.positionInfo(info.positionId + i);
            (uint256 g0, uint256 g1) = PM.getFeeGrowthInside(pid, p.tickLower(), p.tickUpper());
            (uint128 liq, uint256 a0, uint256 a1) = PM.getPositionInfo(
                pid, address(pm), p.tickLower(), p.tickUpper(), bytes32(info.positionId + i)
            );
            unchecked {
                f[0] += FullMath.mulDiv(g0 - a0, liq, FixedPoint128.Q128);
                f[1] += FullMath.mulDiv(g1 - a1, liq, FixedPoint128.Q128);
            }
        }
        // v4 sorts currencies by address
        (uncollectedLayer, uncollectedWeth) = layer < weth ? (f[0], f[1]) : (f[1], f[0]);
        for (uint256 i; i < 4; ++i) {
            claimable[i] =
                feeLocker.availableFees(i < 2 ? controller : router0, i % 2 == 0 ? layer : weth);
        }
        address[3] memory rs = [router0, router1, router2];
        for (uint256 i; i < 3; ++i) {
            routerWeth[i] = IERC20(weth).balanceOf(rs[i]) + rs[i].balance;
            routerThreshold[i] = ILayerBurnRouter(rs[i]).minProcessThreshold();
        }
    }
}
