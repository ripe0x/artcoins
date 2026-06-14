// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

interface IExt {
    function counts(PoolId) external view returns (uint128 buys, uint128 sells);
}

/// @title  LiveNoOpVerify
/// @notice One tiny buy when all stages are below threshold. Expect counter
///         to advance but ZERO PipelineStageFired events.
contract LiveNoOpVerify is Script {
    using PoolIdLibrary for PoolKey;

    address constant LAYER = 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant HOOK = 0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant EXT = 0x38d03af54ba9F80c3476B3D3B3a6415A399303f7;

    function run() external {
        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(LAYER),
            currency1: Currency.wrap(WETH),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(HOOK)
        });
        PoolId pid = pk.toId();

        (uint128 b0, uint128 s0) = IExt(EXT).counts(pid);
        console2.log("Counter at start: buys=", b0, " sells=", s0);

        vm.startBroadcast();
        IWETH9(payable(WETH)).deposit{value: 0.0005 ether}();
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.0005 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory ts =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(pk, params, ts, "");
        vm.stopBroadcast();

        (uint128 b1, uint128 s1) = IExt(EXT).counts(pid);
        console2.log("Counter at end:   buys=", b1, " sells=", s1);
        require(b1 == b0 + 1, "expected 1 buy");
    }
}
