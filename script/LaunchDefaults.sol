// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";

/// @title LaunchDefaults
/// @notice Shared constants and helpers used by deploy scripts and tests so the
///         "art coin speculation" defaults are defined in exactly one place.
///
///         Defaults at a glance:
///           - Pool paired with WETH (ERC20), tickSpacing 200
///           - Buy / sell fee: 1% / 1% (10_000 in v4 hundredths-of-bps)
///           - Anti-sniper: linear 69% -> 1% over 69 minutes (matches the
///             ArtCoinsMevLinearFees defaults so an empty `mevModuleData`
///             yields the same schedule)
///           - LP shape: 4 contiguous, non-overlapping single-sided positions
///             expressed as offsets from `startingTick`:
///               P1 launch zone     [0,      16400)   1000 bps
///               P2 main growth     [16400,  75400)   6000 bps
///               P3 maturity        [75400,  89400)   2000 bps
///               P4 moon tail       [89400,  110400)  1000 bps
library LaunchDefaults {
    /// @notice Default pool tick spacing.
    int24 internal constant TICK_SPACING = 200;

    /// @notice 1% buy fee in v4 hundredths-of-bps (10_000 / 1_000_000 = 1%).
    uint24 internal constant BUY_FEE = 10_000;
    /// @notice 1% sell fee.
    uint24 internal constant SELL_FEE = 10_000;

    /// @notice Anti-sniper start fee — 69%.
    /// @dev Mirrors `ArtCoinsMevLinearFees.DEFAULT_STARTING_FEE`. We override
    ///      from the module's 99% default to the launch brief's 69%.
    uint24 internal constant ANTI_SNIPER_START_FEE = 690_000;
    /// @notice Anti-sniper end fee — 1%.
    uint24 internal constant ANTI_SNIPER_END_FEE = 10_000;
    /// @notice Anti-sniper duration — 69 minutes.
    uint32 internal constant ANTI_SNIPER_DURATION_SECONDS = 69 minutes;

    // ─── 4-position LP preset (offsets from startingTick) ───────────────

    int24 internal constant P1_LOWER_OFFSET = 0;
    int24 internal constant P1_UPPER_OFFSET = 16_400;
    uint16 internal constant P1_BPS = 1000;

    int24 internal constant P2_LOWER_OFFSET = 16_400;
    int24 internal constant P2_UPPER_OFFSET = 75_400;
    uint16 internal constant P2_BPS = 6000;

    int24 internal constant P3_LOWER_OFFSET = 75_400;
    int24 internal constant P3_UPPER_OFFSET = 89_400;
    uint16 internal constant P3_BPS = 2000;

    int24 internal constant P4_LOWER_OFFSET = 89_400;
    int24 internal constant P4_UPPER_OFFSET = 110_400;
    uint16 internal constant P4_BPS = 1000;

    error TickNotAlignedToSpacing(int24 tick, int24 spacing);

    /// @notice Build the 4-position preset arrays for a given starting tick.
    /// @dev Reverts if `startingTick` is not a multiple of `TICK_SPACING`. All
    ///      preset offsets are themselves multiples of 200, so the resulting
    ///      absolute ticks are guaranteed aligned.
    /// @param startingTick Pool starting tick (must be a multiple of 200).
    /// @return tickLower Array of tickLower values, in order P1..P4.
    /// @return tickUpper Array of tickUpper values, in order P1..P4.
    /// @return positionBps Position bps in order P1..P4 (sums to 10_000).
    function buildDefaultPositions(int24 startingTick)
        internal
        pure
        returns (int24[] memory tickLower, int24[] memory tickUpper, uint16[] memory positionBps)
    {
        if (startingTick % TICK_SPACING != 0) {
            revert TickNotAlignedToSpacing(startingTick, TICK_SPACING);
        }

        tickLower = new int24[](4);
        tickUpper = new int24[](4);
        positionBps = new uint16[](4);

        tickLower[0] = startingTick + P1_LOWER_OFFSET;
        tickUpper[0] = startingTick + P1_UPPER_OFFSET;
        positionBps[0] = P1_BPS;

        tickLower[1] = startingTick + P2_LOWER_OFFSET;
        tickUpper[1] = startingTick + P2_UPPER_OFFSET;
        positionBps[1] = P2_BPS;

        tickLower[2] = startingTick + P3_LOWER_OFFSET;
        tickUpper[2] = startingTick + P3_UPPER_OFFSET;
        positionBps[2] = P3_BPS;

        tickLower[3] = startingTick + P4_LOWER_OFFSET;
        tickUpper[3] = startingTick + P4_UPPER_OFFSET;
        positionBps[3] = P4_BPS;
    }

    /// @notice ABI-encoded `mevModuleData` for the linear MEV module that
    ///         pins start/end/duration to the 69% / 1% / 69min schedule.
    /// @dev `ArtCoinsMevLinearFees` already defaults to this exact schedule
    ///      when `mevModuleData == ""`, but a future module deploy could
    ///      change those constants. Scripts pass this payload explicitly so
    ///      the schedule is on-the-record at deploy time and is also
    ///      assertable in unit tests without a live module instance.
    function antiSniperData() internal pure returns (bytes memory) {
        return abi.encode(ANTI_SNIPER_START_FEE, ANTI_SNIPER_END_FEE, ANTI_SNIPER_DURATION_SECONDS);
    }

    // ─── LAYER stepped anti-sniper schedule ────────────────────────────────
    //   0–60s    50%  (500_000 ppm)
    //   60–180s  25%  (250_000 ppm)
    //   180–300s 15%  (150_000 ppm)
    //   300–600s 7%   ( 70_000 ppm)
    //   600–900s 3%   ( 30_000 ppm)
    //   900s+    disabled (normal pool fee resumes)

    // The stepped LAYER schedule is built directly in `LaunchLayer.s.sol`
    // (which imports `ArtCoinsMevSniperSteppedFees.Step` for type-checked
    // encoding) and the schedule entries are TOTAL trader-paid fees (the
    // module subtracts `basePpm` and signals only the extra):
    //   (60, 500_000), (120, 250_000), (120, 150_000), (300, 70_000), (300, 30_000)
    // basePpm = 10_000 (1%, matches BUY_FEE / SELL_FEE).

    // ─── 4-position LP presets ────────────────────────────────────────────
    //   baseline    [1000, 6000, 2000, 1000]   — original art-coin defaults
    //   recommended [2500, 4500, 2000, 1000]   — UI default for LAYER mainnet
    //   deeper      [3000, 4000, 2000, 1000]
    //   smoother    [2000, 4500, 2500, 1000]

    /// @notice Build position arrays for the "recommended" 4-position preset
    ///         (25/45/20/10), which is the LAYER mainnet default and the UI
    ///         default. Tick offsets unchanged from `buildDefaultPositions`.
    function buildRecommendedPositions(int24 startingTick)
        internal
        pure
        returns (int24[] memory tickLower, int24[] memory tickUpper, uint16[] memory positionBps)
    {
        if (startingTick % TICK_SPACING != 0) {
            revert TickNotAlignedToSpacing(startingTick, TICK_SPACING);
        }
        tickLower = new int24[](4);
        tickUpper = new int24[](4);
        positionBps = new uint16[](4);

        tickLower[0] = startingTick + P1_LOWER_OFFSET;
        tickUpper[0] = startingTick + P1_UPPER_OFFSET;
        positionBps[0] = 2500;

        tickLower[1] = startingTick + P2_LOWER_OFFSET;
        tickUpper[1] = startingTick + P2_UPPER_OFFSET;
        positionBps[1] = 4500;

        tickLower[2] = startingTick + P3_LOWER_OFFSET;
        tickUpper[2] = startingTick + P3_UPPER_OFFSET;
        positionBps[2] = 2000;

        tickLower[3] = startingTick + P4_LOWER_OFFSET;
        tickUpper[3] = startingTick + P4_UPPER_OFFSET;
        positionBps[3] = 1000;
    }

    // ─── LAYER recommended LP — 12-position thin-floor taper ──────────────
    //
    // Selected after extensive simulator iteration (see
    // test/LpPresetCompareTest.t.sol) as the safest LAYER launch shape:
    //
    //   First-buy capture (no anti-sniper):  62M LAYER for 0.5 ETH
    //   Wallet capture % of post-burn:        8.4%
    //   Cumulative @ 2 ETH:                  189M
    //   Cumulative @ 10 ETH:                 398M
    //   Exhaustion:                          ~184 ETH
    //
    // Compared to alternatives:
    //   - 4-position baseline:    397M @ 0.5 ETH (53.8% of supply) — unsafe
    //   - 6-position Preset G:    89M @ 0.5 ETH, no realistic ceiling
    //   - 12-position Preset K:   84M @ 0.5 ETH, 284 ETH exhaust
    //   - Single-position S3:     94M @ 0.5 ETH but mid-range buys 327M @ 2 ETH
    //
    // Total width: 60_000 ticks. With LAYER's STARTING_TICK = -190_400 →
    // positions span [-190_400, -130_400]. All ticks are multiples of 200.

    /// @notice Build the 12-position thin-floor taper preset for LAYER.
    /// @dev Tick offsets and bps weights:
    ///        i  offset range            bps   share of LP
    ///        0  [    0,   1_400)         50   0.5%   thin floor
    ///        1  [1_400,   3_400)        150   1.5%
    ///        2  [3_400,   6_000)        300   3.0%
    ///        3  [6_000,   9_400)        500   5.0%
    ///        4  [9_400,  14_000)        800   8.0%
    ///        5  [14_000, 19_400)       1300  13.0%
    ///        6  [19_400, 26_000)       1700  17.0%   main growth
    ///        7  [26_000, 33_000)       1700  17.0%
    ///        8  [33_000, 40_000)       1300  13.0%
    ///        9  [40_000, 47_000)       1000  10.0%
    ///       10  [47_000, 53_400)        800   8.0%   tail
    ///       11  [53_400, 60_000)        400   4.0%
    ///       sum                       10000  100.0%
    /// @param startingTick Pool starting tick (must be a multiple of 200).
    /// @return tickLower Array of 12 tickLower values.
    /// @return tickUpper Array of 12 tickUpper values.
    /// @return positionBps Position bps in order (sums to 10_000).
    function buildLayerThinFloor12Positions(int24 startingTick)
        internal
        pure
        returns (int24[] memory tickLower, int24[] memory tickUpper, uint16[] memory positionBps)
    {
        if (startingTick % TICK_SPACING != 0) {
            revert TickNotAlignedToSpacing(startingTick, TICK_SPACING);
        }

        tickLower = new int24[](12);
        tickUpper = new int24[](12);
        positionBps = new uint16[](12);

        int24[12] memory lo = [
            int24(0),
            int24(1400),
            int24(3400),
            int24(6000),
            int24(9400),
            int24(14_000),
            int24(19_400),
            int24(26_000),
            int24(33_000),
            int24(40_000),
            int24(47_000),
            int24(53_400)
        ];
        int24[12] memory hi = [
            int24(1400),
            int24(3400),
            int24(6000),
            int24(9400),
            int24(14_000),
            int24(19_400),
            int24(26_000),
            int24(33_000),
            int24(40_000),
            int24(47_000),
            int24(53_400),
            int24(60_000)
        ];
        uint16[12] memory bps = [
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
            tickLower[i] = startingTick + lo[i];
            tickUpper[i] = startingTick + hi[i];
            positionBps[i] = bps[i];
        }
    }
}
