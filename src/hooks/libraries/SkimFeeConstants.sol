// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  SkimFeeConstants
/// @notice Single source of truth for skim-fee ceilings shared across the
///         separately-deployed skim contracts (`ArtCoinsHookSkimFee`,
///         `ArtCoinsMevLinearSkim`, `SkimFeeInitLib`). These contracts do not
///         share storage or deploy together, so defining the ceiling here once
///         keeps them from silently diverging on an immutable launch surface.
///         The value inlines at compile time, so there is no bytecode or gas
///         cost versus an inline literal.
library SkimFeeConstants {
    /// @dev Absolute upper bound on the per-swap skim, in the 100k skim
    ///      denominator (90_000 = 90%). The MEV linear-decay module starts the
    ///      skim here and the hook clamps any module-reported value to it, so
    ///      both sides must agree on the ceiling.
    uint24 internal constant MAX_SKIM_BPS = 90_000;
}
