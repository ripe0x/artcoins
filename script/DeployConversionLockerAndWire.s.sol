// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsLpLocker} from "../src/lp-lockers/ArtCoinsLpLocker.sol";

/// @dev Minimal view into the live hook — avoids importing the heavy
///      ArtCoinsHook (Uniswap hook base + HookMiner deps) just to read one
///      immutable.
interface IHookAllowlistView {
    function poolExtensionAllowlist() external view returns (address);
}

/// @title  DeployConversionLockerAndWire
/// @notice Mainnet artcoins-owner ops for the PERMANENT COLLECTION ($111)
///         path-B launch. ("Conversion" in the name is legacy — this now
///         deploys the lean `ArtCoinsLpLocker`; fee conversion moved downstream
///         to FeeAutoSwapper.) Run by the artcoins owner (the account that owns
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
    // ── live V3 stack PC launches against (verified on-chain) ──
    address constant FACTORY = 0xF051cd4C4F3F36F9f24d8a19d60Ee8F84FC6793e;
    address constant HOOK = 0xAAd673ea3945dF5F7Ef328974d2c07c8BdcAA8Cc;
    address constant ESCROW = 0xDD1b8C9C99Be3C717B9A5eb3C84297C5bfca1C06;
    address constant MEV_LINEAR_FEES = 0xAe19E402420359062eE422a03589e04a52cD8C6F;
    // ── canonical infra (constructor deps for the locker) ──
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ─────────────────────────── Phase 1 ───────────────────────────

    function run() public returns (address conversionLocker) {
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
