// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IBurnRouter} from "../src/protocol-fee/IBurnRouter.sol";
import {ProtocolFeeController} from "../src/protocol-fee/ProtocolFeeController.sol";

/// @title  DeployPCController
/// @notice Deploys a permanent-collection-dedicated `ProtocolFeeController`.
///         Reuses the EXISTING LAYER `BurnRouter` (this controller does not
///         own the router — it just forwards the burn share into it). Fixes
///         the PC-specific split to 80% PC-treasury / 20% LAYER-burn at
///         construction.
///
///         Why a NEW controller (not reuse LAYER's `0x5fdc…0a60`): the
///         controller's split and treasury are immutable and global to the
///         instance. PC needs an 80/20 split with PC's treasury as the
///         recipient, while the LAYER controller keeps its 60/40 split with
///         the artcoins protocol treasury. A separate instance is the only
///         way to give each protocol independent routing without affecting
///         the other.
///
///         Why deployer == owner: PC's single-EOA admin design (HANDOFF.md
///         "Admin custody — RESOLVED 2026-05-21") keeps every admin role
///         on `0xCB43…17F9`. The split is fixed at construction, so the owner
///         is needed only for the post-deploy recipient-rotation surface
///         (`setTreasury`, `setBurnRouter`).
///
/// Required env vars:
///   PRIVATE_KEY        Deployer key. Becomes the controller's owner.
///                      Per PC's single-EOA design this should equal
///                      `PC_TREASURY` and `EXPECTED_OWNER` (= 0xCB43…17F9).
///   PC_TREASURY        Recipient of the 80% slice — the "creator fee" in
///                      PC's public-facing copy. Per HANDOFF.md and
///                      LAUNCH_PARAMS.md: 0xCB43078C32423F5348Cab5885911C3B5faE217F9.
///   LAYER_BURN_ROUTER  Address of the already-deployed, initialized LAYER
///                      `BurnRouter`. Receives the 20% slice as native ETH;
///                      its `receive()` accepts ETH and wraps to WETH on the
///                      next `processBurnWeth*` cycle. Mainnet:
///                      0x2edbdf011768d8cd4ef537658b41440900c52000.
///
/// Optional env vars:
///   EXPECTED_OWNER     If set, asserts `vm.addr(PRIVATE_KEY) == EXPECTED_OWNER`.
///                      Recommended belt-and-braces check that the operator
///                      is signing with the intended key.
///
/// Output:
///   The deployed address is logged for the operator to set as PC's
///   `PC_CONTROLLER` env var before running `permanent-collection`'s
///   `contracts/script/Deploy.s.sol`.
contract DeployPCController is Script {
    uint16 internal constant PC_TREASURY_BPS = 8667; // 86.67%
    uint16 internal constant PC_BURN_BPS = 1333; // 13.33% (clears MIN_BURN_BPS = 1000), derived

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address treasury = vm.envAddress("PC_TREASURY");
        address burnRouter = vm.envAddress("LAYER_BURN_ROUTER");
        address expectedOwner = vm.envOr("EXPECTED_OWNER", address(0));

        if (expectedOwner != address(0)) {
            require(deployer == expectedOwner, "DeployPCController: deployer != EXPECTED_OWNER");
        }

        require(treasury != address(0), "DeployPCController: PC_TREASURY zero");
        require(burnRouter != address(0), "DeployPCController: LAYER_BURN_ROUTER zero");
        require(burnRouter.code.length > 0, "DeployPCController: LAYER_BURN_ROUTER has no code");
        address routerLayer = IBurnRouter(burnRouter).layerToken();
        require(routerLayer != address(0), "DeployPCController: LAYER_BURN_ROUTER not initialized");

        console2.log("=== Deploy PC ProtocolFeeController ===");
        console2.log("Deployer / owner:           ", deployer);
        console2.log("PC treasury (80%):          ", treasury);
        console2.log("LAYER BurnRouter (20%):     ", burnRouter);
        console2.log("BurnRouter LAYER token:     ", routerLayer);
        console2.log("Split: 80 / 20  (PC treasury / LAYER burn)");

        vm.startBroadcast(pk);

        ProtocolFeeController controller =
            new ProtocolFeeController(deployer, treasury, burnRouter, PC_TREASURY_BPS);

        vm.stopBroadcast();

        require(controller.owner() == deployer, "DeployPCController: owner mismatch");
        require(controller.treasury() == treasury, "DeployPCController: treasury mismatch");
        require(controller.burnRouter() == burnRouter, "DeployPCController: burnRouter mismatch");
        require(
            controller.treasuryBps() == PC_TREASURY_BPS, "DeployPCController: treasuryBps mismatch"
        );
        require(controller.burnBps() == PC_BURN_BPS, "DeployPCController: burnBps mismatch");

        console2.log("");
        console2.log("PCController deployed at:   ", address(controller));
        console2.log("");
        console2.log("=== Next steps ===");
        console2.log("1. Export as permanent-collection's PC_CONTROLLER env:");
        console2.log("   export PC_CONTROLLER=", address(controller));
        console2.log("2. Proceed with PC Phase 2: contracts/script/Deploy.s.sol");
    }
}
