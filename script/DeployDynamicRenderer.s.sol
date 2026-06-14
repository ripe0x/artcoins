// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {DynamicBlockRenderer} from "../src/renderer/DynamicBlockRenderer.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @notice Deploy the DynamicBlockRenderer and optionally set it on a token.
///
/// Deploy only:
///   forge script script/DeployDynamicRenderer.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv
///
/// Deploy + set on token:
///   TOKEN=0x... forge script script/DeployDynamicRenderer.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv
contract DeployDynamicRenderer is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        DynamicBlockRenderer renderer = new DynamicBlockRenderer();
        console2.log("DynamicBlockRenderer deployed:", address(renderer));

        // If TOKEN env var is set, wire it up
        address tokenAddr = vm.envOr("TOKEN", address(0));
        if (tokenAddr != address(0)) {
            ArtCoinsToken token = ArtCoinsToken(tokenAddr);
            console2.log("Setting renderer on token:", tokenAddr);
            token.setMetadataRenderer(address(renderer));
            console2.log("Renderer set! Verifying...");

            // Quick verification
            string memory uri = token.contractURI();
            console2.log("contractURI length:", bytes(uri).length);
            console2.log("contractURI prefix:", _prefix(uri, 40));
        }

        vm.stopBroadcast();
    }

    function _prefix(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length <= n) return s;
        bytes memory result = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            result[i] = b[i];
        }
        return string(result);
    }
}
