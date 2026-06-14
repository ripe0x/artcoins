// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  RedeployBurnRouter
/// @notice Deploys a new BurnRouter (fixed price-impact sandwich cap, no EMA
///         gate), initializes it against the LAYER pool, and rewires the
///         factory's `teamFeeRecipient` to it.
///
///         Required env (same as `DeployNativeEthStack.s.sol`):
///           PRIVATE_KEY, POOL_MANAGER, PERMIT2, WETH, UNIVERSAL_ROUTER,
///           LAYER_TOKEN, LAYER_POOL_C0, LAYER_POOL_C1, LAYER_POOL_FEE,
///           LAYER_POOL_TICK_SPACING, LAYER_POOL_HOOK
///         Plus:
///           FACTORY                 Existing artcoins V3 factory address
///                                   (so `setTeamFeeRecipient` can be called)
///
/// @dev The previous BurnRouter is left orphaned on-chain (the factory's
///      `teamFeeRecipient` is the only place that referenced it; once
///      rewired, fees stop flowing to it permanently). No need to
///      decommission — it simply stops receiving WETH.
///
/// @dev SCOPE: this rewires the FACTORY's `teamFeeRecipient` (the artcoins /
///      LAYER-side burn router). It does NOT touch any `ProtocolFeeController`.
///      For a controller-fed burn router — e.g. a PERMANENT COLLECTION launch,
///      whose `ProtocolFeeController.burnRouter()` is the 13.33% recipient —
///      do NOT run this script: its `setTeamFeeRecipient` would re-point the
///      wrong slot. Instead deploy + `initialize()` a fresh BurnRouter, then
///      call `controller.setBurnRouter(newRouter)` from the controller owner.
contract RedeployBurnRouter is Script {
    function run() public returns (address newBurnRouter) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address poolManager = vm.envAddress("POOL_MANAGER");
        address weth = vm.envAddress("WETH");
        address layerToken = vm.envAddress("LAYER_TOKEN");
        address factoryAddr = vm.envAddress("FACTORY");

        PoolKey memory layerPoolKey = PoolKey({
            currency0: Currency.wrap(vm.envAddress("LAYER_POOL_C0")),
            currency1: Currency.wrap(vm.envAddress("LAYER_POOL_C1")),
            fee: uint24(vm.envUint("LAYER_POOL_FEE")),
            tickSpacing: int24(int256(vm.envInt("LAYER_POOL_TICK_SPACING"))),
            hooks: IHooks(vm.envAddress("LAYER_POOL_HOOK"))
        });

        ArtCoinsFactory factory = ArtCoinsFactory(payable(factoryAddr));
        address oldBurnRouter = factory.teamFeeRecipient();

        console2.log("Deployer:                ", deployer);
        console2.log("Factory:                 ", factoryAddr);
        console2.log("Old BurnRouter:          ", oldBurnRouter);
        console2.log("");

        vm.startBroadcast(pk);

        // 1. Deploy new BurnRouter (fixed price-impact cap, no EMA gate).
        BurnRouter burnRouter = new BurnRouter(deployer);
        newBurnRouter = address(burnRouter);
        console2.log("New BurnRouter:          ", newBurnRouter);

        // 2. Initialize against the LAYER pool. Sandwich protection is the
        //    hardcoded `MAX_SWAP_IMPACT_BPS` cap — no EMA, no tuning knob.
        burnRouter.initialize(layerToken, weth, layerPoolKey, poolManager);

        // 3. Rewire factory's team-fee recipient to the new BurnRouter.
        //    From now on the factory's protocol-fee slot points here for
        //    every new artcoin deploy. Existing artcoins (none yet under
        //    V3) keep their own recipient registration.
        factory.setTeamFeeRecipient(newBurnRouter);

        vm.stopBroadcast();

        console2.log("");
        console2.log("Wiring summary:");
        console2.log("  factory.teamFeeRecipient now =", factory.teamFeeRecipient());
        console2.log("  burnRouter.MAX_SWAP_IMPACT_BPS =", burnRouter.MAX_SWAP_IMPACT_BPS());
        console2.log("");
        console2.log("Old BurnRouter at", oldBurnRouter);
        console2.log("  is now orphaned - no fee path points to it anymore.");
        console2.log("  It retains any prior balance; sweepable via owner");
        console2.log("  (still you) if/when desired.");
    }
}
