// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {ArtCoinsMevSniperSteppedFees} from "../src/mev-modules/ArtCoinsMevSniperSteppedFees.sol";

import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";

import {LaunchDefaults} from "./LaunchDefaults.sol";

/// @title LaunchArtTest
/// @notice Launches ARTTEST on Sepolia: a vanilla artcoin used to exercise the
///         cross-coin flow (swap → fee → BurnRouter → swap WETH→LAYER → burn)
///         end-to-end on a live network.
///
/// Splits — artist 5000, project-burn 3000, factory-injected protocol 2000.
/// No migrator airdrop, no pre-burn, full 1B to LP.
///
/// Required env vars:
///   PRIVATE_KEY              Deployer key.
///   ARTIST_TREASURY          Locker reward slot 1.
///   FACTORY                  ArtCoinsFactory.
///   HOOK                     Hook on this chain.
///   LOCKER                   ArtCoinsLpLockerMultiple.
///   MEV_SNIPER_STEPPED       ArtCoinsMevSniperSteppedFees.
///   BURN_ROUTER              BurnRouter.
///   STARTING_TICK            Aligned-to-200 starting tick.
contract LaunchArtTest is Script {
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function _weth() internal view returns (address) {
        if (block.chainid == 11_155_111) return SEPOLIA_WETH;
        if (block.chainid == 1) return MAINNET_WETH;
        revert("Unsupported chain");
    }

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address artistTreasury = vm.envAddress("ARTIST_TREASURY");
        address factoryAddr = vm.envAddress("FACTORY");
        address hook = vm.envAddress("HOOK");
        address locker = vm.envAddress("LOCKER");
        address mevSniperStepped = vm.envAddress("MEV_SNIPER_STEPPED");
        address burnRouter = vm.envAddress("BURN_ROUTER");
        int24 startingTick = int24(vm.envInt("STARTING_TICK"));
        require(startingTick % 200 == 0, "STARTING_TICK not aligned to 200");

        ArtCoinsFactory factory = ArtCoinsFactory(factoryAddr);

        IArtCoinsFactory.DeploymentConfig memory config = _buildConfig(
            deployer, artistTreasury, hook, locker, mevSniperStepped, burnRouter, startingTick
        );

        uint256 fee = factory.deployFee();
        vm.startBroadcast(pk);
        address arttest = factory.deployToken{value: fee}(config);
        vm.stopBroadcast();

        console2.log("=== Launch ARTTEST (Sepolia smoke test) ===");
        console2.log("ARTTEST token:           ", arttest);
        console2.log("Pool hook:               ", hook);
        console2.log("Total supply:            ", ArtCoinsToken(arttest).totalSupply());
        console2.log("Splits:                  artist 50% / project-burn 30% / protocol 20%");
        console2.log("");
        console2.log("Pool URL: https://app.uniswap.org/explore/tokens/sepolia/", arttest);
    }

    function _buildConfig(
        address deployer,
        address artistTreasury,
        address hook,
        address locker,
        address mevSniperStepped,
        address burnRouter,
        int24 startingTick
    ) internal view returns (IArtCoinsFactory.DeploymentConfig memory config) {
        config.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: deployer,
            name: "Art Test",
            symbol: "ARTTEST",
            salt: bytes32(0),
            image: "",
            metadata: "ARTTEST -- Sepolia smoke test for cross-coin BurnRouter flow",
            context: "arttest-sepolia",
            totalSupply: 1_000_000_000e18,
            renderer: address(0)
        });

        bytes memory feeData = abi.encode(LaunchDefaults.BUY_FEE, LaunchDefaults.SELL_FEE);
        bytes memory poolData = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: address(0), extensionData: "", feeData: feeData
            })
        );
        config.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: hook,
            pairedToken: _weth(),
            tickIfToken0IsArtCoins: startingTick,
            tickSpacing: LaunchDefaults.TICK_SPACING,
            poolData: poolData
        });

        // Locker: artist 5000, project-burn 3000 (sums to 8000; factory injects 2000 protocol slot).
        address[] memory rewardAdmins = new address[](2);
        rewardAdmins[0] = artistTreasury;
        rewardAdmins[1] = deployer;
        address[] memory rewardRecipients = new address[](2);
        rewardRecipients[0] = artistTreasury;
        rewardRecipients[1] = burnRouter;
        uint16[] memory rewardBps = new uint16[](2);
        rewardBps[0] = 5000;
        rewardBps[1] = 3000;

        (int24[] memory tickLower, int24[] memory tickUpper, uint16[] memory positionBps) =
            LaunchDefaults.buildRecommendedPositions(startingTick);

        config.lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: locker,
            rewardAdmins: rewardAdmins,
            rewardRecipients: rewardRecipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: ""
        });

        // MEV: same stepped schedule as LAYER.
        ArtCoinsMevSniperSteppedFees.Step[] memory schedule =
            new ArtCoinsMevSniperSteppedFees.Step[](5);
        schedule[0] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 60, feePpm: 500_000});
        schedule[1] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 120, feePpm: 250_000});
        schedule[2] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 120, feePpm: 150_000});
        schedule[3] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 300, feePpm: 70_000});
        schedule[4] = ArtCoinsMevSniperSteppedFees.Step({durationSec: 300, feePpm: 30_000});
        // ARTTEST uses the same base 1% so the new sniper-stepped module's
        // basePpm matches LaunchDefaults.BUY_FEE.
        uint24 basePpm = LaunchDefaults.BUY_FEE;
        config.mevModuleConfig = IArtCoinsFactory.MevModuleConfig({
            mevModule: mevSniperStepped, mevModuleData: abi.encode(schedule, basePpm)
        });

        // No extensions for ARTTEST — full 1B goes to LP.
        config.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](0);
    }
}
