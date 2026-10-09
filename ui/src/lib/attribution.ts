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
 *   referral = min(volume × min(att.referralBps, maxReferralBpsOfVolume) / 10_000,
 *                  protocolShare)
 *
 * where `maxReferralBpsOfVolume` is set at pool initialization (PC's
 * launch ships 25 = 0.25% of volume). For non-PC coins the cap is
 * whatever the launching script supplied. The referrer is credited
 * immediately for coins with `permanentCollection == address(0)` and
 * only after `pc.acquisitionCount() > 0` for coins that wire a PC.
 */

import { encodeAbiParameters, getAddress, isAddress, type Hex } from 'viem';

/** Default referral bps requested by the UI (bps of volume; 25 = 0.25%). The hook clamps against the per-pool
 *  `maxReferralBpsOfVolume` cap so this is just a "request whatever the
 *  hook allows" default. */
export const DEFAULT_REFERRAL_BPS_OF_VOLUME = 25;

/** The v1 hook reads `referralBps` out of 100_000, so the same 0.25% default is 250 there. */
export const V1_DEFAULT_REFERRAL_OF_VOLUME = 250;

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

export interface SwapHookDataArgs extends AttributionArgs {
  /**
   * Refund address for a price limited swap's unfilled skim (D58, residual V2H-03). Goes into
   * `mevModuleSwapData = abi.encode(address)` (exactly 32 bytes), which `HookCalldata.refundTo` reads.
   * Without it the refund is credited in the escrow to the PoolManager caller, and for a universal
   * router swap that is the router: stranded. Every swap sent through a v2 hook must name one.
   * Leave undefined for a v1 hook (it does not read it).
   */
  refundTo?: `0x${string}`;
}

/**
 * hookData for a swap through the v2 hook: `abi.encode(PoolSwapData{mevModuleSwapData, poolExtensionSwapData})`.
 * `mevModuleSwapData` carries the refund address, `poolExtensionSwapData` the attribution (empty when there is
 * none). Returns '0x' when there is neither a refund address nor an attribution.
 */
export function encodeSwapHookData(args: SwapHookDataArgs): Hex {
  const refund =
    args.refundTo && isAddress(args.refundTo, { strict: false }) && getAddress(args.refundTo) !== ZERO_ADDRESS
      ? getAddress(args.refundTo)
      : null;
  const attributed = hasAnyAttribution(args);
  if (!refund && !attributed) return '0x';
  return encodeAbiParameters(POOL_SWAP_DATA_ABI, [
    {
      mevModuleSwapData: refund ? encodeAbiParameters([{ type: 'address' }], [refund]) : '0x',
      poolExtensionSwapData: attributed ? encodePCSwapData(args) : '0x',
    },
  ]);
}
