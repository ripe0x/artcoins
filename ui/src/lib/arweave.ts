import { WebUploader } from '@irys/web-upload';
import { WebEthereum } from '@irys/web-upload-ethereum';
import { ViemV2Adapter } from '@irys/web-upload-ethereum-viem-v2';
import type { PublicClient, WalletClient } from 'viem';

/**
 * Max size (in bytes) for Irys free-tier uploads. Files at or below this size
 * can be uploaded with only a wallet signature — no payment needed. Irys
 * permanently stores them on Arweave.
 *
 * (100 KiB = 102400 bytes)
 */
export const IRYS_FREE_TIER_BYTES = 100 * 1024;

/**
 * Irys's own gateway. It resolves the same Arweave transaction id as
 * arweave.net but serves the item immediately after upload — arweave.net
 * itself can lag until the item propagates to it, which would otherwise
 * risk permanently recording a 404ing image URL on-chain (see
 * `uploadImageToArweave`'s verification step below).
 */
const IRYS_GATEWAY = 'https://gateway.irys.xyz';

/** Verification polling: attempts and spacing for confirming the gateway
 *  URL actually resolves before we hand it back to the caller. */
const VERIFY_MAX_ATTEMPTS = 5;
const VERIFY_INTERVAL_MS = 2000;

export interface UploadResult {
  /** Arweave transaction ID (CID-like identifier). */
  id: string;
  /** Public HTTPS gateway URL — usable directly as an <img src>. */
  url: string;
  /** Size of the uploaded file in bytes. */
  size: number;
}

/**
 * Poll `url` with HEAD requests until it resolves (HTTP ok), or give up.
 * Resolves as soon as one attempt succeeds; throws if none do within
 * `VERIFY_MAX_ATTEMPTS` tries.
 */
async function verifyGatewayUrl(url: string): Promise<void> {
  for (let attempt = 1; attempt <= VERIFY_MAX_ATTEMPTS; attempt++) {
    try {
      const res = await fetch(url, { method: 'HEAD' });
      if (res.ok) return;
    } catch {
      // Network error / not yet resolvable — fall through and retry.
    }
    if (attempt < VERIFY_MAX_ATTEMPTS) {
      await new Promise(resolve => setTimeout(resolve, VERIFY_INTERVAL_MS));
    }
  }
  throw new Error(
    `Upload succeeded, but the image isn't resolving yet at the gateway. Please try again in a minute.`
  );
}

/**
 * Upload a file to Arweave via Irys using the connected wallet for signing.
 * For files ≤ 100 KiB, no payment is required — the wallet only signs a
 * message to prove ownership. Larger files require the user to have
 * pre-funded their Irys balance on a supported chain.
 *
 * After the upload completes, the returned gateway URL is verified to
 * actually resolve (via a few polled HEAD requests) before this function
 * returns — callers should not use `receipt.id` to build a URL themselves
 * and skip this check, since an unverified URL may 404 for early viewers.
 *
 * @param onVerifying optional callback invoked once the upload itself has
 *   finished and verification polling begins, so UI can show a distinct
 *   "verifying" state.
 * @throws if the wallet is not connected, if Irys upload fails, or if the
 *   gateway URL fails to verify within the retry budget.
 */
export async function uploadImageToArweave(
  file: File,
  walletClient: WalletClient,
  publicClient: PublicClient,
  onVerifying?: () => void
): Promise<UploadResult> {
  if (!walletClient) {
    throw new Error('Connect a wallet first to sign the upload.');
  }
  if (!publicClient) {
    throw new Error('No RPC client available to sign the upload.');
  }

  // Build an Irys uploader bound to the user's wallet
  const uploader = await WebUploader(WebEthereum).withAdapter(
    ViemV2Adapter(walletClient, { publicClient })
  );

  // Determine the MIME type — Irys uses this as the Content-Type tag so
  // gateway responses come back with the right headers for image rendering.
  const contentType = file.type || guessMimeFromName(file.name);

  const tags = [{ name: 'Content-Type', value: contentType }];

  const buffer = new Uint8Array(await file.arrayBuffer());

  // Use `uploader.upload(buffer, { tags })` for raw data. Note: the Irys SDK
  // also supports `uploadFile()` but that API is node-only.
  //
  // The Irys SDK's TS types declare `upload(data: string | Buffer | Readable, ...)`,
  // a Node-oriented signature, but there is no `Buffer` in the browser. At
  // runtime `upload()` just forwards `data` through unchanged (see
  // @irys/upload-core's Irys.upload -> uploader.uploadData), so handing it a
  // Uint8Array works identically to a Buffer. Cast narrowly here rather than
  // converting the bytes, so the exact same Uint8Array is uploaded.
  const receipt = await uploader.upload(buffer as unknown as Buffer, { tags });

  const id = receipt.id;
  const url = `${IRYS_GATEWAY}/${id}`;

  onVerifying?.();
  await verifyGatewayUrl(url);

  return { id, url, size: file.size };
}

function guessMimeFromName(name: string): string {
  const ext = name.split('.').pop()?.toLowerCase() ?? '';
  switch (ext) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'svg':
      return 'image/svg+xml';
    default:
      return 'application/octet-stream';
  }
}
