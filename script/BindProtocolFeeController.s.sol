// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// targets superseded stack legacy (its bind ran at block 25040234); current stack is 0x4959…
// (Addresses.CURRENT_FACTORY). On mainnet, a non current factory needs ALLOW_SUPERSEDED=1 and
// the current factory needs CONFIRM_REWIRE=1 (it would redirect its 0.069 eth deploy fee and
// every default protocol slot). Any other mainnet factory is refused.

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {Addresses} from "./Addresses.sol";

/// @title BindProtocolFeeController
/// @notice Points the factory protocol/deploy fee recipient at the stable
///         ProtocolFeeController for the current chain.
///
/// Mainnet: `FACTORY` must be a registry factory (Addresses.sol), see the header.
///
/// Required env vars:
///   PRIVATE_KEY              Factory owner key.
///   FACTORY                  ArtCoinsFactory address.
///   PROTOCOL_FEE_CONTROLLER  ProtocolFeeController address.
contract BindProtocolFeeController is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factoryAddr = vm.envAddress("FACTORY");
        address controller = vm.envAddress("PROTOCOL_FEE_CONTROLLER");
        _checkRegistry(factoryAddr, controller);

        console2.log("=== Bind ProtocolFeeController ===");
        console2.log("Factory:               ", factoryAddr);
        console2.log("ProtocolFeeController: ", controller);

        ArtCoinsFactory factory = ArtCoinsFactory(factoryAddr);

        vm.startBroadcast(pk);
        factory.setTeamFeeRecipient(controller);
        vm.stopBroadcast();

        require(factory.teamFeeRecipient() == controller, "teamFeeRecipient not updated");
        require(factory.defaultProtocolFeeBps() == 2000, "defaultProtocolFeeBps must be 2000");

        console2.log("Bound factory.teamFeeRecipient");
        console2.log("factory.deprecated:          ", factory.deprecated());
        console2.log("factory.defaultProtocolFeeBps:", factory.defaultProtocolFeeBps());
    }

    function _checkRegistry(address factoryAddr, address controller) internal view {
        if (block.chainid != Addresses.CHAIN_ID) return;
        if (factoryAddr == Addresses.CURRENT_FACTORY) {
            require(
                vm.envOr("CONFIRM_REWIRE", uint256(0)) == 1,
                "current factory: set CONFIRM_REWIRE=1 to redirect its fee recipient"
            );
            require(
                controller == Addresses.CURRENT_PROTOCOL_FEE_CONTROLLER,
                "controller is not the registry current ProtocolFeeController"
            );
            return;
        }
        require(
            factoryAddr == Addresses.OPEN_FACTORY || factoryAddr == Addresses.LEGACY_FACTORY,
            "FACTORY is not in deployments/mainnet.json"
        );
        require(
            vm.envOr("ALLOW_SUPERSEDED", uint256(0)) == 1,
            "targets superseded stack; set ALLOW_SUPERSEDED=1 to run on mainnet"
        );
    }
}
