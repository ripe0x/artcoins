// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {IArtCoinsAirdrop} from "../src/extensions/interfaces/IArtCoinsAirdrop.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {LaunchDefaults} from "./LaunchDefaults.sol";

/// @notice Launches the Liquidity Layer migration test token on Sepolia.
/// @dev    Mirrors what the artcoins UI would build: 1B supply, single LP
///         recipient (deployer, full-range), linear MEV (defaults), and the
///         AirdropV2 extension funded with the LL merkle root, lockup=0,
///         vesting=0, allocation 10% (covers the 96.5M leaf sum).
///
/// Env vars required:
///     PRIVATE_KEY    deployer key
///     FACTORY        Sepolia factory address
///     HOOK           Sepolia hook
///     LOCKER         Sepolia locker
///     MEV_LINEAR     Sepolia MEV linear fees module
///     AIRDROP        Sepolia AirdropV2 extension (the new 0x2aE25... one)
///     WETH           Sepolia WETH
contract LaunchLLToken is Script {
    // Final 16-entry post-window root with 100M-rounded pro-rata bonus.
    // From script-js/data/ll-allowlist-100M.json. Sum = 100,000,000 LAYER exactly.
    bytes32 internal constant MERKLE_ROOT =
        0x67e99df6795c55652274e25884dca33c9198a49c34f5854faab1fefb5e297239;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address factory = vm.envAddress("FACTORY");
        address hook = vm.envAddress("HOOK");
        address locker = vm.envAddress("LOCKER");
        address mevLinear = vm.envAddress("MEV_LINEAR");
        address airdrop = vm.envAddress("AIRDROP");
        address weth = vm.envAddress("WETH");

        console2.log("=== Launching LL Test Token ===");
        console2.log("Deployer:", deployer);
        console2.log("Factory: ", factory);
        console2.log("Airdrop: ", airdrop);

        // --- TokenConfig: identifiable as the LL test deploy ---
        IArtCoinsFactory.TokenConfig memory tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: deployer,
            name: "Liquidity Layer Test",
            symbol: "LLT",
            salt: bytes32(uint256(block.timestamp)),
            image: "https://placehold.co/400/png",
            metadata: "Sepolia test for LL migration claim flow",
            context: "ll-migration-sepolia-test",
            totalSupply: 0, // 0 = factory default (1B)
            renderer: address(0)
        });

        // --- PoolConfig: 1%/1% fees, tickSpacing=200, WETH-paired ---
        bytes memory feeData = abi.encode(LaunchDefaults.BUY_FEE, LaunchDefaults.SELL_FEE);
        bytes memory poolData = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: address(0), extensionData: "", feeData: feeData
            })
        );

        int24 startingTick = int24(-230_400);

        IArtCoinsFactory.PoolConfig memory poolConfig = IArtCoinsFactory.PoolConfig({
            hook: hook,
            pairedToken: weth, // WETH (ERC20) — never native ETH
            tickIfToken0IsArtCoins: startingTick,
            tickSpacing: LaunchDefaults.TICK_SPACING,
            poolData: poolData
        });

        // --- LockerConfig: deployer gets 100% of LP rewards across the
        //     4-position art-coin speculation preset ---
        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = deployer;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = deployer;
        uint16[] memory rewardBps = new uint16[](1);
        // Project-side share: 80% of trading fee. The factory's
        // defaultProtocolFeeBps (2000 = 20%) is auto-injected as a sibling
        // slot so the on-chain locker array sums to 10_000.
        rewardBps[0] = 8000;

        (int24[] memory tickLower, int24[] memory tickUpper, uint16[] memory positionBps) =
            LaunchDefaults.buildDefaultPositions(startingTick);

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

        // --- MEV: linear anti-sniper, 69% -> 1% over 69 min ---
        IArtCoinsFactory.MevModuleConfig memory mevConfig = IArtCoinsFactory.MevModuleConfig({
            mevModule: mevLinear, mevModuleData: LaunchDefaults.antiSniperData()
        });

        // --- AirdropV2 extension: lockup=0, vesting=0 means claims open in
        //     the next block. Migrated holders can claim while speculators
        //     trade — no waiting period. ---
        IArtCoinsFactory.ExtensionConfig[] memory extensions =
            new IArtCoinsFactory.ExtensionConfig[](1);
        extensions[0] = IArtCoinsFactory.ExtensionConfig({
            extension: airdrop,
            msgValue: 0,
            extensionBps: 1000, // 10% of 1B = 100M tokens (covers 96.5M leaf sum)
            extensionData: abi.encode(
                IArtCoinsAirdrop.AirdropV2ExtensionData({
                    admin: deployer, merkleRoot: MERKLE_ROOT, lockupDuration: 0, vestingDuration: 0
                })
            )
        });

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
        console2.log("=== Deployed ===");
        console2.log("Token:        ", tokenAddress);
        console2.log("Name:         ", token.name());
        console2.log("Symbol:       ", token.symbol());
        console2.log("Total supply: ", token.totalSupply());
        console2.log("Admin:        ", token.admin());
        console2.log("");
        console2.log("Next: copy ui/public/allowlists/liquidity-layer.json to");
        console2.log("artcoins/public/allowlists/<token-address-lowercase>.json");
        console2.log("then visit /coin/11155111/<token>/claim");
    }
}
