// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";

import {LaunchLayer} from "./LaunchLayer.s.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title PrepareLayerLaunch
/// @notice Pre-initializes BurnRouter for the predicted LAYER token/pool so
///         the scheduled `LaunchLayer` broadcast can skip router setup and go
///         straight to `factory.deployToken`.
/// @dev Must be run with the same PRIVATE_KEY, FACTORY, and HOOK that will be
///      used for `LaunchLayer.s.sol`, because the predicted token address is
///      derived from the deployer/token admin.
contract PrepareLayerLaunch is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address factory = vm.envAddress("FACTORY");
        address hook = vm.envAddress("HOOK");
        address renderer = vm.envAddress("LL_RENDERER");
        address burnRouter = vm.envAddress("BURN_ROUTER");

        LaunchLayer launchScript = new LaunchLayer();
        (address predictedLayer, PoolKey memory predictedPoolKey) =
            launchScript.predictLaunch(deployer, factory, hook, renderer);

        BurnRouter router = BurnRouter(payable(burnRouter));

        console2.log("=== Prepare LAYER Launch ===");
        console2.log("Deployer/token admin:", deployer);
        console2.log("Factory:             ", factory);
        console2.log("Hook:                ", hook);
        console2.log("LL renderer:         ", renderer);
        console2.log("BurnRouter:          ", burnRouter);
        console2.log("Predicted LAYER:     ", predictedLayer);
        _printPoolKey(predictedPoolKey);

        if (router.initialized()) {
            _verifyInitialized(router, predictedLayer, predictedPoolKey);
            console2.log("BurnRouter already initialized for predicted LAYER/pool.");
            return;
        }

        require(router.owner() == deployer, "signer must own uninitialized BurnRouter");

        address weth = _weth();

        vm.startBroadcast(pk);
        // Sandwich protection is the hardcoded impact cap — no EMA gate, no knob.
        router.initialize(
            predictedLayer, weth, predictedPoolKey, 0x000000000004444c5dc75cB358380D2e3dE08A90
        );
        vm.stopBroadcast();

        _verifyInitialized(router, predictedLayer, predictedPoolKey);
        console2.log("BurnRouter initialized for predicted LAYER/pool.");
    }

    function _verifyInitialized(
        BurnRouter router,
        address predictedLayer,
        PoolKey memory predictedPoolKey
    ) internal view {
        require(router.initialized(), "BurnRouter not initialized");
        require(router.layerToken() == predictedLayer, "BurnRouter LAYER mismatch");
        require(router.weth() == _weth(), "BurnRouter WETH mismatch");
        require(_samePoolKey(_routerPoolKey(router), predictedPoolKey), "BurnRouter pool mismatch");
    }

    function _routerPoolKey(BurnRouter router) internal view returns (PoolKey memory key) {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            router.canonicalPoolKey();
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    function _samePoolKey(PoolKey memory a, PoolKey memory b) internal pure returns (bool) {
        return Currency.unwrap(a.currency0) == Currency.unwrap(b.currency0)
            && Currency.unwrap(a.currency1) == Currency.unwrap(b.currency1) && a.fee == b.fee
            && a.tickSpacing == b.tickSpacing && address(a.hooks) == address(b.hooks);
    }

    function _printPoolKey(PoolKey memory key) internal pure {
        console2.log("Pool currency0:      ", Currency.unwrap(key.currency0));
        console2.log("Pool currency1:      ", Currency.unwrap(key.currency1));
        console2.log("Pool fee:            ", uint256(key.fee));
        console2.log("Pool tickSpacing:    ", int256(key.tickSpacing));
        console2.log("Pool hook:           ", address(key.hooks));
    }

    function _weth() internal view returns (address) {
        if (block.chainid == 1) return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        if (block.chainid == 11_155_111) return 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        revert("unsupported chain");
    }

    function _universalRouter() internal view returns (address) {
        if (block.chainid == 1) return 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
        if (block.chainid == 11_155_111) return 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
        revert("unsupported chain");
    }
}
