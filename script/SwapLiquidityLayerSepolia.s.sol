// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IWETH9 {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

contract SwapLiquidityLayerSepolia is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant TOKEN = 0x863EFB0261Dc4CA5Ed94AAe241D89257300959C3;
    address internal constant COUNTER = 0xfbd3F3Bc59a41E3052F603F202AEa0Af50Cc0857;
    address internal constant HOOK = 0x6574548504Fe24616E5578f6D9f2D0363f9DE8CC;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant FEE_DYNAMIC = 0x800000;
    uint256 internal constant DEFAULT_BUY_AMOUNT = 0.001 ether;

    error PoolIdMismatch(bytes32 expected, bytes32 actual);

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 buyAmount = vm.envOr("BUY_AMOUNT_WEI", DEFAULT_BUY_AMOUNT);
        address buyer = vm.addr(pk);

        LiquidityLayerCounterPoolExtension counter = LiquidityLayerCounterPoolExtension(COUNTER);
        PoolKey memory key = _buildKey(TOKEN, WETH, HOOK);

        PoolId registered = counter.poolForToken(TOKEN);
        PoolId computed = key.toId();
        if (PoolId.unwrap(registered) != PoolId.unwrap(computed)) {
            revert PoolIdMismatch(PoolId.unwrap(registered), PoolId.unwrap(computed));
        }

        (uint128 buysBefore, uint128 sellsBefore) = counter.countsForToken(TOKEN);

        console2.log("=== Sepolia Liquidity Layer swap ===");
        console2.log("Buyer:          ", buyer);
        console2.log("Token:          ", TOKEN);
        console2.logBytes32(PoolId.unwrap(computed));
        console2.log("Buy amount WETH:", buyAmount);
        console2.log("Buys before:    ", buysBefore);
        console2.log("Sells before:   ", sellsBefore);

        vm.startBroadcast(pk);

        PoolSwapTest swapTest = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        IWETH9(WETH).deposit{value: buyAmount}();
        IWETH9(WETH).approve(address(swapTest), buyAmount);

        bool zeroForOne = Currency.unwrap(key.currency0) == WETH;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(buyAmount),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapTest.swap(key, params, settings, "");

        vm.stopBroadcast();

        (uint128 buysAfter, uint128 sellsAfter) = counter.countsForToken(TOKEN);
        console2.log("Buys after:     ", buysAfter);
        console2.log("Sells after:    ", sellsAfter);
    }

    function _buildKey(address token, address weth, address hook)
        internal
        pure
        returns (PoolKey memory)
    {
        (address c0, address c1) = token < weth ? (token, weth) : (weth, token);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE_DYNAMIC,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }
}
