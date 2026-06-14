// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LaunchDefaults} from "../script/LaunchDefaults.sol";
import {ArtCoinsAirdrop} from "../src/extensions/ArtCoinsAirdrop.sol";
import {ArtCoinsMevLinearFees} from "../src/mev-modules/ArtCoinsMevLinearFees.sol";

/// @title LaunchDefaultsTest
/// @notice Verifies the launch-defaults brief in `script/LaunchDefaults.sol`.
///         Covers: tickSpacing 200, 1%/1% fees, 69%/1%/69min anti-sniper, and
///         the 4-position art-coin speculation preset (offsets, bps, contiguity,
///         alignment, single-sided constraint).
contract LaunchDefaultsTest is Test {
    /// @dev Same starting tick used by every launch script in this repo. Picked
    ///      so the LP defaults test exercises a realistic startingTick rather
    ///      than 0.
    int24 internal constant STARTING_TICK = -230_400;

    // ─── Pool defaults ──────────────────────────────────────────────────

    function test_tickSpacingIs200() public pure {
        assertEq(LaunchDefaults.TICK_SPACING, int24(200));
    }

    function test_buyFeeIs1Percent() public pure {
        // v4 hundredths-of-bps: 1% = 10_000 / 1_000_000.
        assertEq(LaunchDefaults.BUY_FEE, uint24(10_000));
    }

    function test_sellFeeIs1Percent() public pure {
        assertEq(LaunchDefaults.SELL_FEE, uint24(10_000));
    }

    // ─── Anti-sniper schedule ───────────────────────────────────────────

    function test_antiSniperStartIs69Percent() public pure {
        assertEq(LaunchDefaults.ANTI_SNIPER_START_FEE, uint24(690_000));
    }

    function test_antiSniperEndIs1Percent() public pure {
        assertEq(LaunchDefaults.ANTI_SNIPER_END_FEE, uint24(10_000));
    }

    function test_antiSniperDurationIs69Minutes() public pure {
        assertEq(LaunchDefaults.ANTI_SNIPER_DURATION_SECONDS, uint32(69 * 60));
        assertEq(LaunchDefaults.ANTI_SNIPER_DURATION_SECONDS, uint32(4140));
    }

    function test_antiSniperDataDecodes() public pure {
        bytes memory data = LaunchDefaults.antiSniperData();
        (uint24 startingFee, uint24 endingFee, uint32 duration) =
            abi.decode(data, (uint24, uint24, uint32));
        assertEq(startingFee, uint24(690_000));
        assertEq(endingFee, uint24(10_000));
        assertEq(duration, uint32(4140));
    }

    // ─── 4-position LP preset ───────────────────────────────────────────

    function test_presetExpands() public pure {
        (int24[] memory tl, int24[] memory tu, uint16[] memory bps) =
            LaunchDefaults.buildDefaultPositions(STARTING_TICK);

        assertEq(tl.length, 4, "exactly 4 positions");
        assertEq(tu.length, 4);
        assertEq(bps.length, 4);

        // Roles in order: launch zone / main growth / maturity / moon tail
        assertEq(bps[0], uint16(1000), "P1 launch zone bps");
        assertEq(bps[1], uint16(6000), "P2 main growth bps");
        assertEq(bps[2], uint16(2000), "P3 maturity bps");
        assertEq(bps[3], uint16(1000), "P4 moon tail bps");
    }

    function test_presetBpsSumTo10000() public pure {
        (,, uint16[] memory bps) = LaunchDefaults.buildDefaultPositions(STARTING_TICK);
        uint256 sum;
        for (uint256 i = 0; i < bps.length; i++) {
            sum += bps[i];
        }
        assertEq(sum, 10_000);
    }

    function test_presetExactBpsDistribution() public pure {
        (,, uint16[] memory bps) = LaunchDefaults.buildDefaultPositions(STARTING_TICK);
        // The brief's exact split — 10% / 60% / 20% / 10% — must not drift.
        uint16[4] memory expected = [uint16(1000), uint16(6000), uint16(2000), uint16(1000)];
        for (uint256 i = 0; i < 4; i++) {
            assertEq(bps[i], expected[i]);
        }
    }

    function test_presetTickRangesAreContiguousAndNonOverlapping() public pure {
        (int24[] memory tl, int24[] memory tu,) =
            LaunchDefaults.buildDefaultPositions(STARTING_TICK);
        for (uint256 i = 0; i < tl.length; i++) {
            assertLt(tl[i], tu[i], "tickLower < tickUpper");
        }
        for (uint256 i = 1; i < tl.length; i++) {
            assertEq(tl[i], tu[i - 1], "ranges are contiguous (no gap, no overlap)");
        }
    }

    function test_presetAllTicksMultipleOf200() public pure {
        (int24[] memory tl, int24[] memory tu,) =
            LaunchDefaults.buildDefaultPositions(STARTING_TICK);
        for (uint256 i = 0; i < tl.length; i++) {
            assertEq(tl[i] % 200, 0, "tickLower % 200 == 0");
            assertEq(tu[i] % 200, 0, "tickUpper % 200 == 0");
        }
    }

    function test_presetOffsetsAreMultiplesOf200() public pure {
        // Re-assert against the constants directly so a future refactor that
        // changes the offsets but forgets the alignment guarantee fails here.
        assertEq(LaunchDefaults.P1_LOWER_OFFSET % 200, 0);
        assertEq(LaunchDefaults.P1_UPPER_OFFSET % 200, 0);
        assertEq(LaunchDefaults.P2_LOWER_OFFSET % 200, 0);
        assertEq(LaunchDefaults.P2_UPPER_OFFSET % 200, 0);
        assertEq(LaunchDefaults.P3_LOWER_OFFSET % 200, 0);
        assertEq(LaunchDefaults.P3_UPPER_OFFSET % 200, 0);
        assertEq(LaunchDefaults.P4_LOWER_OFFSET % 200, 0);
        assertEq(LaunchDefaults.P4_UPPER_OFFSET % 200, 0);
    }

    function test_presetExactOffsetsMatchBrief() public pure {
        // Hard-code the exact offsets from the launch brief so a renamed
        // role/role-shuffle without offset change is still caught.
        assertEq(LaunchDefaults.P1_LOWER_OFFSET, int24(0));
        assertEq(LaunchDefaults.P1_UPPER_OFFSET, int24(16_400));
        assertEq(LaunchDefaults.P2_LOWER_OFFSET, int24(16_400));
        assertEq(LaunchDefaults.P2_UPPER_OFFSET, int24(75_400));
        assertEq(LaunchDefaults.P3_LOWER_OFFSET, int24(75_400));
        assertEq(LaunchDefaults.P3_UPPER_OFFSET, int24(89_400));
        assertEq(LaunchDefaults.P4_LOWER_OFFSET, int24(89_400));
        assertEq(LaunchDefaults.P4_UPPER_OFFSET, int24(110_400));
    }

    function test_presetSingleSided_lowerIsAtLeastStartingTick() public pure {
        (int24[] memory tl,,) = LaunchDefaults.buildDefaultPositions(STARTING_TICK);
        for (uint256 i = 0; i < tl.length; i++) {
            assertGe(tl[i], STARTING_TICK, "tickLower >= startingTick (single-sided)");
        }
        // The launch-zone position MUST start exactly at the starting tick;
        // anything higher would mean the very first buyer pays a price step.
        assertEq(tl[0], STARTING_TICK, "launch zone starts at startingTick");
    }

    function test_presetRevertsOnUnalignedStartingTick() public {
        // 200 doesn't divide 123, so this should revert with our alignment guard.
        // Call via an external wrapper so the revert is at a deeper call depth
        // than the cheatcode (otherwise expectRevert can't catch it).
        LaunchDefaultsExternal helper = new LaunchDefaultsExternal();
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchDefaults.TickNotAlignedToSpacing.selector, int24(123), int24(200)
            )
        );
        helper.buildDefaultPositions(int24(123));
    }

    // ─── Sort-order awareness for absolute ticks ────────────────────────

    /// @dev The factory accepts `tickIfToken0IsArtCoins`. The locker negates
    ///      ticks when WETH is token0. This test pins the convention so a
    ///      future refactor of the locker that flips the assumption fails
    ///      loudly here rather than silently inverting every launch's price.
    function test_startingTickConvention_isSortOrderAgnosticInput() public pure {
        // The 4-position preset is computed as offsets from the input tick,
        // not from `min(token, weth)`. So the *input* to buildDefaultPositions
        // is sort-agnostic: callers always pass "if my token were token0".
        int24 inputTick = -200_000;
        (int24[] memory tl,,) = LaunchDefaults.buildDefaultPositions(inputTick);
        assertEq(tl[0], inputTick);
        assertEq(tl[1], inputTick + 16_400);
        assertEq(tl[2], inputTick + 75_400);
        assertEq(tl[3], inputTick + 89_400);
    }
}

