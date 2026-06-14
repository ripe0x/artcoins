// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsHookStaticFeeV2} from "../src/hooks/legacy/ArtCoinsHookStaticFeeV2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Redeploys ArtCoinsHookStaticFeeV2 with the new
///         setPoolExtension / lockPoolExtension capabilities.
///
/// @dev    Reuses the EXISTING factory, pool-extension allowlist, and weth
///         from the prior deploy. Mines a fresh CREATE2 salt for the new
///         bytecode. Caller must `factory.setHook(newHookAddress, true)`
///         after this lands to allowlist the new hook for token deploys.
///
/// Usage:
///   PRIVATE_KEY=0x... \
///   POOL_MANAGER=0x... FACTORY=0x... POOL_EXT_ALLOWLIST=0x... WETH=0x... \
///   forge script script/RedeployHook.s.sol --rpc-url <RPC> \
///       --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvv
contract RedeployHook is Script {
    /// @dev Canonical CREATE2 deployer used by HookMiner.find / new{salt:}.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address factory = vm.envAddress("FACTORY");
        address poolExtAllowlist = vm.envAddress("POOL_EXT_ALLOWLIST");
        address weth = vm.envAddress("WETH");

        // Same hook permissions as the existing deploy.
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(poolManager, factory, poolExtAllowlist, weth);

        (address minedAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, hookFlags, type(ArtCoinsHookStaticFeeV2).creationCode, constructorArgs
        );

        console2.log("Mined hook address: ", minedAddress);

        vm.startBroadcast(pk);
        ArtCoinsHookStaticFeeV2 hook =
            new ArtCoinsHookStaticFeeV2{salt: salt}(poolManager, factory, poolExtAllowlist, weth);
        vm.stopBroadcast();

        require(address(hook) == minedAddress, "Address mismatch");
        console2.log("Deployed:           ", address(hook));
        console2.log("");
        console2.log("Next: factory.setHook(", address(hook), ", true)");
    }
}
