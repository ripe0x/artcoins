/**
 * Encode `PCSwapData` attribution into the V4 hookData byte string the
 * artcoins skim-fee hook (`ArtCoinsHookSkimFee`) expects.
 *
 * # The encoding gotcha
 *
 * The hook decodes `swapData` as a **1-tuple struct**:
 *
 *   abi.decode(swapData, (PoolSwapData))
 *
 * where `PoolSwapData = { bytes mevModuleSwapData; bytes poolExtensionSwapData; }`.
 *
 * Solidity's ABI encoder for a single struct argument writes a 32-byte
 * pointer (offset) followed by the struct body. If callers (frontends,
 * routers, aggregators) instead pass a 2-tuple `(bytes mev, bytes inner)`
 * — i.e. `abi.encode(bytes(""), inner)` — the byte stream is off by 32
 * bytes of outer-offset and the hook's `abi.decode` silently throws,
 * which the multi-layer try/catch in `_decodeAttribution` interprets
 * as "no attribution." The swap completes; the referral path is
 * skipped. Hard to spot without tests because nothing reverts.
 *
 * This module is the one place that gets the encoding right.
 *
 * # The referral path
 *
 * The hook routes the referral leg according to:
 *
 *   referral = min(volume × min(att.referralBps, maxReferralBpsOfVolume) / 100_000,
 *                  protocolShare)
 *
 * where `maxReferralBpsOfVolume` is set at pool initialization (PC's
 * launch ships 250 = 0.25% of volume). For non-PC coins the cap is
 * whatever the launching script supplied. The referrer is credited
 * immediately for coins with `permanentCollection == address(0)` and
 * only after `pc.acquisitionCount() > 0` for coins that wire a PC.
 */

import { encodeAbiParameters, getAddress, isAddress, type Hex } from 'viem';

/** Default referral bps requested by the UI (in 100k-denom; 250 = 0.25%
 *  of volume). The hook clamps against the per-pool
 *  `maxReferralBpsOfVolume` cap so this is just a "request whatever the
 *  hook allows" default. */
export const DEFAULT_REFERRAL_BPS_OF_VOLUME = 250;

const POOL_SWAP_DATA_ABI = [
  {
    type: 'tuple',
    components: [
      { name: 'mevModuleSwapData', type: 'bytes' },
      { name: 'poolExtensionSwapData', type: 'bytes' },
    ],
  },
] as const;

const PC_SWAP_DATA_ABI = [
  {
    type: 'tuple',
    components: [
      {
        name: 'attribution',
        type: 'tuple',
        components: [
          { name: 'sourceId', type: 'bytes32' },
          { name: 'referrer', type: 'address' },
          { name: 'campaignId', type: 'bytes16' },
          { name: 'referralBps', type: 'uint24' },
        ],
      },
      { name: 'extensionPayload', type: 'bytes' },
    ],
  },
] as const;

export interface AttributionArgs {
  sourceId?: Hex;
  referrer?: `0x${string}`;
  campaignId?: Hex;
  referralBpsOfVolume?: number;
}

const ZERO_BYTES32: Hex = '0x0000000000000000000000000000000000000000000000000000000000000000';
const ZERO_BYTES16: Hex = '0x00000000000000000000000000000000';
const ZERO_ADDRESS: `0x${string}` = '0x0000000000000000000000000000000000000000';

function encodePCSwapData(args: AttributionArgs): Hex {
  const referrerNorm: `0x${string}` =
    args.referrer && isAddress(args.referrer, { strict: false })
      ? getAddress(args.referrer)
      : ZERO_ADDRESS;
  return encodeAbiParameters(PC_SWAP_DATA_ABI, [
    {
      attribution: {
        sourceId: args.sourceId ?? ZERO_BYTES32,
        referrer: referrerNorm,
        campaignId: args.campaignId ?? ZERO_BYTES16,
        referralBps: args.referralBpsOfVolume ?? DEFAULT_REFERRAL_BPS_OF_VOLUME,
      },
      extensionPayload: '0x',
    },
  ]);
}

/**
 * Build the full `hookData` to pass into a V4 swap routed through
 * `ArtCoinsHookSkimFee`. The encoding is a single-argument
 * `PoolSwapData` struct (1-tuple).
 *
 * Pass the result as `hookData` on the swap call. If no attribution is
 * needed, pass `'0x'` instead of calling this function.
 */
export function encodeAttributionHookData(args: AttributionArgs): Hex {
  const inner = encodePCSwapData(args);
  return encodeAbiParameters(POOL_SWAP_DATA_ABI, [
    {
      mevModuleSwapData: '0x',
      poolExtensionSwapData: inner,
    },
  ]);
}

export function hasAnyAttribution(args: AttributionArgs): boolean {
  if (
    args.referrer &&
    args.referrer !== ZERO_ADDRESS &&
    isAddress(args.referrer, { strict: false })
  ) {
    return true;
  }
  if (args.sourceId && args.sourceId !== ZERO_BYTES32) return true;
  if (args.campaignId && args.campaignId !== ZERO_BYTES16) return true;
  return false;
}
