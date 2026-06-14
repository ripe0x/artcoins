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

/// @title  LiveSwapVerify
/// @notice Make 3 small live swaps on the LAYER pool to verify the new
///         auto-forward extension records each one. Total notional capped
///         at 0.006 ETH (3 × 0.002 ETH buys).
///
/// Run:
///   forge script script/LiveSwapVerify.s.sol \
///     --rpc-url $MAINNET_RPC_URL --broadcast --private-key $PRIVATE_KEY -vv
contract LiveSwapVerify is Script {
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
        console2.log("Counter at start:", b0, "buys,", s0);
        console2.log("(sells)", s0);

        vm.startBroadcast();

        // Wrap 0.006 ETH and approve a fresh swap router.
        IWETH9(payable(WETH)).deposit{value: 0.006 ether}();
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false, // WETH (currency1) → LAYER (currency0)
            amountSpecified: -0.002 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory ts =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Swap 1
        swapRouter.swap(pk, params, ts, "");

        // Swap 2
        swapRouter.swap(pk, params, ts, "");

        // Swap 3
        swapRouter.swap(pk, params, ts, "");

        vm.stopBroadcast();

        (uint128 b1, uint128 s1) = IExt(EXT).counts(pid);
        console2.log("Counter at end:  ", b1, "buys,", s1);
        console2.log("(sells)", s1);
        console2.log("Buys delta:       ", uint256(b1 - b0));
        console2.log("Sells delta:      ", uint256(s1 - s0));
        require(b1 - b0 == 3, "expected 3 buys recorded");
    }
}
