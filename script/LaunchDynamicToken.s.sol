// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {DynamicBlockRenderer} from "../src/renderer/DynamicBlockRenderer.sol";
import {LaunchDefaults} from "./LaunchDefaults.sol";

/// @notice Deploy a new token with the DynamicBlockRenderer.
/// @dev Uses the Sepolia addresses from config.ts.
///
/// Usage:
///   source .env && forge script script/LaunchDynamicToken.s.sol \
///     --rpc-url "$SEPOLIA_RPC_URL" --broadcast -vvv
contract LaunchDynamicToken is Script {
    // Sepolia addresses (from ui/src/lib/config.ts)
    address constant FACTORY = 0x3c3aEfC8Fa374589D179D43cb03e29a6B350DF7A;
    address constant HOOK = 0x36EF2eC4c1DF5e0A07567306D721F2Bb5d4E68cc;
    address constant LOCKER = 0x6e511f2321F82559E559ce1Da0EcFDBf0E4ace62;
    address constant MEV_LINEAR = 0x7f0AC1a505614CF21a78ed276710864C8b256b4e;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("=== Launch Dynamic Token ===");
        console2.log("Deployer:", deployer);

        // 1. TokenConfig
        IArtCoinsFactory.TokenConfig memory tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: deployer,
            name: "Dynamic Block Art",
            symbol: "DYNBLK",
            salt: bytes32(uint256(block.timestamp)),
            image: "",
            metadata: "Token with dynamic on-chain SVG that changes every block. Shows block number, hash, and timestamp.",
            context: "dynamic renderer test",
            totalSupply: 0, // default 1B
            renderer: address(0)
        });

        // 2. PoolConfig — WETH-paired, tickSpacing 200, 1%/1% fees
        bytes memory feeData = abi.encode(LaunchDefaults.BUY_FEE, LaunchDefaults.SELL_FEE);
        bytes memory poolData = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: address(0), extensionData: "", feeData: feeData
            })
        );

        int24 startingTick = int24(-230_400);

        IArtCoinsFactory.PoolConfig memory poolConfig = IArtCoinsFactory.PoolConfig({
            hook: HOOK,
            pairedToken: WETH,
            tickIfToken0IsArtCoins: startingTick,
            tickSpacing: LaunchDefaults.TICK_SPACING,
            poolData: poolData
        });

        // 3. LockerConfig — deployer gets 100% of fees across the
        //    4-position art-coin speculation preset
        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = deployer;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = deployer;
        uint16[] memory rewardBps = new uint16[](1);
        // Project-side share: 80% of trading fee (factory injects 20% protocol slot).
        rewardBps[0] = 8000;

        (int24[] memory tickLower, int24[] memory tickUpper, uint16[] memory positionBps) =
            LaunchDefaults.buildDefaultPositions(startingTick);

        IArtCoinsFactory.LockerConfig memory lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: LOCKER,
            rewardAdmins: rewardAdmins,
            rewardRecipients: rewardRecipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: ""
        });

        // 4. MevModuleConfig — linear anti-sniper, 69% -> 1% over 69 min
        IArtCoinsFactory.MevModuleConfig memory mevConfig = IArtCoinsFactory.MevModuleConfig({
            mevModule: MEV_LINEAR, mevModuleData: LaunchDefaults.antiSniperData()
        });

        // 5. No extensions
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

        // Deploy token via factory
        uint256 fee = ArtCoinsFactory(FACTORY).deployFee();
        address tokenAddress = ArtCoinsFactory(FACTORY).deployToken{value: fee}(config);
        ArtCoinsToken token = ArtCoinsToken(tokenAddress);

        console2.log("");
        console2.log("Token deployed:  ", tokenAddress);
        console2.log("Name:            ", token.name());
        console2.log("Symbol:          ", token.symbol());
        console2.log("Total supply:    ", token.totalSupply());

        // Deploy renderer and set it on the token
        DynamicBlockRenderer renderer = new DynamicBlockRenderer();
        console2.log("Renderer deployed:", address(renderer));

        token.setMetadataRenderer(address(renderer));
        console2.log("Renderer set on token!");

        // Verify
        string memory uri = token.contractURI();
        console2.log("contractURI len: ", bytes(uri).length);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Done! ===");
        console2.log("Token:    ", tokenAddress);
        console2.log("Renderer: ", address(renderer));
    }
}
