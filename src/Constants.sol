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
    /// @notice Basis point denominator (10_000 = 100%). Skim and referral rates,
    ///         their caps, and the protocol floor are all in BPS of volume.
    uint256 internal constant BPS = 10_000;
    /// @notice Uniswap v4 lp fee denominator (1_000_000 = 100%).
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    // ── hook and pool fee config (frozen per pool, validated at init) ─────
    /// @notice Max lp fee, 10% in pips (1e6 units).
    uint24 internal constant MAX_LP_FEE = 100_000;
    /// @notice Anti sniper skim ceiling, 90% of volume in BPS.
    uint24 internal constant MAX_SKIM_BPS = 9000;
    /// @notice Baseline skim ceiling, 10% of volume in BPS.
    uint24 internal constant MAX_BASELINE_SKIM_BPS = 1000;
    /// @notice Referral cap ceiling, 1% of volume in BPS.
    uint24 internal constant MAX_REFERRAL_CAP_OF_VOLUME = 100;
    /// @notice Max bounty share of the skim, in BPS.
    uint16 internal constant MAX_BOUNTY_BPS = 9999;

    // ── fee push gas cap ──────────────────────────────────────────────────
    /// @notice Gas forwarded on a locker or controller fee push; a failed push
    ///         falls back to the escrow. The hook pushes with a zero gas call.
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
    /// @notice Max reward slots (project slots plus the protocol slot).
    uint256 internal constant MAX_REWARD_PARTICIPANTS = 7;
    /// @notice Max lp positions per coin.
    uint256 internal constant MAX_LP_POSITIONS = 14;
    /// @notice Owner bounds for the locker keeper reward.
    uint256 internal constant LOCKER_KEEPER_BPS_MAX = 200;
    uint256 internal constant LOCKER_KEEPER_CAP_MIN = 0.001 ether;
    uint256 internal constant LOCKER_KEEPER_CAP_MAX = 0.05 ether;
    /// @notice Initial locker keeper reward cap (not a setter bound, not hashed).
    uint256 internal constant LOCKER_KEEPER_CAP_DEFAULT = 0.01 ether;

    // ── factory ───────────────────────────────────────────────────────────
    /// @notice Supply used when `TokenConfigV2.totalSupply == 0`.
    uint256 internal constant DEFAULT_TOKEN_SUPPLY = 1_000_000_000e18;
    uint256 internal constant MIN_TOKEN_SUPPLY = 1e18;
    /// @notice Launch extension limits.
    uint256 internal constant MAX_EXTENSIONS = 10;
    uint16 internal constant MAX_EXTENSION_BPS = 9000;
    /// @notice Max protocol slot in the locker split, in BPS.
    uint16 internal constant MAX_PROTOCOL_FEE_BPS = 3000;
    /// @notice Max flat deploy fee.
    uint256 internal constant MAX_DEPLOY_FEE = 1 ether;

    // ── token restriction ────────────────────────────────────────────────
    /// @notice Max entries in a restricted coin's launch allowlist, bounding the
    ///         construction loop and the factory assembled set.
    uint256 internal constant MAX_ALLOWED = 64;
    /// @notice Burn sink.
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ── keepers, swapper, burn router ─────────────────────────────────────
    /// @notice Keeper reward on consumed amounts, capped.
    uint256 internal constant KEEPER_REWARD_BPS = 50;
    uint256 internal constant KEEPER_REWARD_CAP = 0.01 ether;
    /// @notice Burn router initial fee net spot floor, in BPS. The swapper's
    ///         convert floor default (9500) is contract local; both are owner
    ///         tunable within [SPOT_FLOOR_MIN_BPS, SPOT_FLOOR_MAX_BPS].
    uint256 internal constant BURN_SPOT_FLOOR_DEFAULT_BPS = 8000;
    uint256 internal constant SPOT_FLOOR_MIN_BPS = 5000;
    uint256 internal constant SPOT_FLOOR_MAX_BPS = 9500;
    /// @notice Fee swapper owner bounds.
    uint256 internal constant SWAPPER_SLIPPAGE_MIN = 50;
    uint256 internal constant SWAPPER_SLIPPAGE_MAX = 1000;
    uint256 internal constant SWAPPER_MIN_BLOCKS_MIN = 1;
    uint256 internal constant SWAPPER_MIN_BLOCKS_MAX = 50_400;
    /// @notice Per block price impact bounds, in BPS, for the swapper convert
    ///         and the burn router.
    uint16 internal constant PRICE_IMPACT_MIN = 25;
    uint16 internal constant PRICE_IMPACT_DEFAULT = 100;
    uint16 internal constant PRICE_IMPACT_MAX = 300;
    uint256 internal constant BURN_THRESHOLD_FLOOR = 0.001 ether;
    /// @notice Burn router per call eth cap bounds and default (not hashed).
    uint256 internal constant BURN_MAX_PER_CALL_MIN = 0.1 ether;
    uint256 internal constant BURN_MAX_PER_CALL_MAX = 100 ether;
    uint256 internal constant BURN_MAX_PER_CALL_DEFAULT = 5 ether;

    // ── protocol fee controller ───────────────────────────────────────────
    /// @notice Minimum shares of the protocol revenue split, in BPS.
    uint16 internal constant PFC_MIN_TREASURY_BPS = 4000;
    uint16 internal constant PFC_MIN_BURN_BPS = 1000;

    // ── renderers ─────────────────────────────────────────────────────────
    uint256 internal constant MAX_GLYPHS = 256;
    uint256 internal constant RENDER_GAS_BUDGET = 8_000_000;

    // ── informational (not hashed) ────────────────────────────────────────
    /// @notice `leg` codes in the hook `FeeDelivered` event.
    uint8 internal constant LEG_BOUNTY = 0;
    uint8 internal constant LEG_PROTOCOL = 1;
    uint8 internal constant LEG_REFERRAL = 2;

    /// @notice Hash of every value two separately deployed contracts must agree on.
    /// @dev    Single contract tunables (locker keeper, swapper, burn router,
    ///         fee controller, renderer, deploy fee bounds) and informational
    ///         values are excluded. `test/v2/ConstantsV2.t.sol` recomputes this
    ///         from literals, so an edit without a matching test update fails.
    function hash() internal pure returns (bytes32) {
        return keccak256(abi.encode(_hashPool(), _hashDelivery(), _hashLaunch(), _hashKeeper()));
    }

    function _hashPool() private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                STACK_VERSION,
                BPS,
                FEE_DENOMINATOR,
                MAX_LP_FEE,
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

    function _hashDelivery() private pure returns (bytes32) {
        return keccak256(abi.encode(PUSH_GAS_MAX));
    }

    function _hashLaunch() private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MAX_REWARD_PARTICIPANTS,
                MAX_LP_POSITIONS,
                DEFAULT_TOKEN_SUPPLY,
                MIN_TOKEN_SUPPLY,
                MAX_EXTENSIONS,
                MAX_EXTENSION_BPS,
                MAX_PROTOCOL_FEE_BPS,
                MAX_ALLOWED,
                DEAD
            )
        );
    }

    function _hashKeeper() private pure returns (bytes32) {
        return
            keccak256(abi.encode(KEEPER_REWARD_BPS, KEEPER_REWARD_CAP, BURN_SPOT_FLOOR_DEFAULT_BPS));
    }
}
