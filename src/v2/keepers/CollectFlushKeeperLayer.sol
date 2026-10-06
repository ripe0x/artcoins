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

/// @dev the three live LAYER burn routers share these names (legacy and open source); `minLayerOutPerWeth`
///      is absent on the current stack router, which enforces its own spot floor instead.
interface ILayerBurnRouter {
    function processBurnLayer() external returns (uint256);
    function processBurnWeth(uint256 minLayerOut) external returns (uint256, uint256);
    function minProcessThreshold() external view returns (uint256);
    function minLayerOutPerWeth() external view returns (uint256);
}

interface ILayerFeeController {
    function processFees(address token) external;
}

interface ILegacyLockerPm {
    function positionManager() external view returns (IPositionManager);
}

/// @title  CollectFlushKeeperLayer
/// @notice Stateless keeper pinned to the live LAYER fee path on the legacy stack. `run` collects the LAYER lp
///         fees into the fee locker, pushes the burn router and controller slots out of the fee locker, splits
///         the controller balance, burns LAYER and (optionally) weth at the burn routers, and forwards whatever
///         the keeper received to the caller. No owner, holds nothing between calls.
/// @dev    D49 gas pattern: each step needs `gasleft()` above its floor before it starts and then gets all
///         remaining gas. A collect revert bubbles; any other step's revert is reported via `StepSkipped` and
///         the run continues; a revert that leaves gas under the step's floor reverts `InsufficientGas(step)`.
///         The owner slot (an eoa) is never claimed: claim pays only the fee owner, it is the owner's call.
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
    /// @dev locker reward recipient and fee locker slot; sends 40% of what it holds to `routers[0]`
    address public immutable controller;
    /// @dev routers[0] is the locker recipient and controller burn router; the other two are optional extras
    ///      bound to the same pool (zero address disables a slot)
    address public immutable router0;
    address public immutable router1;
    address public immutable router2;

    /// @dev floors measured on a mainnet fork (see docs/v2/review/keeper-111.md, LAYER keeper), not caps.
    ///      Every swap on the LAYER pool runs the hook's own lp collect, so a weth burn costs a collect too.
    uint256 internal constant COLLECT_GAS = 640_000;
    uint256 internal constant CLAIM_GAS = 60_000;
    uint256 internal constant FEES_GAS = 80_000;
    uint256 internal constant BURN_LAYER_GAS = 60_000;
    uint256 internal constant BURN_WETH_GAS = 900_000;
    uint256 internal constant MARGIN = 50_000;

    event KeeperRun(
        address indexed caller,
        uint256 layerCollected,
        uint256 wethCollected,
        uint256 layerBurned,
        uint256 wethBurned,
        uint256 layerBought
    );
    /// @dev step 2 claim, 3 processFees, 4 processBurnLayer, 5 processBurnWeth. `reason` is the revert data
    ///      (`BelowMinThreshold`, `MinLayerOutBelowFloor`, `V4TooLittleReceived`, ...) or "floor 0".
    event StepSkipped(uint8 indexed step, address indexed target, bytes reason);

    /// @dev gas shortfall for `step` (1 collect .. 5 burn weth). Reverts rather than skips so an estimateGas
    ///      search cannot land on a path that silently drops a step.
    error InsufficientGas(uint8 step);
    error EthTransferFailed();

    constructor(
        address locker_,
        address layer_,
        address weth_,
        address feeLocker_,
        address controller_,
        address[3] memory routers_
    ) {
        locker = IArtCoinsLpLocker(locker_);
        layer = layer_;
        weth = weth_;
        feeLocker = IArtCoinsFeeLocker(feeLocker_);
        controller = controller_;
        (router0, router1, router2) = (routers_[0], routers_[1], routers_[2]);
    }

    receive() external payable {}

    /// @param doBurn also run `processBurnWeth` on every router at or above its threshold
    /// @param minLayerOutPerWeth caller's floor, LAYER out per 1e18 weth in (the routers' own unit). The keeper
    ///        passes `max(this, router owner floor) * balance / 1e18`; 0 means "the router's own floor"
    /// @param unwrap send weth the keeper received as eth
    /// @dev returns the fees the collect credited to the fee locker (all three slots), LAYER burned directly by
    ///      `processBurnLayer`, and weth in / LAYER out of the weth burns
    function run(bool doBurn, uint256 minLayerOutPerWeth, bool unwrap)
        external
        returns (
            uint256 layerCollected,
            uint256 wethCollected,
            uint256 layerBurned,
            uint256 wethBurned,
            uint256 layerBought
        )
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
        layerCollected = IERC20(layer).balanceOf(address(feeLocker)) - l0;
        wethCollected = IERC20(weth).balanceOf(address(feeLocker)) - w0;

        address[2] memory tokens = [layer, weth];
        address[2] memory slots = [controller, router0];
        for (uint256 i; i < 4; ++i) {
            (address slot, address token) = (slots[i / 2], tokens[i % 2]);
            if (feeLocker.availableFees(slot, token) > 0) {
                _step(2, CLAIM_GAS, address(feeLocker), abi.encodeCall(IArtCoinsFeeLocker.claim, (slot, token)));
            }
        }
        for (uint256 i; i < 2; ++i) {
            if (IERC20(tokens[i]).balanceOf(controller) > 0) {
                _step(3, FEES_GAS, controller, abi.encodeCall(ILayerFeeController.processFees, (tokens[i])));
            }
        }
        address[3] memory routers = [router0, router1, router2];
        for (uint256 i; i < 3; ++i) {
            address r = routers[i];
            if (r == address(0)) continue;
            if (IERC20(layer).balanceOf(r) > 0) {
                (bool ok, bytes memory ret) =
                    _step(4, BURN_LAYER_GAS, r, abi.encodeCall(ILayerBurnRouter.processBurnLayer, ()));
                if (ok) layerBurned += abi.decode(ret, (uint256));
            }
            uint256 bal = IERC20(weth).balanceOf(r) + r.balance;
            if (!doBurn || bal == 0 || bal < ILayerBurnRouter(r).minProcessThreshold()) continue;
            uint256 minOut = Math.mulDiv(bal, minLayerOutPerWeth, 1e18);
            try ILayerBurnRouter(r).minLayerOutPerWeth() returns (uint256 floor) {
                if (floor == 0) {
                    emit StepSkipped(5, r, "floor 0");
                    continue;
                }
                minOut = Math.max(minOut, Math.mulDiv(bal, floor, 1e18));
            } catch {} // current stack router: no owner floor, it enforces its spot floor itself
            (bool ok2, bytes memory ret2) =
                _step(5, BURN_WETH_GAS, r, abi.encodeCall(ILayerBurnRouter.processBurnWeth, (minOut)));
            if (ok2) {
                (uint256 wIn, uint256 lOut) = abi.decode(ret2, (uint256, uint256));
                wethBurned += wIn;
                layerBought += lOut;
            }
        }
        _forward(unwrap);
        emit KeeperRun(msg.sender, layerCollected, wethCollected, layerBurned, wethBurned, layerBought);
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

    /// @notice Runner view. `uncollected*`: gross lp fees owed to the locker positions (both currencies).
    ///         `claimable`: fee locker slots the keeper pushes [controller LAYER, controller weth, router0 LAYER,
    ///         router0 weth]. `routerWeth`: weth plus eth per router (what `processBurnWeth` swaps) next to
    ///         `routerThreshold` (its `minProcessThreshold`).
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
        IPositionManager pm = ILegacyLockerPm(address(locker)).positionManager();
        PoolId pid = info.poolKey.toId();
        (uint256 f0, uint256 f1) = (0, 0);
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
        bool layerIs0 = Currency.unwrap(info.poolKey.currency0) == layer;
        (uncollectedLayer, uncollectedWeth) = layerIs0 ? (f0, f1) : (f1, f0);
        claimable = [
            feeLocker.availableFees(controller, layer),
            feeLocker.availableFees(controller, weth),
            feeLocker.availableFees(router0, layer),
            feeLocker.availableFees(router0, weth)
        ];
        address[3] memory routers = [router0, router1, router2];
        for (uint256 i; i < 3; ++i) {
            if (routers[i] == address(0)) continue;
            routerWeth[i] = IERC20(weth).balanceOf(routers[i]) + routers[i].balance;
            routerThreshold[i] = ILayerBurnRouter(routers[i]).minProcessThreshold();
        }
    }
}
