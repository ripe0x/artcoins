// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {ArtCoinsMevSniperSteppedFees} from "../src/mev-modules/ArtCoinsMevSniperSteppedFees.sol";

/// @title DeployMevSniperSteppedFees
/// @notice Deploys the sniper-stepped MEV module (which signals an "extra"
///         ppm above the pool base fee, routed 100% to the per-pool
///         sniper-fee recipient) and optionally allowlists it on the target
///         factory in a single broadcast. Use the allowlist path only if the
///         broadcaster is the factory owner/admin.
///
/// Env vars:
///   PRIVATE_KEY     Deployer private key.
///   FACTORY         (optional) Factory to allowlist the module on.
contract DeployMevSniperSteppedFees is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factory = vm.envOr("FACTORY", address(0));

        console2.log("=== Deploy ArtCoinsMevSniperSteppedFees ===");
        vm.startBroadcast(pk);

        ArtCoinsMevSniperSteppedFees mev = new ArtCoinsMevSniperSteppedFees();
        console2.log("ArtCoinsMevSniperSteppedFees deployed:", address(mev));

        if (factory != address(0)) {
            ArtCoinsFactory(factory).setMevModule(address(mev), true);
            console2.log("Allowlisted on factory:", factory);
        }

        vm.stopBroadcast();
    }
}
