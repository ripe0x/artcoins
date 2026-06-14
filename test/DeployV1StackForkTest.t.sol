// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsHookSkimFee} from "../src/hooks/ArtCoinsHookSkimFee.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsLpLocker} from "../src/lp-lockers/ArtCoinsLpLocker.sol";
import {ArtCoinsMevLinearSkim} from "../src/mev-modules/ArtCoinsMevLinearSkim.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Drives the full v1-stack deploy against a forked mainnet so a
///         broken broadcast is caught at PR time instead of on chain.
///         Inlines the deploy body from `script/DeployV1Stack.s.sol` because
///         `forge test` does NOT rewrite `new {salt:}` calls through the
///         canonical CREATE2_DEPLOYER proxy the way `forge script --broadcast`
///         does — instead the calling contract IS the CREATE2 deployer. So
///         the salt has to be mined against `address(this)` here, and the
///         mainnet script mines against the canonical proxy. The deploy
///         semantics are identical; only the deployer-address argument to
///         HookMiner differs. Keep this mirror in sync if `DeployV1Stack`
///         changes shape.
///
/// Usage:
///   forge test --match-contract DeployV1StackForkTest \
///     --skip "test/ArtCoinsHookSkimFeeUnit.t.sol" \
///     --skip "test/ArtCoinsHookSkimFeeForkTest.t.sol" \
///     --fork-url https://gateway.tenderly.co/public/mainnet -vv
contract DeployV1StackForkTest is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev Canonical mainnet artcoins owner (matches the prior v3 stack).
    address constant ARTCOINS_OWNER = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;

    function test_full_stack_deploys_and_wires() public {
        address creator = address(this);
        address deployer = ARTCOINS_OWNER;

        // 1. Factory + escrow + allowlist. Owner = deployer; the actual EVM
        //    `new()` is issued from the test contract.
        vm.prank(deployer);
        ArtCoinsFactory factory = new ArtCoinsFactory(deployer);
        vm.prank(deployer);
        ArtCoinsFeeEscrow escrow = new ArtCoinsFeeEscrow(deployer);
        vm.prank(deployer);
        ArtCoinsPoolExtensionAllowlist allowlist = new ArtCoinsPoolExtensionAllowlist(deployer);

        // 2. Mine hook salt against the TEST contract address (the CREATE2
        //    deployer in `forge test` mode).
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs =
            abi.encode(POOL_MANAGER, address(factory), address(allowlist), WETH, address(escrow));
        (address minedHook, bytes32 hookSalt) =
            HookMiner.find(creator, hookFlags, type(ArtCoinsHookSkimFee).creationCode, ctorArgs);
        ArtCoinsHookSkimFee hook = new ArtCoinsHookSkimFee{salt: hookSalt}(
            POOL_MANAGER, address(factory), address(allowlist), WETH, address(escrow)
        );
        require(address(hook) == minedHook, "Hook address mismatch");

        // 3. Locker + MEV.
        vm.prank(deployer);
        ArtCoinsLpLocker locker = new ArtCoinsLpLocker(
            deployer, address(factory), address(escrow), POSITION_MANAGER, PERMIT2
        );
        ArtCoinsMevLinearSkim mev = new ArtCoinsMevLinearSkim();

        // 4. Wiring. Owner-gated, so prank as deployer.
        vm.startPrank(deployer);
        factory.setTeamFeeRecipient(deployer);
        factory.setDeployFee(0);
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), address(hook), true);
        factory.setMevModule(address(mev), true);
        escrow.addDepositor(address(locker));
        escrow.addDepositor(address(hook));
        locker.setKeeperRewardBps(0);
        vm.stopPrank();

        // ── identity + version ────────────────────────────────────────────
        assertEq(factory.owner(), deployer, "factory.owner");
        assertEq(factory.version(), "1", "factory.version == 1");
        assertEq(escrow.owner(), deployer, "escrow.owner");
        // The hook MUST be an escrow depositor: it deposits the protocol fee
        // leg on every swap, and the escrow reverts for non-depositors, so a
        // missing depositor bricks all trading.
        assertTrue(
            escrow.allowedDepositors(address(hook)),
            "hook MUST be an escrow depositor (else every swap reverts)"
        );
        assertTrue(escrow.allowedDepositors(address(locker)), "locker is escrow depositor");
        assertEq(allowlist.owner(), deployer, "allowlist.owner");
        assertEq(locker.owner(), deployer, "locker.owner");
        assertEq(locker.factory(), address(factory), "locker.factory");
        assertEq(address(locker.feeLocker()), address(escrow), "locker.feeLocker == escrow");
        assertEq(locker.keeperRewardBps(), 0, "locker.keeperRewardBps zeroed");

        // ── hook permissions encoded in low-14 bits ──────────────────────
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            hookFlags & Hooks.ALL_HOOK_MASK,
            "hook low-14 bits encode permissions"
        );
        assertGt(address(hook).code.length, 0, "hook has code");
        assertEq(
            address(hook.poolExtensionAllowlist()),
            address(allowlist),
            "hook.poolExtensionAllowlist"
        );
        assertEq(address(hook.feeEscrow()), address(escrow), "hook.feeEscrow");
        assertEq(hook.factory(), address(factory), "hook.factory");

        // ── wiring ───────────────────────────────────────────────────────
        assertTrue(factory.enabledHooks(address(hook)), "factory.enabledHooks[hook]");
        assertTrue(
            factory.enabledLockers(address(locker), address(hook)),
            "factory.enabledLockers[locker][hook]"
        );
        assertTrue(factory.enabledMevModules(address(mev)), "factory.enabledMevModules[mev]");
        assertTrue(escrow.allowedDepositors(address(locker)), "escrow.allowedDepositors[locker]");
        assertEq(factory.teamFeeRecipient(), deployer, "factory.teamFeeRecipient");
        assertEq(factory.deployFee(), 0, "factory.deployFee == 0");

        console2.log("--- v1 stack (fork) ---");
        console2.log("factory:           ", address(factory));
        console2.log("escrow:            ", address(escrow));
        console2.log("poolExtAllowlist:  ", address(allowlist));
        console2.log("hook:              ", address(hook));
        console2.log("locker:            ", address(locker));
        console2.log("mev:               ", address(mev));
    }
}
