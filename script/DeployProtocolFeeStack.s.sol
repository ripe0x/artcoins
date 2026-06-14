// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";
import {LiquiditySupportReceiver} from "../src/protocol-fee/LiquiditySupportReceiver.sol";
import {ProtocolFeeController} from "../src/protocol-fee/ProtocolFeeController.sol";

/// @title DeployProtocolFeeStack
/// @notice Deploys the ProtocolFeeController + BurnRouter, and OPTIONALLY
///         the LiquiditySupportReceiver. The LAYER mainnet launch does NOT
///         use LiquiditySupportReceiver (its bps is 0), but future artcoins
///         that route project-side fees to a liquidity-support sink can.
///
/// Required env vars:
///   PRIVATE_KEY        Deployer private key.
///   FEE_ADMIN          Multisig that will own all three contracts.
///   PROTOCOL_TREASURY  artcoins protocol treasury.
///   WETH               WETH address on this chain.
///
/// Optional env vars:
///   LAYER_TOKEN              LAYER ERC20 address (default 0x0 = deploy
///                            before LAYER; initialize later with
///                            PrepareLayerLaunch).
///   DEPLOY_LIQUIDITY_SUPPORT True/false. Default false. When true, requires
///                            LAYER_TOKEN to be set.
contract DeployProtocolFeeStack is Script {
    /// @dev LAYER's protocol-fee split: 60% treasury / 40% burn. Fixed at
    ///      construction (the controller's split is immutable). The burn share
    ///      is the remainder, `BPS - LAYER_TREASURY_BPS = 4000`.
    uint16 internal constant LAYER_TREASURY_BPS = 6000;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.envAddress("FEE_ADMIN");
        address treasury = vm.envAddress("PROTOCOL_TREASURY");
        address layer = vm.envOr("LAYER_TOKEN", address(0));
        address weth = vm.envAddress("WETH");
        bool deployLiqSupport = vm.envOr("DEPLOY_LIQUIDITY_SUPPORT", false);

        console2.log("=== Deploy ProtocolFeeStack ===");
        console2.log("Admin:                ", admin);
        console2.log("Treasury:             ", treasury);
        console2.log("LAYER:                ", layer);
        console2.log("WETH:                 ", weth);
        console2.log("Deploy LiqSupport:    ", deployLiqSupport);

        vm.startBroadcast(pk);

        // 1. BurnRouter (admin-owned, initialized later if LAYER unknown)
        BurnRouter router = new BurnRouter(admin);
        console2.log("BurnRouter deployed:                  ", address(router));

        // 2. LiquiditySupportReceiver (optional; LAYER doesn't use it).
        LiquiditySupportReceiver liqSupport;
        if (deployLiqSupport) {
            require(layer != address(0), "LAYER_TOKEN required when DEPLOY_LIQUIDITY_SUPPORT=true");
            liqSupport = new LiquiditySupportReceiver(admin, layer, weth);
            console2.log("LiquiditySupportReceiver deployed:    ", address(liqSupport));
        } else {
            console2.log("LiquiditySupportReceiver: SKIPPED (not used by LAYER launch)");
        }

        // 3. ProtocolFeeController (controller wired to router; 60/40 split)
        ProtocolFeeController controller =
            new ProtocolFeeController(admin, treasury, address(router), LAYER_TREASURY_BPS);
        console2.log("ProtocolFeeController deployed:       ", address(controller));
        console2.log("Split: 60 / 40  (treasury / burn)");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Next steps ===");
        if (layer == address(0)) {
            console2.log("1. Bind factory teamFeeRecipient = ProtocolFeeController");
            console2.log("2. Pre-initialize BurnRouter with PrepareLayerLaunch");
            console2.log("3. Deploy LAYER via LaunchLayer (factory.deployToken)");
        } else {
            console2.log("1. Initialize BurnRouter with LAYER + canonical pool key");
        }
        console2.log("4. Confirm factory defaultProtocolFeeBps = 2000 (20%)");
        console2.log("");
        console2.log("Final report:");
        console2.log("  ProtocolFeeController:    ", address(controller));
        console2.log("  BurnRouter:               ", address(router));
        if (deployLiqSupport) {
            console2.log("  LiquiditySupportReceiver: ", address(liqSupport));
        }
    }
}
