// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  Constants
/// @notice Single source of truth for every cap and bound shared by the
///         separately deployed artcoins v2 contracts. Each v2 contract exposes
///         `constantsHash()`; wiring checks reject a contract built against a
///         different set.
library Constants {
    /// @notice Stack version tag carried by the token, the hook pool record and the factory.
    uint16 internal constant STACK_VERSION = 2;

    // ── denominators ──────────────────────────────────────────────────────
    /// @notice Basis point denominator (10_000 = 100%). Skim and referral rates
    ///         and their caps are in BPS of volume.
    uint256 internal constant BPS = 10_000;
    /// @notice Uniswap v4 lp fee denominator (1_000_000 = 100%).
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    // ── hook and pool fee config (per pool fields are set at launch; the referral rate is hook wide) ──
    /// @notice Anti sniper skim ceiling, 90% of volume in BPS.
    uint24 internal constant MAX_SKIM_BPS = 9000;
    /// @notice Baseline skim ceiling, 10% of volume in BPS.
    uint24 internal constant MAX_BASELINE_SKIM_BPS = 1000;
    /// @notice Ceiling of the hook wide referral rate, 1% of volume in BPS.
    uint24 internal constant MAX_REFERRAL_CAP_OF_VOLUME = 100;
    /// @notice Initial hook wide referral rate, bps of volume (owner tunable, not hashed).
    uint24 internal constant REFERRAL_BPS_DEFAULT = 25;
    /// @notice Max bounty share of the skim, in BPS.
    uint16 internal constant MAX_BOUNTY_BPS = 9999;

    // ── fee push gas cap (not hashed) ─────────────────────────────────────
    /// @notice Gas forwarded on a controller fee push; a failed push falls back
    ///         to the escrow. The hook pushes with a zero gas call.
    uint32 internal constant PUSH_GAS_MAX = 150_000;

    // ── anti sniper window (module and hook agree) ────────────────────────
    /// @notice Window bounds. The hook treats any module as expired at
    ///         `createdAt + MAX_MEV_WINDOW` whatever the module reports.
    uint32 internal constant MIN_MEV_WINDOW = 1 minutes;
    uint32 internal constant DEFAULT_MEV_WINDOW = 69 minutes;
    uint32 internal constant MAX_MEV_WINDOW = 180 minutes;
    /// @notice Default starting skim, in BPS of volume.
    uint24 internal constant DEFAULT_START_SKIM_BPS = 6869;

    // ── locker ────────────────────────────────────────────────────────────
    /// @notice Max lp positions per coin.
    uint256 internal constant MAX_LP_POSITIONS = 14;

    // ── factory ───────────────────────────────────────────────────────────
    /// @notice Supply used when `TokenConfigV2.totalSupply == 0`.
    uint256 internal constant DEFAULT_TOKEN_SUPPLY = 1_000_000_000e18;
    uint256 internal constant MIN_TOKEN_SUPPLY = 1e18;
    /// @notice Launch extension limits.
    uint256 internal constant MAX_EXTENSIONS = 10;
    uint16 internal constant MAX_EXTENSION_BPS = 9000;
    /// @notice Max flat deploy fee.
    uint256 internal constant MAX_DEPLOY_FEE = 1 ether;

    // ── token restriction ────────────────────────────────────────────────
    /// @notice Max entries in a restricted coin's launch allowlist, bounding the
    ///         construction loop and the factory assembled set.
    uint256 internal constant MAX_ALLOWED = 64;
    /// @notice Burn sink.
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ── token strings ─────────────────────────────────────────────────────
    /// @notice String caps in bytes, enforced by the token at construction and
    ///         in every setter, and by the factory before deploying. Hashed.
    uint256 internal constant MAX_NAME_BYTES = 64;
    uint256 internal constant MAX_SYMBOL_BYTES = 16;
    uint256 internal constant MAX_IMAGE_BYTES = 2048;
    uint256 internal constant MAX_DESCRIPTION_BYTES = 4096;
    /// @notice `StringTooLong.field` codes.
    uint8 internal constant FIELD_NAME = 0;
    uint8 internal constant FIELD_SYMBOL = 1;
    uint8 internal constant FIELD_IMAGE = 2;
    uint8 internal constant FIELD_DESCRIPTION = 3;

    // ── burn router (not hashed) ──────────────────────────────────────────
    /// @notice Clamp on the lp fee read from the LAYER pool for the output floor, in pips.
    uint24 internal constant MAX_LP_FEE = 100_000;
    /// @notice Burn router initial output floor, in BPS of the spot output net
    ///         of the pool's buy fee (the spot and fee are read at burn time).
    ///         Owner tunable within [SPOT_FLOOR_MIN_BPS, SPOT_FLOOR_MAX_BPS].
    uint256 internal constant BURN_SPOT_FLOOR_BPS = 9000;
    uint256 internal constant SPOT_FLOOR_MIN_BPS = 5000;
    uint256 internal constant SPOT_FLOOR_MAX_BPS = 9500;
    /// @notice Burn router keeper reward: initial values and owner bounds. The
    ///         reward is a flat tip plus the burn's gas at the basefee, paid when
    ///         the basefee is at or under the gate, capped at a share of the weth
    ///         consumed.
    uint256 internal constant BURN_TIP_DEFAULT = 0.0003 ether;
    uint256 internal constant BURN_TIP_MAX = 0.01 ether;
    uint256 internal constant BURN_GAS_OVERHEAD_DEFAULT = 60_000;
    uint256 internal constant BURN_GAS_OVERHEAD_MAX = 300_000;
    uint256 internal constant BURN_BASEFEE_GATE_DEFAULT = 1 gwei;
    uint256 internal constant BURN_BASEFEE_GATE_MAX = 100 gwei;
    uint16 internal constant BURN_REWARD_BPS_DEFAULT = 1000;
    uint16 internal constant BURN_REWARD_BPS_MAX = 5000;
    /// @notice Per burn price impact bounds, in BPS.
    uint16 internal constant PRICE_IMPACT_MIN = 25;
    uint16 internal constant PRICE_IMPACT_DEFAULT = 100;
    uint16 internal constant PRICE_IMPACT_MAX = 300;

    // ── protocol fee controller (not hashed) ──────────────────────────────
    /// @notice Minimum shares of the protocol revenue split, in BPS.
    uint16 internal constant PFC_MIN_TREASURY_BPS = 1000;
    uint16 internal constant PFC_MIN_BURN_BPS = 1000;

    // ── renderers (not hashed) ────────────────────────────────────────────
    uint256 internal constant MAX_GLYPHS = 256;
    uint256 internal constant RENDER_GAS_BUDGET = 8_000_000;

    // ── informational (not hashed) ────────────────────────────────────────
    /// @notice `leg` codes in the hook `FeeDelivered` event.
    uint8 internal constant LEG_BOUNTY = 0;
    uint8 internal constant LEG_PROTOCOL = 1;
    uint8 internal constant LEG_REFERRAL = 2;

    /// @notice Hash of every value two separately deployed contracts must agree on.
    /// @dev    Single contract values (burn router, fee controller, renderer,
    ///         deploy fee bounds, push gas) and informational values are excluded.
    function hash() internal pure returns (bytes32) {
        return keccak256(abi.encode(_hashPool(), _hashLaunch()));
    }

    function _hashPool() private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                STACK_VERSION,
                BPS,
                FEE_DENOMINATOR,
                MAX_SKIM_BPS,
                MAX_BASELINE_SKIM_BPS,
                MAX_REFERRAL_CAP_OF_VOLUME,
                MAX_BOUNTY_BPS,
                MIN_MEV_WINDOW,
                DEFAULT_MEV_WINDOW,
                MAX_MEV_WINDOW,
                DEFAULT_START_SKIM_BPS
            )
        );
    }

    function _hashLaunch() private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MAX_LP_POSITIONS,
                DEFAULT_TOKEN_SUPPLY,
                MIN_TOKEN_SUPPLY,
                MAX_EXTENSIONS,
                MAX_EXTENSION_BPS,
                MAX_ALLOWED,
                DEAD,
                MAX_NAME_BYTES,
                MAX_SYMBOL_BYTES,
                MAX_IMAGE_BYTES,
                MAX_DESCRIPTION_BYTES
            )
        );
    }
}
