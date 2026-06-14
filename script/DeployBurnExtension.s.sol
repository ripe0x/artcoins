// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {BurnExtension} from "../src/extensions/BurnExtension.sol";
import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";

/// @title DeployBurnExtension
/// @notice Deploys the BurnExtension and optionally allowlists it on a target
///         factory.
///
/// Env vars:
///   PRIVATE_KEY  Deployer private key.
///   FACTORY      The factory to bind to (and optionally allowlist on).
contract DeployBurnExtension is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("FACTORY");

        console2.log("=== Deploy BurnExtension ===");
        console2.log("Factory:", factory);

        vm.startBroadcast(pk);
        BurnExtension ext = new BurnExtension(factory);
        console2.log("BurnExtension deployed:", address(ext));

        // Try to allowlist (only succeeds if broadcaster is factory owner/admin).
        try ArtCoinsFactory(factory).setExtension(address(ext), true) {
            console2.log("Allowlisted on factory");
        } catch {
            console2.log("NOTE: Could not auto-allowlist (broadcaster not factory owner/admin)");
            console2.log("      Run factory.setExtension(", address(ext), ", true) separately.");
        }
        vm.stopBroadcast();
    }
}