/// @dev External wrapper so expectRevert can catch reverts thrown from the
///      library — `vm.expectRevert` only fires for reverts at a deeper call
///      depth than the cheatcode, and a same-frame internal-library call
///      bypasses that.
contract LaunchDefaultsExternal {
    function buildDefaultPositions(int24 startingTick)
        external
        pure
        returns (int24[] memory, int24[] memory, uint16[] memory)
    {
        return LaunchDefaults.buildDefaultPositions(startingTick);
    }

    function buildRecommendedPositions(int24 startingTick)
        external
        pure
        returns (int24[] memory, int24[] memory, uint16[] memory)
    {
        return LaunchDefaults.buildRecommendedPositions(startingTick);
    }
}

/// @title LaunchDefaultsRecommendedPresetTest
/// @notice Asserts the "recommended" 4-position LP preset (25/45/20/10) used
///         by the LAYER mainnet launch and the UI default. Same tick offsets
///         as the legacy default preset; only the bps weights differ.
contract LaunchDefaultsRecommendedPresetTest is Test {
    int24 internal constant STARTING_TICK = -230_400;
    LaunchDefaultsExternal internal ext;

    function setUp() public {
        ext = new LaunchDefaultsExternal();
    }

    function test_recommendedBpsAre25_45_20_10() public pure {
        (,, uint16[] memory positionBps) = LaunchDefaults.buildRecommendedPositions(STARTING_TICK);
        assertEq(positionBps.length, 4);
        assertEq(positionBps[0], 2500);
        assertEq(positionBps[1], 4500);
        assertEq(positionBps[2], 2000);
        assertEq(positionBps[3], 1000);
    }

    function test_recommendedBpsSumTo10000() public pure {
        (,, uint16[] memory positionBps) = LaunchDefaults.buildRecommendedPositions(STARTING_TICK);
        uint256 sum;
        for (uint256 i = 0; i < positionBps.length; i++) {
            sum += positionBps[i];
        }
        assertEq(sum, 10_000);
    }

    function test_recommendedTickOffsetsMatchBrief() public pure {
        (int24[] memory tl, int24[] memory tu,) =
            LaunchDefaults.buildRecommendedPositions(STARTING_TICK);
        // Offsets from STARTING_TICK: [0, 16400], [16400, 75400], [75400, 89400], [89400, 110400]
        assertEq(tl[0], STARTING_TICK + 0);
        assertEq(tu[0], STARTING_TICK + 16_400);
        assertEq(tl[1], STARTING_TICK + 16_400);
        assertEq(tu[1], STARTING_TICK + 75_400);
        assertEq(tl[2], STARTING_TICK + 75_400);
        assertEq(tu[2], STARTING_TICK + 89_400);
        assertEq(tl[3], STARTING_TICK + 89_400);
        assertEq(tu[3], STARTING_TICK + 110_400);
    }

    function test_recommendedRangesAreContiguousAndNonOverlapping() public pure {
        (int24[] memory tl, int24[] memory tu,) =
            LaunchDefaults.buildRecommendedPositions(STARTING_TICK);
        for (uint256 i = 0; i < tl.length; i++) {
            // each range is well-formed
            assertLt(tl[i], tu[i]);
            // contiguous: each upper meets the next lower
            if (i + 1 < tl.length) assertEq(tu[i], tl[i + 1]);
        }
    }

    function test_recommendedAllTicksAlignedTo200() public pure {
        (int24[] memory tl, int24[] memory tu,) =
            LaunchDefaults.buildRecommendedPositions(STARTING_TICK);
        for (uint256 i = 0; i < tl.length; i++) {
            assertEq(tl[i] % 200, int24(0));
            assertEq(tu[i] % 200, int24(0));
        }
    }

    function test_recommendedSingleSided_lowerIsAtLeastStartingTick() public pure {
        (int24[] memory tl,,) = LaunchDefaults.buildRecommendedPositions(STARTING_TICK);
        for (uint256 i = 0; i < tl.length; i++) {
            assertGe(tl[i], STARTING_TICK);
        }
    }

    function test_recommendedRevertsOnUnalignedStartingTick() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchDefaults.TickNotAlignedToSpacing.selector, int24(-230_401), int24(200)
            )
        );
        ext.buildRecommendedPositions(int24(-230_401));
    }

    function test_recommendedWorksForNegativeAndPositiveStartingTicks() public pure {
        // negative starting tick (typical mainnet launch FDV)
        (int24[] memory tlNeg,,) = LaunchDefaults.buildRecommendedPositions(int24(-230_400));
        assertEq(tlNeg[0], int24(-230_400));
        // positive starting tick (paired with a stable that sorts as currency1)
        (int24[] memory tlPos,,) = LaunchDefaults.buildRecommendedPositions(int24(50_000));
        assertEq(tlPos[0], int24(50_000));
        assertEq(tlPos[3], int24(50_000 + 89_400));
    }
}

