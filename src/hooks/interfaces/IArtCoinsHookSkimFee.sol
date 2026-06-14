// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title  IArtCoinsHookSkimFee
/// @notice Three-leg per-swap split: bounty / protocol / referral. The bounty
///         leg is computed from gross volume × baseline skim × `bountyBps` and
///         is STRUCTURALLY invariant of any referral payment. Referral only
///         ever comes from the protocol slice and is clamped to whatever that
///         slice can fund this swap.
interface IArtCoinsHookSkimFee {
    error LpFeeTooHigh();
    error BaselineSkimBpsTooHigh();
    error BadLegBps();
    error BountyRecipientZero();
    error ProtocolRecipientZero();
    error ReferralPayoutZero();
    error QuoteTokenMismatch();
    error QuoteTokenMustBeNative();
    error MaxReferralTooHigh();
    error BidForwardFailed();
    // NotPoolManager is inherited from v4-periphery's ImmutableState via the
    // parent hook — no redeclaration here.

    struct SkimHookFeeData {
        uint24 baselineSkimBps;
        uint16 bountyBps;
        uint24 maxReferralBpsOfVolume;
        uint24 lpFee;
        address payable bountyRecipient;
        address payable protocolRecipient;
        address payable referralPayout;
        address quoteToken;
    }

    event SkimConfigInitialized(
        PoolId indexed poolId,
        uint24 baselineSkimBps,
        uint16 bountyBps,
        uint24 maxReferralBpsOfVolume,
        uint24 lpFee,
        address quoteToken
    );

    event SkimSplit(
        PoolId indexed poolId,
        uint256 quoteVolume,
        uint256 bountyAmount,
        uint256 protocolNet,
        uint256 referralPaid
    );

    event SwapAttribution(
        PoolId indexed poolId,
        address indexed swapper,
        address indexed referrer,
        bytes32 sourceId,
        bytes16 campaignId,
        uint256 quoteVolume,
        uint256 referralPaid
    );

    event ReferralUnderpaid(
        PoolId indexed poolId, address indexed referrer, uint256 requested, uint256 paid
    );

    event LegForwarded(PoolId indexed poolId, uint8 indexed leg, address recipient, uint256 amount);
    event ReferralForwarded(PoolId indexed poolId, address indexed referrer, uint256 amount);
    event ReferralFoldedToProtocol(PoolId indexed poolId, address indexed referrer, uint256 amount);
    event MaxReferralBpsUpdated(PoolId indexed poolId, uint24 newCap);

    function skimConfig(PoolId poolId)
        external
        view
        returns (
            uint24 baselineSkimBps,
            uint16 bountyBps,
            uint24 maxReferralBpsOfVolume,
            uint24 lpFee,
            address payable bountyRecipient,
            address payable protocolRecipient,
            address payable referralPayout,
            address quoteToken
        );

    /// @notice Whether the venue-scoped transfer-tax attestation path is active
    ///         for `poolId` (set at pool init; honored only on the blessed pool).
    function poolTaxEnabled(PoolId poolId) external view returns (bool);

    function accruedReferral(PoolId poolId, address referrer) external view returns (uint256);

    function setMaxReferralBpsOfVolume(PoolKey calldata poolKey, uint24 newCap) external;

    function MAX_SKIM_BPS() external view returns (uint24);
    function MAX_REFERRAL_CAP_OF_VOLUME() external view returns (uint24);
    function SKIM_DENOMINATOR() external view returns (uint256);
    function BPS_DENOMINATOR() external view returns (uint256);
}

struct PCSwapData {
    PCAttribution attribution;
    bytes extensionPayload;
}

struct PCAttribution {
    bytes32 sourceId;
    address referrer;
    bytes16 campaignId;
    uint24 referralBps;
}

interface IReferralPayoutForHook {
    function notify(address referrer) external payable;
}
