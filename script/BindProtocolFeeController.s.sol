// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";

/// @title BindProtocolFeeController
/// @notice Points the factory protocol/deploy fee recipient at the stable
///         ProtocolFeeController for the current chain.
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
}
