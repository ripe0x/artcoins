// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsHookSkimFee} from "../interfaces/IArtCoinsHookSkimFee.sol";
import {SkimFeeConstants} from "./SkimFeeConstants.sol";

/// @title  SkimFeeInitLib
/// @notice Extracts the per-pool `_initializeFeeData` validation chain of
///         `ArtCoinsHookSkimFee` into a separately-deployed library. The
///         caller `DELEGATECALL`s `validate` once per pool initialization —
///         a cold path — and writes the returned struct to its own storage.
/// @dev    Pure: no storage access. Solidity tags the function `external` so
///         the library is deployed as its own contract and the caller's
///         bytecode only carries the call/jump glue, not the ~25-line
///         validation chain. The runtime gas cost on the cold init path
///         goes up by ~1k for the delegatecall, which is operationally
///         negligible against pool-creation gas.
library SkimFeeInitLib {
    /// @dev Mirrors the constants defined on `ArtCoinsHookSkimFeeBase`. Kept
    ///      as `private constant` here so the library bytecode doesn't grow
    ///      with public getters; the values are tied to the hook's chosen
    ///      maxima and should NEVER drift from those.
    uint24 private constant MAX_LP_FEE = 100_000;
    uint24 private constant MAX_REFERRAL_CAP_OF_VOLUME = 1000;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Decodes + validates fee-init bytes and returns the parsed
    ///         struct. Caller is responsible for storing it.
    /// @param  feeData    Raw bytes from the factory's `poolData` argument.
    /// @param  currency0  `poolKey.currency0` (already-unwrapped address).
    /// @param  currency1  `poolKey.currency1` (already-unwrapped address).
    /// @return cfg        Validated `SkimHookFeeData`. Any invalid field
    ///                    reverts with the matching `IArtCoinsHookSkimFee`
    ///                    custom error — emitted from the calling contract's
    ///                    address because this is a delegatecall.
    function validate(bytes memory feeData, address currency0, address currency1)
        external
        pure
        returns (IArtCoinsHookSkimFee.SkimHookFeeData memory cfg)
    {
        cfg = abi.decode(feeData, (IArtCoinsHookSkimFee.SkimHookFeeData));

        if (cfg.lpFee > MAX_LP_FEE) revert IArtCoinsHookSkimFee.LpFeeTooHigh();
        if (cfg.baselineSkimBps > SkimFeeConstants.MAX_SKIM_BPS) {
            revert IArtCoinsHookSkimFee.BaselineSkimBpsTooHigh();
        }
        if (uint256(cfg.bountyBps) >= BPS_DENOMINATOR) {
            revert IArtCoinsHookSkimFee.BadLegBps();
        }
        if (cfg.maxReferralBpsOfVolume > MAX_REFERRAL_CAP_OF_VOLUME) {
            revert IArtCoinsHookSkimFee.MaxReferralTooHigh();
        }
        if (cfg.bountyRecipient == address(0)) {
            revert IArtCoinsHookSkimFee.BountyRecipientZero();
        }
        if (cfg.protocolRecipient == address(0)) {
            revert IArtCoinsHookSkimFee.ProtocolRecipientZero();
        }
        if (cfg.referralPayout == address(0)) {
            revert IArtCoinsHookSkimFee.ReferralPayoutZero();
        }
        if (cfg.quoteToken != currency0 && cfg.quoteToken != currency1) {
            revert IArtCoinsHookSkimFee.QuoteTokenMismatch();
        }
        if (cfg.quoteToken != address(0)) {
            revert IArtCoinsHookSkimFee.QuoteTokenMustBeNative();
        }
    }
}
