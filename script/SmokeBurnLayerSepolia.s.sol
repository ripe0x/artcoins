// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {ArtCoinsLpLockerMultiple} from "../src/lp-lockers/legacy/ArtCoinsLpLockerMultiple.sol";
import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IWETH9 {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Demonstrates two paths the prior smoke test couldn't reach:
///         (1) cross-coin gap — sell ARTTEST → ARTTEST-side fee accumulates in
///             BurnRouter as held tokens (no automatic conversion path);
///         (2) direct LAYER burn — buy LAYER, transfer some to BurnRouter,
///             call processBurnLayer, observe totalSupply drop.
///
/// Required env vars:
///   PRIVATE_KEY, HOOK, LOCKER, BURN_ROUTER, LAYER_TOKEN, ARTTEST_TOKEN,
///   POOL_SWAP_TEST (the helper deployed by SmokeTestArtTestSepolia)
contract SmokeBurnLayerSepolia is Script {
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    int24 constant TICK_SPACING = 200;
    uint24 constant FEE_DYNAMIC = 0x800000;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address hook = vm.envAddress("HOOK");
        address lockerAddr = vm.envAddress("LOCKER");
        address burnRouter = vm.envAddress("BURN_ROUTER");
        address layer = vm.envAddress("LAYER_TOKEN");
        address arttest = vm.envAddress("ARTTEST_TOKEN");
        address poolSwapTest = vm.envAddress("POOL_SWAP_TEST");

        ArtCoinsToken layerTok = ArtCoinsToken(layer);
        ArtCoinsToken artTok = ArtCoinsToken(arttest);

        console2.log("=== Sepolia: cross-coin gap + direct LAYER burn ===");

        uint256 supplyStart = layerTok.totalSupply();
        console2.log("LAYER totalSupply (start): ", supplyStart);
        console2.log("BurnRouter ARTTEST held (start): ", artTok.balanceOf(burnRouter));
        console2.log("BurnRouter LAYER held (start):   ", layerTok.balanceOf(burnRouter));

        vm.startBroadcast(pk);

        // ─── (1) Sell part of held ARTTEST to demonstrate the cross-coin gap ───
        uint256 artBal = artTok.balanceOf(me);
        uint256 sellAmount = artBal / 4; // sell 25% of what we hold
        artTok.approve(poolSwapTest, sellAmount);

        PoolKey memory artKey = _buildKey(arttest, SEPOLIA_WETH, hook);
        bool zeroForOneSell = Currency.unwrap(artKey.currency0) == arttest;
        IPoolManager.SwapParams memory sellParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOneSell,
            amountSpecified: -int256(sellAmount),
            sqrtPriceLimitX96: zeroForOneSell
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest(poolSwapTest)
            .swap(
                artKey,
                sellParams,
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        console2.log("Sold %s ARTTEST", sellAmount);

        // Push fees through locker — ARTTEST-side fee goes to BurnRouter (project-burn)
        // and PFC, both of which now hold ARTTEST with no automatic LAYER conversion.
        ArtCoinsLpLockerMultiple(lockerAddr).collectRewards(arttest);
        console2.log("Locker.collectRewards(ARTTEST) done.");

        // ─── (2) Buy a tiny amount of LAYER, then burn some directly ─────────
        uint256 buyEth = 0.005 ether;
        IWETH9(SEPOLIA_WETH).deposit{value: buyEth}();
        IWETH9(SEPOLIA_WETH).approve(poolSwapTest, buyEth);

        PoolKey memory layerKey = _buildKey(layer, SEPOLIA_WETH, hook);
        bool zeroForOneBuy = Currency.unwrap(layerKey.currency0) == SEPOLIA_WETH;
        IPoolManager.SwapParams memory buyParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOneBuy,
            amountSpecified: -int256(buyEth),
            sqrtPriceLimitX96: zeroForOneBuy
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest(poolSwapTest)
            .swap(
                layerKey,
                buyParams,
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        uint256 layerBalBuyer = layerTok.balanceOf(me);
        console2.log("Bought LAYER:                       ", layerBalBuyer);

        // Transfer half of bought LAYER to BurnRouter and burn.
        uint256 toBurn = layerBalBuyer / 2;
        layerTok.transfer(burnRouter, toBurn);
        console2.log("Sent to BurnRouter for burn:        ", toBurn);

        uint256 burned = BurnRouter(payable(burnRouter)).processBurnLayer();
        console2.log("BurnRouter.processBurnLayer burned: ", burned);

        vm.stopBroadcast();

        uint256 supplyEnd = layerTok.totalSupply();
        console2.log("");
        console2.log("=== Final state ===");
        console2.log("LAYER totalSupply (end):    ", supplyEnd);
        console2.log("LAYER burned this run:      ", supplyStart - supplyEnd);
        console2.log("BurnRouter ARTTEST held (end): ", artTok.balanceOf(burnRouter));
        console2.log("BurnRouter LAYER held (end):   ", layerTok.balanceOf(burnRouter));
    }

    function _buildKey(address coin, address weth, address hook)
        internal
        pure
        returns (PoolKey memory)
    {
        (address c0, address c1) = coin < weth ? (coin, weth) : (weth, coin);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE_DYNAMIC,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }
}
