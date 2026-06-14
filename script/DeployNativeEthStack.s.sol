// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsAutoBurnPoolExtension} from "../src/extensions/ArtCoinsAutoBurnPoolExtension.sol";
import {ArtCoinsHookStaticFee} from "../src/hooks/ArtCoinsHookStaticFee.sol";
import {ArtCoinsLpLocker} from "../src/lp-lockers/ArtCoinsLpLocker.sol";
import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";

/// @title  DeployNativeEthStack
/// @notice Deploys the full V3 artcoins stack: factory, hook, LP locker,
///         fee escrow, and BurnRouter with keeper rewards. Wires the factory
///         to recognize the new hook+locker and routes the protocol slot to
///         the new BurnRouter. After this run, the V3 stack is ready to
///         accept native-ETH-paired artcoin deploys via
///         `factory.deployTokenWithProtocolBps(config, bps)`.
///
///         New deploys: only this script. Existing artcoin pools (LAYER) are
///         on the V1 factory and unaffected.
///
/// @dev    Wiring done in-broadcast (deployer must be owner of all new
///         contracts at deploy time, which it is by construction). The
///         BurnRouter's slippage floor is auto-derived from the rolling EMA
///         each call — no post-deploy floor setting required. The factory's
///         `defaultProtocolFeeBps` defaults to 2000 (20%); for the $111 launch,
///         call `factory.deployTokenWithProtocolBps(cfg, 1000)` to override.
///
/// Required env:
///   PRIVATE_KEY              Deployer key (becomes owner of factory + escrow + burnRouter)
///   POOL_MANAGER             V4 PoolManager
///   POSITION_MANAGER         V4 PositionManager (for LP locker)
///   PERMIT2                  Canonical Permit2
///   WETH                     Canonical WETH
///   UNIVERSAL_ROUTER         Uniswap Universal Router (for BurnRouter swaps)
///   LAYER_TOKEN              LAYER ERC20 address (already deployed)
///   LAYER_POOL_C0            currency0 of the canonical LAYER/WETH pool
///   LAYER_POOL_C1            currency1 of the canonical LAYER/WETH pool
///   LAYER_POOL_FEE           Pool fee (e.g. 3000)
///   LAYER_POOL_TICK_SPACING  Pool tick spacing
///   LAYER_POOL_HOOK          Hook address for the LAYER pool (0x0 if none)
///
/// Run:
///   forge script script/DeployNativeEthStack.s.sol --rpc-url <RPC> \
///       --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvv
contract DeployNativeEthStack is Script {
    function run()
        public
        returns (
            address factoryAddr,
            address feeEscrowAddr,
            address lpLockerAddr,
            address hookAddr,
            address burnRouterAddr
        )
    {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address poolManager = vm.envAddress("POOL_MANAGER");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");
        address weth = vm.envAddress("WETH");
        address layerToken = vm.envAddress("LAYER_TOKEN");

        // Build the LAYER pool key from env (sorted currencies + fee + tickSpacing + hook).
        PoolKey memory layerPoolKey = PoolKey({
            currency0: Currency.wrap(vm.envAddress("LAYER_POOL_C0")),
            currency1: Currency.wrap(vm.envAddress("LAYER_POOL_C1")),
            fee: uint24(vm.envUint("LAYER_POOL_FEE")),
            tickSpacing: int24(int256(vm.envInt("LAYER_POOL_TICK_SPACING"))),
            hooks: IHooks(vm.envAddress("LAYER_POOL_HOOK"))
        });

        console2.log("Deployer:               ", deployer);
        console2.log("");

        vm.startBroadcast(pk);

        // 1. Factory (V3 — per-deploy protocolBps override capability).
        ArtCoinsFactory factory = new ArtCoinsFactory(deployer);
        factoryAddr = address(factory);
        console2.log("ArtCoinsFactory:      ", factoryAddr);

        // 2. Pool-extension allowlist (re-used by the hook for V2-compat
        //    extension flow; we deploy a fresh empty one).
        ArtCoinsPoolExtensionAllowlist extAllowlist = new ArtCoinsPoolExtensionAllowlist(deployer);
        console2.log("ExtensionAllowlist:     ", address(extAllowlist));

        // 3. Fee escrow.
        ArtCoinsFeeEscrow escrow = new ArtCoinsFeeEscrow(deployer);
        feeEscrowAddr = address(escrow);
        console2.log("ArtCoinsFeeEscrow:      ", feeEscrowAddr);

        // 4. LP locker (binds to the new factory + new escrow).
        ArtCoinsLpLocker locker =
            new ArtCoinsLpLocker(deployer, factoryAddr, feeEscrowAddr, positionManager, permit2);
        lpLockerAddr = address(locker);
        console2.log("ArtCoinsLpLocker:       ", lpLockerAddr);

        // 5. BurnRouter (V3 — with keeper rewards).
        BurnRouter burnRouter = new BurnRouter(deployer);
        burnRouterAddr = address(burnRouter);
        console2.log("BurnRouter:           ", burnRouterAddr);

        // 6. Mine + deploy hook. Salt picked so the deployed address has the
        //    required V4 hook-permission bits in its lowest 14 bits.
        // Scoped to free the mining temporaries (stack pressure).
        {
            uint160 hookFlags = uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            );
            // CREATE2_DEPLOYER is the canonical 0x4e59... proxy used by forge
            // script --broadcast.
            (address minedHook, bytes32 hookSalt) = HookMiner.find(
                0x4e59b44847b379578588920cA78FbF26c0B4956C,
                hookFlags,
                type(ArtCoinsHookStaticFee).creationCode,
                abi.encode(poolManager, factoryAddr, address(extAllowlist), weth, feeEscrowAddr)
            );
            hookAddr = address(
                new ArtCoinsHookStaticFee{salt: hookSalt}(
                    poolManager, factoryAddr, address(extAllowlist), weth, feeEscrowAddr
                )
            );
            require(hookAddr == minedHook, "Hook address mismatch");
        }
        console2.log("ArtCoinsHookStaticFee:  ", hookAddr);

        // ─── wiring ──────────────────────────────────────────────────────

        // Factory: allowlist hook + locker, point teamFeeRecipient at
        // BurnRouter, un-deprecate so deploys can proceed. Drop the
        // per-token-launch deploy fee to 0 — we don't gate launches on
        // ETH payment for the V3 stack (the protocol-fee bps split is the
        // only economic plumbing). Owner can re-raise it later via
        // `factory.setDeployFee(...)`.
        factory.setHook(hookAddr, true);
        factory.setLocker(lpLockerAddr, hookAddr, true);
        factory.setTeamFeeRecipient(burnRouterAddr);
        factory.setDeployFee(0);
        factory.setDeprecated(false);

        // Escrow: allowlist LP locker AND the hook as depositors. The hook
        // calls `storeFeesNative` from `_sniperExtraFeeClaim` to route
        // native-ETH sniper-extra fees (M-03 fix).
        escrow.addDepositor(lpLockerAddr);
        escrow.addDepositor(hookAddr);

        // BurnRouter: initialize with LAYER, WETH, pool manager, LAYER pool key.
        // Sandwich protection is the hardcoded `MAX_SWAP_IMPACT_BPS` price-impact
        // cap (set below the LAYER round-trip fee moat) — no EMA gate, no knob.
        burnRouter.initialize(layerToken, weth, layerPoolKey, poolManager);

        // 7. Auto-burn pool extension (stack member). One shared instance:
        //    any coin whose pool sets it as the extension drives the
        //    keeper-less LAYER buy-and-burn on every swap. It reads LAYER/WETH
        //    from the now-initialized BurnRouter, so it MUST be deployed after
        //    `burnRouter.initialize`. pfc = address(0): this stack routes the
        //    protocol share straight to the BurnRouter (teamFeeRecipient), so
        //    the extension's PFC stages are disabled. Allowlisted on the
        //    extension allowlist so coin launches can reference it.
        {
            ArtCoinsAutoBurnPoolExtension autoBurn = new ArtCoinsAutoBurnPoolExtension(
                hookAddr, feeEscrowAddr, address(0), burnRouterAddr, deployer
            );
            extAllowlist.setPoolExtension(address(autoBurn), true);
            console2.log("AutoBurnPoolExtension:  ", address(autoBurn));
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("Defaults:");
        console2.log("  factory.deployFee()                    = 0 (set by this script)");
        console2.log("  factory.defaultProtocolFeeBps()       = 2000 (20%)");
        console2.log("  burnRouter.minProcessThreshold        = 0.01 ether");
        console2.log("  burnRouter.KEEPER_REWARD_BPS          = 50 (0.5%)");
        console2.log("  burnRouter.KEEPER_REWARD_CAP          = 0.01 ether");
        console2.log("");
        console2.log("LP-locker keeper reward (paid to msg.sender of");
        console2.log("`locker.collectRewards(token)`; skimmed off paired-side fees");
        console2.log("before distribution to recipients):");
        console2.log("  locker.keeperRewardBps                = 50 (0.5%)");
        console2.log("  locker.keeperRewardCap                = 0.01 ether");
        console2.log("  Owner-adjustable within hard bounds:");
        console2.log("    keeperRewardBps in [0, 200]         (max 2%, ceiling enforced on-chain)");
        console2.log("    keeperRewardCap in [0.001, 0.05 ether]");
        console2.log("  Setters: locker.setKeeperRewardBps(bps),");
        console2.log("           locker.setKeeperRewardCap(weiCap)");
        console2.log("  Burning the setters: Ownable.renounceOwnership() on the");
        console2.log("  locker freezes both values forever (one-way).");
        console2.log("");
        console2.log("For $111 deploy: use deployTokenWithProtocolBps(cfg, 1000)");
        console2.log("                  to override the protocol fee to 10%.");
    }
}
