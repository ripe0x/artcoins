import { WebUploader } from '@irys/web-upload';
import { WebEthereum } from '@irys/web-upload-ethereum';
import { EthersV6Adapter } from '@irys/web-upload-ethereum-ethers-v6';
import { BrowserProvider } from 'ethers';
import type { WalletClient } from 'viem';

/**
 * Max size (in bytes) for Irys free-tier uploads. Files at or below this size
 * can be uploaded with only a wallet signature — no payment needed. Irys
 * permanently stores them on Arweave.
 *
 * (100 KiB = 102400 bytes)
 */
export const IRYS_FREE_TIER_BYTES = 100 * 1024;

/**
 * Build an ethers v6 BrowserProvider from a wagmi walletClient.
 */
function walletClientToEthersProvider(walletClient: WalletClient): BrowserProvider {
  const { chain, transport } = walletClient;
  if (!chain) throw new Error('Wallet client has no chain');
  const network = {
    chainId: chain.id,
    name: chain.name,
  };
  // viem's transport is an EIP-1193 compatible provider; ethers can wrap it.
  // Use ConstructorParameters (not Parameters) since BrowserProvider is a
  // class — `typeof BrowserProvider` is a constructor type, and only
  // ConstructorParameters can extract argument types from that.
  return new BrowserProvider(transport as unknown as ConstructorParameters<typeof BrowserProvider>[0], network);
}

export interface UploadResult {
  /** Arweave transaction ID (CID-like identifier). */
  id: string;
  /** Public HTTPS gateway URL — usable directly as an <img src>. */
  url: string;
  /** Size of the uploaded file in bytes. */
  size: number;
}

/**
 * Upload a file to Arweave via Irys using the connected wallet for signing.
 * For files ≤ 100 KiB, no payment is required — the wallet only signs a
 * message to prove ownership. Larger files require the user to have
 * pre-funded their Irys balance on a supported chain.
 *
 * @throws if the wallet is not connected, or if Irys upload fails.
 */
export async function uploadImageToArweave(
  file: File,
  walletClient: WalletClient
): Promise<UploadResult> {
  if (!walletClient) {
    throw new Error('Connect a wallet first to sign the upload.');
  }

  const provider = walletClientToEthersProvider(walletClient);

  // Build an Irys uploader bound to the user's wallet
  const uploader = await WebUploader(WebEthereum).withAdapter(EthersV6Adapter(provider));

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
  return {
    id,
    url: `https://arweave.net/${id}`,
    size: file.size,
  };
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
