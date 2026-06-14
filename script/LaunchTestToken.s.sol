// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {LaunchDefaults} from "./LaunchDefaults.sol";

/// @notice Launches a test token via the factory.
/// @dev Reads deployed factory/hook/etc addresses from env vars:
///      FACTORY, HOOK, LOCKER, MEV_LINEAR, WETH, DEPLOYER
///
/// Usage:
///   PRIVATE_KEY=0x... \
///   FACTORY=0x... HOOK=0x... LOCKER=0x... MEV_LINEAR=0x... WETH=0x... DEPLOYER=0x... \
///   forge script script/LaunchTestToken.s.sol --rpc-url http://localhost:8545 --broadcast -vvv
contract LaunchTestToken is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address factory = vm.envAddress("FACTORY");
        address hook = vm.envAddress("HOOK");
        address locker = vm.envAddress("LOCKER");
        address mevLinear = vm.envAddress("MEV_LINEAR");
        address weth = vm.envAddress("WETH");

        console2.log("Launching test token");
        console2.log("Deployer:", deployer);
        console2.log("Factory: ", factory);

        // --- Build the full DeploymentConfig ---

        // 1. TokenConfig
        IArtCoinsFactory.TokenConfig memory tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: deployer,
            name: "Test Token",
            symbol: "TEST",
            salt: bytes32(uint256(block.timestamp)),
            image: "https://placehold.co/400",
            metadata: "A test token deployed via forge script",
            context: "sepolia fork deploy test",
            totalSupply: 0, // 0 = default 1B
            renderer: address(0)
        });

        // 2. PoolConfig — pair WETH (ERC20), tickSpacing 200, 1%/1% fees
        bytes memory feeData = abi.encode(LaunchDefaults.BUY_FEE, LaunchDefaults.SELL_FEE);
        bytes memory poolData = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: address(0), extensionData: "", feeData: feeData
            })
        );

        // Starting tick MUST be a multiple of tickSpacing. The 4-position
        // preset adds offsets that are themselves multiples of 200, so as
        // long as startingTick aligns the absolute ticks all align too.
        int24 startingTick = int24(-230_400);

        IArtCoinsFactory.PoolConfig memory poolConfig = IArtCoinsFactory.PoolConfig({
            hook: hook,
            pairedToken: weth, // WETH (ERC20) — never native ETH
            tickIfToken0IsArtCoins: startingTick,
            tickSpacing: LaunchDefaults.TICK_SPACING,
            poolData: poolData
        });

        // 3. LockerConfig — deployer keeps 100% of LP rewards; LP shape is
        //    the 4-position art-coin speculation preset (launch zone /
        //    main growth / maturity / moon tail).
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
            locker: locker,
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
            mevModule: mevLinear, mevModuleData: LaunchDefaults.antiSniperData()
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
        uint256 fee = ArtCoinsFactory(factory).deployFee();
        address tokenAddress = ArtCoinsFactory(factory).deployToken{value: fee}(config);
        vm.stopBroadcast();

        console2.log("");
        console2.log("Token deployed:", tokenAddress);

        ArtCoinsToken token = ArtCoinsToken(tokenAddress);
        console2.log("Name:          ", token.name());
        console2.log("Symbol:        ", token.symbol());
        console2.log("Total supply:  ", token.totalSupply());
        console2.log("Admin:         ", token.admin());
    }
}