/// @title MevLinearFeesDefaultsTest
/// @notice Asserts the on-chain MEV module constants match the brief.
contract MevLinearFeesDefaultsTest is Test {
    ArtCoinsMevLinearFees internal mev;

    function setUp() public {
        mev = new ArtCoinsMevLinearFees();
    }

    function test_defaultStartingFeeIs69Percent() public view {
        assertEq(mev.DEFAULT_STARTING_FEE(), uint24(690_000));
    }

    function test_defaultEndingFeeIs1Percent() public view {
        assertEq(mev.DEFAULT_ENDING_FEE(), uint24(10_000));
    }

    function test_defaultDurationIs69Minutes() public view {
        assertEq(mev.DEFAULT_DURATION(), uint32(69 * 60));
    }
}

/// @title AirdropClaimsImmediatelyTest
/// @notice The launch-brief requires that migrated holders can claim the
///         instant the pool is live. The airdrop extension permits a zero
///         lockup; this test pins that behaviour so a future tightening of
///         the floor doesn't silently re-introduce a waiting period.
contract AirdropClaimsImmediatelyTest is Test {
    function test_airdropMinLockupIsZero() public {
        ArtCoinsAirdrop airdrop = new ArtCoinsAirdrop(address(this));
        assertEq(
            airdrop.MIN_LOCKUP_DURATION(),
            0,
            "MIN_LOCKUP_DURATION must stay at 0 so claims can open with the pool"
        );
    }
}

