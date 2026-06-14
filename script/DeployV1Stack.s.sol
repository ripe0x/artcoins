// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsHookSkimFee} from "../src/hooks/ArtCoinsHookSkimFee.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsLpLocker} from "../src/lp-lockers/ArtCoinsLpLocker.sol";
import {ArtCoinsMevLinearSkim} from "../src/mev-modules/ArtCoinsMevLinearSkim.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @title  DeployV1Stack
/// @notice One-shot deploy of the artcoins v1 stack that the
///         `permanent-collection` Phase 2 launch consumes. Replaces the
///         "v3-named" stack at `0xF051…6793e` whose factory bytecode hard-
///         checks a pre-rename `IArtCoinsHook` interfaceId no longer
///         reported by freshly-compiled hooks (see commit fed632b — the
///         slim base was merged into the extended interface, recomputing
///         the id). This script ships a fresh stack at clean addresses
///         with `factory.version() == "1"` on-chain.
///
/// What gets deployed (six contracts, in dependency order):
///   1. `ArtCoinsFactory`                    — core deployer, version "1"
///   2. `ArtCoinsFeeEscrow`                  — protocol fee storage
///   3. `ArtCoinsPoolExtensionAllowlist`     — registry for pool extensions
///   4. `ArtCoinsHookSkimFee`                — V4 hook (CREATE2 address-mined)
///   5. `ArtCoinsLpLocker`                  — lean collect+escrow LP locker
///   6. `ArtCoinsMevLinearSkim`              — MEV module (LinearSkim variant)
///
/// Wiring (same broadcast):
///   - `factory.setTeamFeeRecipient(deployer)`  (placeholder — bypassed when
///       PC passes `ARTCOINS_PROTOCOL_BPS = 0`; can be re-pointed later)
///   - `factory.setDeployFee(0)`                (no per-launch ETH gate)
///   - `factory.setHook(hook, true)`
///   - `factory.setLocker(locker, hook, true)`
///   - `factory.setMevModule(mev, true)`
///   - `escrow.addDepositor(locker)`            (locker stores collected fees here)
///   - `escrow.addDepositor(hook)`              (hook stores the protocol fee leg
///       on every swap via `storeFeesNative`; the escrow reverts for
///       non-depositors, so without this every swap bricks)
///   - `locker.setKeeperRewardBps(0)`           (no locker-level keeper skim —
///       PC converts artcoin-side fees downstream via FeeAutoSwapper, which
///       pays its own keeper reward; zeroing here avoids taxing the bounty twice)
///
/// What's NOT redeployed (out of scope for this script):
///   - `BurnRouter`, `ProtocolFeeController`, `PCController` — separate
///     deploys, downstream of this stack. PC's `Deploy.s.sol` resolves them
///     via env vars at Phase 2 time.
///   - LAYER-specific extensions (vault, airdrop, dev-buy, etc.) — those
///     belong to the frozen LAYER stack at `0xd159…2292f9` and are not used
///     by PC.
///
/// Post-broadcast steps (out of script):
///   1. Export the six addresses logged at the end of `run()`.
///   2. In `permanent-collection`:
///        - Edit `contracts/script/Deploy.s.sol` constants
///          (`ARTCOINS_FACTORY`, `ARTCOINS_LOCKER`, `ARTCOINS_FEE_LOCKER`)
///          to the new addresses. Commit.
///        - Bump the artcoins submodule pin to the post-deploy artcoins
///          commit. Commit.
///   3. PC Phase 2 (`forge script contracts/script/Deploy.s.sol`) runs
///      against the new stack with:
///        - `ARTCOINS_HOOK_SKIM=<deployed hook>`
///        - `ARTCOINS_MEV_SKIM=<deployed MEV>`
///        - `CONVERSION_LOCKER=<deployed locker>`
///        - (plus `PC_CONTROLLER` resolved separately).
///
/// Usage (mainnet):
///   PRIVATE_KEY=0x... \
///   forge script script/DeployV1Stack.s.sol \
///     --rpc-url $MAINNET_RPC_URL \
///     --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvv
///
/// Usage (fork rehearsal):
///   forge test --match-contract DeployV1StackForkTest \
///     --fork-url https://gateway.tenderly.co/public/mainnet -vv
contract DeployV1Stack is Script {
    // ── canonical Ethereum mainnet infrastructure ─────────────────────────
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Canonical CREATE2 deployer proxy used by `forge script --broadcast`
    ///      when it rewrites `new Contract{salt:}(...)`. HookMiner must mine
    ///      against this address so the on-chain deploy lands at the mined
    ///      address.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Bag of every address produced by `deployStack`. Returned to the
    ///         caller so both `run()` (logging) and the fork test (assertions)
    ///         can consume it.
    struct Stack {
        address factory;
        address escrow;
        address poolExtAllowlist;
        address hook;
        address locker;
        address mev;
    }

    /// @notice Deploys + wires the v1 stack as `deployer` and returns every
    ///         address. Caller is responsible for `vm.startBroadcast(deployer)`
    ///         before calling and `vm.stopBroadcast()` after. The factored-out
    ///         form lets `run()` use script-mode broadcast (which rewrites
    ///         `new {salt}` to CREATE2_DEPLOYER) and lets the fork test
    ///         broadcast as a synthetic deployer under `vm.prank`.
    function deployStack(address deployer) public returns (Stack memory s) {
        // 1. Factory (version "1"). `deprecated = true` per constructor —
        //    owner deploys still work; flip to false later if/when public
        //    deploys should be enabled.
        ArtCoinsFactory factory = new ArtCoinsFactory(deployer);
        s.factory = address(factory);

        // 2. Fee escrow. Owner = deployer; locker added as depositor below.
        ArtCoinsFeeEscrow escrow = new ArtCoinsFeeEscrow(deployer);
        s.escrow = address(escrow);

        // 3. Pool-extension allowlist. PC adds its own extensions via
        //    `tokenAdminPoker.bindExtension` post-launch; this stack ships
        //    empty.
        ArtCoinsPoolExtensionAllowlist poolExtAllowlist =
            new ArtCoinsPoolExtensionAllowlist(deployer);
        s.poolExtAllowlist = address(poolExtAllowlist);

        // 4. Mine + deploy hook. Salt selected so the address's low 14 bits
        //    encode the permissions reported by
        //    `ArtCoinsHookSkimFee.getHookPermissions()`:
        //      beforeInitialize, beforeAddLiquidity, beforeSwap, afterSwap,
        //      beforeSwapReturnsDelta, afterSwapReturnsDelta.
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs =
            abi.encode(POOL_MANAGER, s.factory, s.poolExtAllowlist, WETH, s.escrow);
        (address minedHook, bytes32 hookSalt) = HookMiner.find(
            CREATE2_DEPLOYER, hookFlags, type(ArtCoinsHookSkimFee).creationCode, ctorArgs
        );
        ArtCoinsHookSkimFee hook = new ArtCoinsHookSkimFee{salt: hookSalt}(
            POOL_MANAGER, s.factory, s.poolExtAllowlist, WETH, s.escrow
        );
        require(address(hook) == minedHook, "Hook address mismatch");
        s.hook = address(hook);

        // 5. Lean LP locker — collect fees + escrow the currency received.
        //    Conversion now lives downstream in FeeAutoSwapper, so the locker
        //    no longer takes a Universal Router or pool manager. Binds to the
        //    new factory + new escrow; `feeLocker_` is the FeeEscrow (used for
        //    both the ERC20 `storeFees` and native `storeFeesNative` paths).
        ArtCoinsLpLocker locker =
            new ArtCoinsLpLocker(deployer, s.factory, s.escrow, POSITION_MANAGER, PERMIT2);
        s.locker = address(locker);

        // 6. MEV module (LinearSkim variant — the one ArtCoinsHookSkimFee
        //    expects per `_currentSkimBpsClamped` / `IArtCoinsMevSkim`).
        ArtCoinsMevLinearSkim mev = new ArtCoinsMevLinearSkim();
        s.mev = address(mev);

        // ─── wiring (deployer is the owner of factory + escrow at this
        // point because they were just constructed by the same EOA). ─────
        factory.setTeamFeeRecipient(deployer);
        factory.setDeployFee(0);
        factory.setHook(s.hook, true);
        factory.setLocker(s.locker, s.hook, true);
        factory.setMevModule(s.mev, true);
        escrow.addDepositor(s.locker);
        // The hook deposits the protocol fee leg into the escrow on EVERY swap
        // (`storeFeesNative`), which reverts for non-depositors. Without this
        // the first swap, and every swap after it, reverts and the pool bricks.
        escrow.addDepositor(s.hook);
        // PERMANENT COLLECTION converts artcoin-side LP fees downstream via a
        // FeeAutoSwapper reward recipient, which pays its own keeper reward.
        // Zero the locker-level keeper skim so the bounty isn't taxed twice.
        locker.setKeeperRewardBps(0);
    }

    function run() public returns (Stack memory s) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("=== artcoins v1 stack deploy ===");
        console2.log("chainId:           ", block.chainid);
        console2.log("deployer (owner):  ", deployer);
        console2.log("");

        vm.startBroadcast(pk);
        s = deployStack(deployer);
        vm.stopBroadcast();

        // Post-flight: sanity-check the wiring landed.
        ArtCoinsFactory factory = ArtCoinsFactory(payable(s.factory));
        require(factory.owner() == deployer, "post: factory owner");
        require(
            keccak256(bytes(factory.version())) == keccak256(bytes("1")),
            "post: factory version not 1"
        );
        require(factory.enabledHooks(s.hook), "post: hook not allowlisted");
        require(factory.enabledLockers(s.locker, s.hook), "post: locker not allowlisted");
        require(factory.enabledMevModules(s.mev), "post: mev not allowlisted");
        require(factory.teamFeeRecipient() == deployer, "post: teamFeeRecipient");
        require(factory.deployFee() == 0, "post: deployFee not 0");
        require(
            ArtCoinsFeeEscrow(s.escrow).allowedDepositors(s.locker), "post: locker not depositor"
        );
        require(
            ArtCoinsLpLocker(payable(s.locker)).keeperRewardBps() == 0,
            "post: keeperRewardBps not 0"
        );

        console2.log("=== DEPLOY V1 STACK DONE ===");
        console2.log("ARTCOINS_FACTORY:     ", s.factory);
        console2.log("ARTCOINS_FEE_ESCROW:  ", s.escrow);
        console2.log("ARTCOINS_POOL_EXT_AL: ", s.poolExtAllowlist);
        console2.log("ARTCOINS_HOOK_SKIM:   ", s.hook);
        console2.log("ARTCOINS_LOCKER:      ", s.locker);
        console2.log("ARTCOINS_MEV_SKIM:    ", s.mev);
        console2.log("");
        console2.log("Next: bump PC's Deploy.s.sol constants + submodule pin.");
    }
}
