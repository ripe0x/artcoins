// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {LaunchDefaults} from "./LaunchDefaults.sol";

/// @notice Minimal launch script — deploys a Liquidity Layer Test token via
///         the ArtCoins factory, wired up with:
///           - the on-chain `LiquidityLayerOnchainRenderer` for `contractURI`
///           - the `LiquidityLayerCounterPoolExtension` as the pool extension
///             so every swap is recorded onchain
///         No airdrop, no vault, no dev-buy. The deployer keeps the entire
///         supply (LP) and owns the metadata admin slot.
///
/// Required env vars:
///     PRIVATE_KEY    deployer key
///     FACTORY        ArtCoins factory
///     HOOK           ArtCoins hook (v2 static fee)
///     LOCKER         LP locker (multiple)
///     MEV_LINEAR     Linear-fee MEV module
///     WETH           Sepolia WETH
///     LL_COUNTER     LiquidityLayerCounterPoolExtension
///     LL_RENDERER    The on-chain renderer (LiquidityLayerOnchainRenderer)
contract LaunchLLTokenSimple is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address factory = vm.envAddress("FACTORY");
        address hook = vm.envAddress("HOOK");
        address locker = vm.envAddress("LOCKER");
        address mev = vm.envAddress("MEV_LINEAR");
        address weth = vm.envAddress("WETH");
        address llCounter = vm.envAddress("LL_COUNTER");
        address renderer = vm.envAddress("LL_RENDERER");

        console2.log("=== Launching LL Test Token (renderer wired) ===");
        console2.log("Deployer:  ", deployer);
        console2.log("Factory:   ", factory);
        console2.log("Hook:      ", hook);
        console2.log("Counter:   ", llCounter);
        console2.log("Renderer:  ", renderer);

        // ── TokenConfig ────────────────────────────────────────────────────
        IArtCoinsFactory.TokenConfig memory tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: deployer,
            name: "Liquidity Layer Test",
            symbol: "LLT",
            salt: bytes32(uint256(block.timestamp)),
            image: "", // ignored — renderer overrides
            metadata: "Sepolia test of the LL on-chain renderer + counter",
            context: "ll-onchain-renderer-sepolia-test",
            totalSupply: 0, // factory default
            renderer: renderer
        });

        // ── PoolConfig: 1%/1% fees, tickSpacing 200, WETH-paired, LL counter ──
        bytes memory feeData = abi.encode(LaunchDefaults.BUY_FEE, LaunchDefaults.SELL_FEE);
        bytes memory poolData = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: llCounter, extensionData: "", feeData: feeData
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

        // ── LockerConfig: deployer takes 100% LP rewards across the
        //    4-position art-coin speculation preset ──────────────────────
        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = deployer;
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = deployer;
        // Project-side share: 80% of trading fee (factory injects 20% protocol slot).
        uint16[] memory rewardBps = new uint16[](1);
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

        // ── MEV: linear anti-sniper, 69% -> 1% over 69 min ────────────────
        IArtCoinsFactory.MevModuleConfig memory mevConfig = IArtCoinsFactory.MevModuleConfig({
            mevModule: mev, mevModuleData: LaunchDefaults.antiSniperData()
        });

        // ── No deploy-time extensions ──────────────────────────────────────
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
        console2.log("=== Deployed ===");
        console2.log("Token:        ", tokenAddress);
        console2.log("Name:         ", token.name());
        console2.log("Symbol:       ", token.symbol());
        console2.log("Total supply: ", token.totalSupply());
        console2.log("Admin:        ", token.admin());
        console2.log("");
        console2.log("Read contractURI() to verify:");
        console2.log("  cast call", tokenAddress, '"contractURI()(string)" --rpc-url $RPC');
    }
}
