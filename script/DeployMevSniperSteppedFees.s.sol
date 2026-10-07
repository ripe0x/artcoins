// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// targets superseded stack legacy and open; current stack is 0x4959… (Addresses.CURRENT_FACTORY).
// Mainnet runs are refused unless ALLOW_SUPERSEDED=1.

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {ArtCoinsMevSniperSteppedFees} from "../src/mev-modules/ArtCoinsMevSniperSteppedFees.sol";

import {Addresses} from "./Addresses.sol";

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
    /// @dev Mainnet runs are refused unless ALLOW_SUPERSEDED=1 (superseded stack legacy and open).
    function _requireSupersededAllowed() internal view {
        if (block.chainid == Addresses.CHAIN_ID && vm.envOr("ALLOW_SUPERSEDED", uint256(0)) != 1) {
            revert("targets a superseded stack; set ALLOW_SUPERSEDED=1 to run on mainnet");
        }
    }

    function run() public {
        _requireSupersededAllowed();
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
