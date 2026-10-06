// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsLpLocker} from "../src/lp-lockers/ArtCoinsLpLocker.sol";
import {Addresses} from "./Addresses.sol";

/// @dev Minimal view into the live hook — avoids importing the heavy
///      ArtCoinsHook (Uniswap hook base + HookMiner deps) just to read one
///      immutable.
interface IHookAllowlistView {
    function poolExtensionAllowlist() external view returns (address);
}

/// @title  DeployConversionLockerAndWire
/// @notice Mainnet artcoins-owner ops for the PERMANENT COLLECTION ($111)
///         path-B launch. Targets the CURRENT stack (factory 0x4959…), taken from
///         deployments/mainnet.json through Addresses.sol. NOTE: that factory is
///         `deprecated`, so the Phase 1 preflight (`!deprecated`) fails closed; the
///         current stack already has locker 0x866e…, so a second locker is not needed.
///         ("Conversion" in the name is legacy — this now deploys the lean
///         `ArtCoinsLpLocker`; fee conversion moved downstream to FeeAutoSwapper.) Run by the artcoins owner (the account that owns
///         the live V3 factory, fee escrow, AND the hook's pool-extension
///         allowlist — currently `0xCB43…17F9`). Two phases, two broadcasts:
///
///   PHASE 1 — `run()`  (BEFORE PC's `Deploy.s.sol`):
///     1. deploy a fresh `ArtCoinsLpLocker` (lean collect+escrow locker —
///        native-ETH support, MAX_LP_POSITIONS=14, keeper skim zeroed)
///     2. factory.setLocker(locker, hook, true)
///     3. escrow.addDepositor(locker)
///     4. factory.setMevModule(MEV_LINEAR_FEES, true)   [idempotent: skipped if set]
///     → logs CONVERSION_LOCKER; export it for PC's `Deploy.s.sol`.
///
///   PHASE 3 — `allowlistExtension()`  (AFTER PC's `Deploy.s.sol`):
///     5. hook.poolExtensionAllowlist().setPoolExtension(EXTENSION, true)
///        (PC's `Deploy.s.sol` logs `perSwapFeeExtension` — pass it as EXTENSION.)
///        Afterwards the PC deployer runs
///        `tokenAdminPoker.bindExtension(hook, poolKey, extension)`.
///
/// Signer-agnostic: supply the artcoins-owner signer via `--ledger`,
/// `--account <keystore>`, or `--private-key`/`PRIVATE_KEY`, and set
/// `ARTCOINS_OWNER` to that account's address. The preflight asserts
/// `ARTCOINS_OWNER` matches the on-chain owner BEFORE any broadcast, so a wrong
/// signer fails fast instead of reverting partway through.
///
/// Phase 1:
///   ARTCOINS_OWNER=0xCB43... \
///   forge script script/DeployConversionLockerAndWire.s.sol \
///     --rpc-url <MAINNET> --broadcast --ledger --sender 0xCB43... -vvv
///
/// Phase 3 (after PC deploy):
///   ARTCOINS_OWNER=0xCB43... EXTENSION=0x<perSwapFeeExtension> \
///   forge script script/DeployConversionLockerAndWire.s.sol \
///     --sig "allowlistExtension()" \
///     --rpc-url <MAINNET> --broadcast --ledger --sender 0xCB43... -vvv
contract DeployConversionLockerAndWire is Script {
    // ── current stack PC launches against (deployments/mainnet.json, via Addresses.sol) ──
    // Was hardcoded to the superseded open stack (factory 0xF051, hook 0xAAd6, escrow 0xDD1b)
    // and the legacy mev module 0xAe19. `MEV_LINEAR_FEES` keeps its name (the fork test
    // reads it) but is the current linear skim module.
    address constant FACTORY = Addresses.CURRENT_FACTORY;
    address constant HOOK = Addresses.CURRENT_HOOK;
    address constant ESCROW = Addresses.CURRENT_ESCROW;
    address constant MEV_LINEAR_FEES = Addresses.CURRENT_MEV_LINEAR_SKIM;
    // ── canonical infra (constructor deps for the locker) ──
    address constant POSITION_MANAGER = Addresses.POSITION_MANAGER;
    address constant PERMIT2 = Addresses.PERMIT2;

    // ─────────────────────────── Phase 1 ───────────────────────────

    function run() public returns (address conversionLocker) {
        require(block.chainid == Addresses.CHAIN_ID, "mainnet only");
        address owner = vm.envAddress("ARTCOINS_OWNER");
        _preflightPhase1(owner);

        vm.startBroadcast(owner);
        conversionLocker = deployAndWire(owner);
        // Match PC's no-admin-withdrawal posture. The locker's owner-gated
        // surface is withdrawETH/withdrawERC20 (loose-balance rescue) plus the
        // keeper-reward setters — PC needs none of them at runtime (the keeper
        // skim is already zeroed in `deployAndWire`, and collection forwards
        // fees to the escrow in the same call), and every other PC launch
        // contract is bytecode-scanned for the absence of any admin withdrawal
        // path. Renounce so this instance matches (freezing keeperRewardBps at
        // 0). Safe to renounce here: position-minting and reward-slot config
        // flow through the factory / per-slot-admin paths, NOT Ownable owner, so
        // no later launch step (PC's Deploy.s.sol, Phase 3) needs it.
        ArtCoinsLpLocker(payable(conversionLocker)).renounceOwnership();
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== PHASE 1 DONE ===");
        console2.log("CONVERSION_LOCKER:", conversionLocker);
        console2.log("  setLocker(locker, hook, true)     done");
        console2.log("  escrow.addDepositor(locker)       done");
        console2.log("  escrow.addDepositor(hook)         done");
        console2.log("  locker.renounceOwnership()        done (rescue surface off)");
        console2.log("  setMevModule(linearFees, true)    done/already-set");
        console2.log("");
        console2.log("NEXT: export CONVERSION_LOCKER and broadcast PC's Deploy.s.sol,");
        console2.log("      then run --sig allowlistExtension() with EXTENSION set.");
    }

    /// @dev The owner-gated wiring, factored out so the fork test can drive it
    ///      under `vm.startPrank(owner)` (the broadcast wrapper lives in `run`).
    function deployAndWire(address owner) public returns (address conversionLocker) {
        ArtCoinsLpLocker locker =
            new ArtCoinsLpLocker(owner, FACTORY, ESCROW, POSITION_MANAGER, PERMIT2);
        conversionLocker = address(locker);

        ArtCoinsFactory(payable(FACTORY)).setLocker(conversionLocker, HOOK, true);
        ArtCoinsFeeEscrow(ESCROW).addDepositor(conversionLocker);
        // The skim hook now DEPOSITS the protocol-fee leg into the escrow
        // (fresh-only settlement: ProtocolFeePhaseAdapter claims it later), so the
        // hook must be an allowlisted depositor too. Without this, every swap
        // reverts Unauthorized(). HOOK must be the redeployed ArtCoinsHookSkimFee.
        ArtCoinsFeeEscrow(ESCROW).addDepositor(HOOK);
        // PC converts artcoin-side LP fees downstream via FeeAutoSwapper (which
        // pays its own keeper reward); zero the locker-level skim so the bounty
        // isn't taxed twice. Set before the caller renounces ownership.
        locker.setKeeperRewardBps(0);
        if (!ArtCoinsFactory(payable(FACTORY)).enabledMevModules(MEV_LINEAR_FEES)) {
            ArtCoinsFactory(payable(FACTORY)).setMevModule(MEV_LINEAR_FEES, true);
        }
    }

    function _preflightPhase1(address owner) internal view {
        require(owner != address(0), "set ARTCOINS_OWNER");
        require(
            owner == ArtCoinsFactory(payable(FACTORY)).owner(), "ARTCOINS_OWNER != factory.owner()"
        );
        require(owner == ArtCoinsFeeEscrow(ESCROW).owner(), "ARTCOINS_OWNER != escrow.owner()");
        require(!ArtCoinsFactory(payable(FACTORY)).deprecated(), "factory is deprecated");
    }

    // ─────────────────────────── Phase 3 ───────────────────────────

    function allowlistExtension() public {
        require(block.chainid == Addresses.CHAIN_ID, "mainnet only");
        address owner = vm.envAddress("ARTCOINS_OWNER");
        address ext = vm.envAddress("EXTENSION");
        ArtCoinsPoolExtensionAllowlist allowlist = _allowlist();
        require(ext != address(0), "set EXTENSION");
        require(owner == allowlist.owner(), "ARTCOINS_OWNER != allowlist.owner()");

        vm.startBroadcast(owner);
        allowlistExt(ext);
        vm.stopBroadcast();

        require(allowlist.enabledExtensions(ext), "extension not enabled after call");
        console2.log("");
        console2.log("=== PHASE 3 DONE ===");
        console2.log("allowlisted extension:", ext);
        console2.log("on allowlist:", address(allowlist));
        console2.log(
            "NEXT: PC deployer runs tokenAdminPoker.bindExtension(hook, poolKey, extension)"
        );
    }

    /// @dev Owner-gated allowlist write, factored out for the fork test.
    function allowlistExt(address ext) public {
        _allowlist().setPoolExtension(ext, true);
    }

    function _allowlist() internal view returns (ArtCoinsPoolExtensionAllowlist) {
        return ArtCoinsPoolExtensionAllowlist(IHookAllowlistView(HOOK).poolExtensionAllowlist());
    }
}
