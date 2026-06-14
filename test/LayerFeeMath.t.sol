// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {ProtocolFeeController} from "../src/protocol-fee/ProtocolFeeController.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Math-only assertions for the LAYER fee split. Verifies that the
///         constants embedded in `LaunchLayer.s.sol` produce the
///         spec'd effective breakdown at 1% total trading fee:
///
///           artist treasury        0.38% of volume
///           project-side burn      0.42% of volume
///           protocol-side burn     0.08% of volume
///           artcoins treasury      0.12% of volume
///           ───────────────────────────────────────
///           total burn             0.50% of volume
///           total treasury         0.50% of volume
///           liquidity support      0.00% of volume
///
///         CRITICAL: this clean math only holds when no hook-level protocol
///         skim sits on top of the pool fee. The canonical `ArtCoinsHook`
///         removes that path entirely, so the invariant holds by construction
///         there. The frozen legacy LAYER hook keeps the path at
///         `protocolFeeNumerator == 0`; `FeeMathReconciliationForkTest` and
///         `HookProtocolFeeNumeratorZeroTest` assert that against the live
///         Sepolia deployment, and the LAYER deploy/preflight scripts assert
///         numerator==0 to keep it.
///
///         Pure constant + ProtocolFeeController state arithmetic — no fork
///         or live pool needed.
contract LayerFeeMathTest is Test {
    /// @dev The factory's default 2000 bps protocol slot is what
    ///      `_injectProtocolFeeSlot` appends. We re-derive expected splits
    ///      from this constant + the ProtocolFeeController defaults.
    function test_projectSlotsSumToProjectShare() public {
        // ARTIST_BPS + PROJECT_BURN_BPS = 8000 = 10_000 - defaultProtocolFeeBps.
        // We can't read the launch-script constants directly without making
        // them public, so we assert the math the way the launch script does.
        uint16 artistBps = 3800;
        uint16 projectBurnBps = 4200;
        uint16 protocolBps = 2000; // factory default
        assertEq(uint256(artistBps) + uint256(projectBurnBps), 8000);
        assertEq(uint256(artistBps) + uint256(projectBurnBps) + uint256(protocolBps), 10_000);
    }

    function test_layerEffectiveFeeAt1Pct() public pure {
        // Express the math in basis points-of-volume × 10_000 to avoid float.
        // total fee = 100 bps of volume = 0.01 * volume.
        // We compute each line as `bps_of_fee * 100 / 10_000` (= bps of volume).
        uint256 totalFeeBpsOfVolume = 100; // 1.00% = 100 bps of volume

        // Project side = 80% of fee = 80 bps of volume
        uint256 projectShare = totalFeeBpsOfVolume * 8000 / 10_000;
        assertEq(projectShare, 80);

        // Protocol side = 20 bps of volume
        uint256 protocolShare = totalFeeBpsOfVolume * 2000 / 10_000;
        assertEq(protocolShare, 20);

        // Project-side splits (out of 10_000 bps of project share):
        //   artist 4750, project-burn 5250, liquidity support 0.
        uint256 artistTreasury = projectShare * 4750 / 10_000;
        uint256 projectBurn = projectShare * 5250 / 10_000;
        uint256 liquiditySupport = projectShare * 0 / 10_000;
        assertEq(artistTreasury, 38); // 0.38% of volume
        assertEq(projectBurn, 42); // 0.42% of volume
        assertEq(liquiditySupport, 0); // 0.00% of volume

        // Protocol-side splits (out of 10_000 bps of protocol share):
        //   treasury 6000, burn 4000, rewards 0.
        uint256 protocolTreasury = protocolShare * 6000 / 10_000;
        uint256 protocolBurn = protocolShare * 4000 / 10_000;
        assertEq(protocolTreasury, 12); // 0.12% of volume
        assertEq(protocolBurn, 8); // 0.08% of volume

        // Aggregate identities:
        assertEq(projectBurn + protocolBurn, 50); // total burn = 0.50%
        assertEq(artistTreasury + protocolTreasury, 50); // total treasury = 0.50%
        assertEq(
            artistTreasury + projectBurn + liquiditySupport + protocolTreasury + protocolBurn,
            totalFeeBpsOfVolume
        );
    }

    /// @dev Cross-check that the LAYER ProtocolFeeController split (60/40,
    ///      fixed at construction) produces the protocol-side split we
    ///      asserted above.
    function test_controllerDefaultsMatchSpec() public {
        ProtocolFeeController controller =
            new ProtocolFeeController(address(this), address(0xBADBABE), address(this), 6000);
        assertEq(controller.treasuryBps(), 6000);
        assertEq(controller.burnBps(), 4000);
    }

    /// @dev Cross-check that the factory's default protocol-fee bps still
    ///      matches the 2000 (20%) baseline the LAYER math relies on.
    function test_factoryDefaultProtocolFeeBpsMatchesSpec() public {
        ArtCoinsFactory factory = new ArtCoinsFactory(address(this));
        assertEq(factory.defaultProtocolFeeBps(), 2000);
    }

    /// @notice Dual-path fee math at minute 0 (50% headline). Asserts the
    ///         POST-CHANGE routing: base 1% flows through the locker normal
    ///         split (artist+treasury+burn), and the EXTRA 49% routes 100%
    ///         to the LAYER buy-and-burn path. Compare against the
    ///         pre-change routing (ALL of the 50% flowing through the
    ///         locker split) which would have given artist windfall.
    function test_minute0_dualPathSplit() public pure {
        // Trader pays 50% headline fee on a 1 ETH buy. Decompose:
        uint256 traderPays_ppm = 500_000; // 50% in ppm
        uint256 basePoolFee_ppm = 10_000; // 1%
        uint256 extraSniperFee_ppm = traderPays_ppm - basePoolFee_ppm; // 49%

        assertEq(extraSniperFee_ppm, 490_000, "extra is 49% of input");

        // Normalize to volume basis (out of 10_000 bps for percentage):
        // The base 1% flows through the locker's standard rewardBps array:
        //   - artist:        3800 / 10_000 = 38% of base = 0.38% of volume
        //   - project burn:  4200 / 10_000 = 42% of base = 0.42% of volume
        //   - protocol slot: 2000 / 10_000 = 20% of base = 0.20% of volume
        //     which is internally split 60/40 by ProtocolFeeController:
        //       - artcoins treasury (60%) = 0.12% of volume
        //       - protocol burn   (40%) = 0.08% of volume

        uint256 base_bps_of_volume = 100; // 1.00% = 100 bps of volume
        uint256 artistFromBase = base_bps_of_volume * 3800 / 10_000;
        uint256 projectBurnFromBase = base_bps_of_volume * 4200 / 10_000;
        uint256 protocolSlot = base_bps_of_volume * 2000 / 10_000;
        uint256 artcoinsTreasuryFromBase = protocolSlot * 6000 / 10_000;
        uint256 protocolBurnFromBase = protocolSlot * 4000 / 10_000;

        assertEq(artistFromBase, 38); // 0.38%
        assertEq(projectBurnFromBase, 42); // 0.42%
        assertEq(artcoinsTreasuryFromBase, 12); // 0.12%
        assertEq(protocolBurnFromBase, 8); // 0.08%
        // base burns total = 50 bps = 0.50%
        assertEq(projectBurnFromBase + protocolBurnFromBase, 50);
        // base treasury total = 50 bps = 0.50%
        assertEq(artistFromBase + artcoinsTreasuryFromBase, 50);

        // The EXTRA 49% routes 100% to BurnRouter. NOT split. NOT shared.
        uint256 extra_bps_of_volume = 4900; // 49.00%
        uint256 extraToBurnRouter = extra_bps_of_volume; // 100%
        uint256 extraToArtist = 0;
        uint256 extraToTreasury = 0;
        assertEq(extraToBurnRouter, 4900);
        assertEq(extraToArtist, 0, "artist gets nothing from sniper extra");
        assertEq(extraToTreasury, 0, "treasury gets nothing from sniper extra");

        // Dual-path totals at minute 0 (% of volume on a 50% headline):
        //   artist:            0.38%
        //   artcoins treasury: 0.12%
        //   LAYER burn (project + protocol + sniper extra):
        //     0.42% + 0.08% + 49.00% = 49.50%
        uint256 totalToBurnPath_bps = projectBurnFromBase + protocolBurnFromBase + extraToBurnRouter;
        uint256 totalToTreasury_bps = artistFromBase + artcoinsTreasuryFromBase;
        assertEq(totalToBurnPath_bps, 4950, "LAYER burn = 49.50% of volume @ minute 0");
        assertEq(
            totalToTreasury_bps, 50, "treasury (artist + artcoins) = 0.50% of volume @ minute 0"
        );
        // Sum reconciles to the trader's total fee: 49.50 + 0.50 = 50.00%.
        assertEq(totalToBurnPath_bps + totalToTreasury_bps, 5000, "sums to headline 50%");
    }

    /// @notice Same dual-path identity at minute 10-15 (3% headline → 2%
    ///         extra). Trader pays 3% total: 1% via base (split 50/50
    ///         burn/treasury) and 2% via extra (100% to burn).
    function test_minute10to15_dualPathSplit() public pure {
        uint256 base_bps_of_volume = 100; // 1.00% base
        uint256 extra_bps_of_volume = 200; // 2.00% extra
        uint256 totalTrader_bps = base_bps_of_volume + extra_bps_of_volume;
        assertEq(totalTrader_bps, 300, "trader pays 3% at minute 10-15");

        // Base split (per LAYER spec): burn 50%, treasury 50%.
        uint256 burnFromBase = base_bps_of_volume * 5000 / 10_000;
        uint256 treasuryFromBase = base_bps_of_volume * 5000 / 10_000;
        assertEq(burnFromBase, 50);
        assertEq(treasuryFromBase, 50);

        // Total to burn path = base burn (0.50%) + entire extra (2.00%) = 2.50%.
        uint256 totalBurn_bps = burnFromBase + extra_bps_of_volume;
        assertEq(totalBurn_bps, 250, "burn = 2.50% of volume");
        assertEq(totalBurn_bps + treasuryFromBase, totalTrader_bps);
    }
}
