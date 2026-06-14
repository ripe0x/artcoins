// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchDefaults} from "../script/LaunchDefaults.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Locks down the LAYER recommended LP shape ("Preset L") so any
///         change to LaunchDefaults is caught here before reaching mainnet.
contract LayerPresetLDefaultTest is Test {
    /// @dev LAYER's actual launch starting tick. Matches LaunchLayer.s.sol.
    int24 constant LAYER_STARTING_TICK = -190_400;
    /// @dev LP allocation (1B − 260.2M burn − 100M airdrop).
    uint256 constant LP_ALLOCATION = 639_800_000e18;

    function test_buildsExactly12Positions() public pure {
        (int24[] memory tl, int24[] memory tu, uint16[] memory bps) =
            LaunchDefaults.buildLayerThinFloor12Positions(LAYER_STARTING_TICK);
        assertEq(tl.length, 12, "tickLower length");
        assertEq(tu.length, 12, "tickUpper length");
        assertEq(bps.length, 12, "bps length");
    }

    function test_bpsSumTo10000() public pure {
        (,, uint16[] memory bps) =
            LaunchDefaults.buildLayerThinFloor12Positions(LAYER_STARTING_TICK);
        uint256 sum;
        for (uint256 i = 0; i < bps.length; i++) {
            sum += bps[i];
        }
        assertEq(sum, 10_000, "bps must sum to 10000");
    }

    function test_layerAmountsSumToAllocation() public pure {
        (,, uint16[] memory bps) =
            LaunchDefaults.buildLayerThinFloor12Positions(LAYER_STARTING_TICK);
        uint256 layerSum;
        for (uint256 i = 0; i < bps.length; i++) {
            layerSum += (LP_ALLOCATION * bps[i]) / 10_000;
        }
        // Allow trivial integer-division dust.
        assertGe(layerSum, LP_ALLOCATION - 100);
        assertLe(layerSum, LP_ALLOCATION);
    }

    function test_positionsContiguousAndAligned() public pure {
        (int24[] memory tl, int24[] memory tu,) =
            LaunchDefaults.buildLayerThinFloor12Positions(LAYER_STARTING_TICK);
        for (uint256 i = 0; i < tl.length; i++) {
            assertEq(tl[i] % LaunchDefaults.TICK_SPACING, 0, "tickLower not aligned");
            assertEq(tu[i] % LaunchDefaults.TICK_SPACING, 0, "tickUpper not aligned");
            assertLt(tl[i], tu[i], "tickLower must be < tickUpper");
            if (i > 0) assertEq(tl[i], tu[i - 1], "positions must be contiguous");
        }
    }

    function test_boundariesMatchSpec() public pure {
        (int24[] memory tl, int24[] memory tu,) =
            LaunchDefaults.buildLayerThinFloor12Positions(LAYER_STARTING_TICK);
        // First tickLower at startingTick (offset 0).
        assertEq(tl[0], LAYER_STARTING_TICK, "first tickLower");
        // Last tickUpper at startingTick + 60000.
        assertEq(tu[11], LAYER_STARTING_TICK + 60_000, "last tickUpper");
        assertEq(tu[11], int24(-130_400), "last tickUpper absolute");
        assertEq(tu[11] - tl[0], int24(60_000), "total width");
    }

    function test_singleSided_noWethSeedNeeded() public pure {
        // Every position must start at or above the starting tick: this is
        // the single-sided-LAYER invariant that lets the launch ship with 0
        // WETH seed.
        (int24[] memory tl,,) = LaunchDefaults.buildLayerThinFloor12Positions(LAYER_STARTING_TICK);
        for (uint256 i = 0; i < tl.length; i++) {
            assertGe(tl[i], LAYER_STARTING_TICK, "position requires WETH seed");
        }
    }

    /// @dev Lock down the per-position bps weights so a future refactor of
    ///      LaunchDefaults can't quietly reshape the curve.
    function test_bpsWeightsExactly() public pure {
        (,, uint16[] memory bps) =
            LaunchDefaults.buildLayerThinFloor12Positions(LAYER_STARTING_TICK);
        uint16[12] memory expected = [
            uint16(50),
            uint16(150),
            uint16(300),
            uint16(500),
            uint16(800),
            uint16(1300),
            uint16(1700),
            uint16(1700),
            uint16(1300),
            uint16(1000),
            uint16(800),
            uint16(400)
        ];
        for (uint256 i = 0; i < 12; i++) {
            assertEq(bps[i], expected[i]);
        }
    }
}
