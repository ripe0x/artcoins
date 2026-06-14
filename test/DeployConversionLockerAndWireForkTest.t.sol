// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployConversionLockerAndWire} from "../script/DeployConversionLockerAndWire.s.sol";
import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsLpLocker} from "../src/lp-lockers/ArtCoinsLpLocker.sol";
import {Test} from "forge-std/Test.sol";

interface IHookAllowlistView2 {
    function poolExtensionAllowlist() external view returns (address);
}

/// @notice Fork proof for the PC path-B owner-ops script against the LIVE V3
///         stack. Inherits the script so its owner-gated helpers
///         (`deployAndWire`, `allowlistExt`) execute in this test's context —
///         that way `vm.startPrank(owner)` applies to the inner factory/escrow
///         calls (a separate script instance would make those calls as the
///         instance, not the owner, and revert).
///
///         Self-forks + fail-loud: never depends on `--fork-url`, and a missing
///         live stack FAILS instead of skip-passing.
contract DeployConversionLockerAndWireForkTest is Test, DeployConversionLockerAndWire {
    function setUp() public {
        string memory url =
            vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        try vm.envUint("FORK_BLOCK") returns (uint256 b) {
            vm.createSelectFork(url, b);
        } catch {
            vm.createSelectFork(url);
        }
        require(FACTORY.code.length > 0, "fork: live V3 factory missing");
        require(ESCROW.code.length > 0, "fork: live escrow missing");
        require(HOOK.code.length > 0, "fork: live hook missing");
    }

    /// Phase 1: deploy the conversion locker + the three owner wirings all land.
    function test_phase1_deploysAndWires() public {
        address owner = ArtCoinsFactory(payable(FACTORY)).owner();

        vm.startPrank(owner);
        address locker = deployAndWire(owner);
        vm.stopPrank();

        assertGt(locker.code.length, 0, "locker deployed");
        assertEq(ArtCoinsLpLocker(payable(locker)).owner(), owner, "locker owner = artcoins owner");
        assertEq(ArtCoinsLpLocker(payable(locker)).keeperRewardBps(), 0, "keeper skim zeroed");
        assertTrue(
            ArtCoinsFactory(payable(FACTORY)).enabledLockers(locker, HOOK), "setLocker took effect"
        );
        assertTrue(ArtCoinsFeeEscrow(ESCROW).allowedDepositors(locker), "addDepositor took effect");
        assertTrue(
            ArtCoinsFactory(payable(FACTORY)).enabledMevModules(MEV_LINEAR_FEES),
            "setMevModule took effect"
        );
    }

    /// run() must fail fast (before any broadcast) when ARTCOINS_OWNER isn't the
    /// real owner — so a wrong signer can't half-execute the wiring on mainnet.
    function test_phase1_run_revertsOnWrongOwner() public {
        vm.setEnv("ARTCOINS_OWNER", vm.toString(makeAddr("notTheOwner")));
        vm.expectRevert(bytes("ARTCOINS_OWNER != factory.owner()"));
        this.run();
    }

    /// Phase 3: allowlisting the PC extension on the hook's allowlist lands.
    function test_phase3_allowlistExtension() public {
        ArtCoinsPoolExtensionAllowlist allowlist =
            ArtCoinsPoolExtensionAllowlist(IHookAllowlistView2(HOOK).poolExtensionAllowlist());
        address alOwner = allowlist.owner();
        address ext = makeAddr("perSwapFeeExtension");
        assertFalse(allowlist.enabledExtensions(ext), "not enabled before");

        vm.startPrank(alOwner);
        allowlistExt(ext);
        vm.stopPrank();

        assertTrue(allowlist.enabledExtensions(ext), "enabled after");
    }
}
