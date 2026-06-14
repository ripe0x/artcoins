// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";

/// @notice Deploys a smoke-test token via the (new) hook + LL counter pool
///         extension. No airdrop, no vault — minimal to keep the deploy
///         small. Used to validate that:
///           - the new hook accepts deploys (registered on the factory)
///           - the LL counter extension binds to the pool
///           - swaps post-deploy will increment buys / sells
///
/// Required env vars:
///   PRIVATE_KEY, FACTORY, HOOK, LOCKER, MEV_LINEAR, AIRDROP (unused),
///   WETH, COUNTER_EXTENSION
contract SmokeTestLLCounter is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address factory = vm.envAddress("FACTORY");
        address hook = vm.envAddress("HOOK");
        address locker = vm.envAddress("LOCKER");
        address mevLinear = vm.envAddress("MEV_LINEAR");
        address weth = vm.envAddress("WETH");
        address counter = vm.envAddress("COUNTER_EXTENSION");

        console2.log("=== Smoke deploy: LL counter token ===");
        console2.log("Deployer:        ", deployer);
        console2.log("Hook:            ", hook);
        console2.log("Counter ext:     ", counter);

        // --- Token config ---
        IArtCoinsFactory.TokenConfig memory tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: deployer,
            name: "LL Smoke",
            symbol: "LLSMK",
            salt: bytes32(uint256(block.timestamp)),
            image: "https://gateway.irys.xyz/4t5vh5u8ExzX6wyJnHRmzYhHLVTCD6ZHXoBXTh3exBet",
            metadata: "Smoke test for LL counter pool extension",
            context: "",
            totalSupply: 0,
            renderer: address(0)
        });

        // --- Pool config: paired with WETH, LL counter as pool extension ---
        bytes memory feeData = abi.encode(uint24(10_000), uint24(10_000));
        bytes memory poolData = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: counter, extensionData: "", feeData: feeData
            })
        );
        IArtCoinsFactory.PoolConfig memory poolConfig = IArtCoinsFactory.PoolConfig({
            hook: hook,
            pairedToken: weth,
            tickIfToken0IsArtCoins: int24(-230_400),
            tickSpacing: int24(60),
            poolData: poolData
        });

        // --- LP locker: deployer gets 100% rewards, full-range single-sided ---
        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = deployer;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = deployer;
        uint16[] memory rewardBps = new uint16[](1);
        // Project-side share: 80% of trading fee (factory injects 20% protocol slot).
        rewardBps[0] = 8000;

        int24[] memory tickLower = new int24[](1);
        tickLower[0] = int24(-230_400);
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = int24(887_220);
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        IArtCoinsFactory.LockerConfig memory lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: locker,
            rewardAdmins: rewardAdmins,
            rewardRecipients: rewardRecipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: ""
        });

        // --- MEV: linear default ---
        IArtCoinsFactory.MevModuleConfig memory mevConfig =
            IArtCoinsFactory.MevModuleConfig({mevModule: mevLinear, mevModuleData: ""});

        // --- No deploy-time extensions (no airdrop / vault / dev-buy) ---
        IArtCoinsFactory.ExtensionConfig[] memory extensions =
            new IArtCoinsFactory.ExtensionConfig[](0);

        IArtCoinsFactory.DeploymentConfig memory config = IArtCoinsFactory.DeploymentConfig({
            tokenConfig: tokenConfig,
            poolConfig: poolConfig,
            lockerConfig: lockerConfig,
            mevModuleConfig: mevConfig,
            sniperFeeConfig: IArtCoinsFactory.SniperFeeConfig({
                recipient: address(0), lockRecipient: false
            }),
            extensionConfigs: extensions
        });

        vm.startBroadcast(pk);
        uint256 fee = ArtCoinsFactory(factory).deployFee();
        address tokenAddress = ArtCoinsFactory(factory).deployToken{value: fee}(config);
        vm.stopBroadcast();

        ArtCoinsToken token = ArtCoinsToken(tokenAddress);
        console2.log("");
        console2.log("Token:           ", tokenAddress);
        console2.log("Name:            ", token.name());
        console2.log("Total supply:    ", token.totalSupply());
        console2.log("Admin:           ", token.admin());
    }
}
