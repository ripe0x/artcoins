// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerSpriteRenderer} from "../src/extensions/LiquidityLayerSpriteRenderer.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";

/// @notice Deploys the LL counter pool extension + sprite renderer for a
///         freshly-deployed hook, and allowlists the counter on the
///         hook's pool extension allowlist contract.
///
/// Required env vars:
///   PRIVATE_KEY, HOOK, POOL_EXT_ALLOWLIST, ANIMATION_URL_BASE
///
/// Usage (always include --verify so the contracts are queryable on
/// Etherscan from the moment they land):
///   PRIVATE_KEY=0x... \
///   HOOK=0x... POOL_EXT_ALLOWLIST=0x... \
///   ANIMATION_URL_BASE=https://artcoins.com/embed \
///   forge script script/DeployLLExtension.s.sol --rpc-url <RPC> \
///       --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vv
contract DeployLLExtension is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address hook = vm.envAddress("HOOK");
        address allowlist = vm.envAddress("POOL_EXT_ALLOWLIST");
        string memory animBase = vm.envString("ANIMATION_URL_BASE");

        console2.log("=== Deploy LL extension + sprite renderer ===");
        console2.log("Hook:                ", hook);
        console2.log("Pool ext allowlist:  ", allowlist);
        console2.log("Animation URL base:  ", animBase);
        console2.log("");

        vm.startBroadcast(pk);

        LiquidityLayerCounterPoolExtension counter = new LiquidityLayerCounterPoolExtension(hook);
        console2.log("[1] LLCounter:           ", address(counter));

        LiquidityLayerSpriteRenderer renderer = new LiquidityLayerSpriteRenderer(counter, animBase);
        console2.log("[2] LLSpriteRenderer:    ", address(renderer));

        ArtCoinsPoolExtensionAllowlist(allowlist).setPoolExtension(address(counter), true);
        console2.log("[3] Allowlisted counter on pool ext allowlist");

        vm.stopBroadcast();

        console2.log("");
        console2.log("Done. Use the counter as the 'pool extension' in the deploy form,");
        console2.log("and the sprite renderer as the token's metadata renderer.");
    }
}
