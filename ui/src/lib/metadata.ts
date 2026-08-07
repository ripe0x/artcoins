export interface MetadataAttribute {
  trait_type?: string;
  value: string | number;
  display_type?: string;
}

export interface ParsedContractURI {
  name?: string;
  symbol?: string;
  description?: string;
  image?: string;
  external_url?: string;
  attributes?: MetadataAttribute[];
  [k: string]: unknown;
}

/**
 * Parse a contractURI / tokenURI string. Handles:
 *   - data:application/json;base64,<b64>
 *   - data:application/json,<url-encoded-json>
 *   - raw JSON string
 * Returns null if the input can't be parsed (e.g. an https URL pointing off-chain).
 */
export function parseContractURI(uri: string | undefined | null): ParsedContractURI | null {
  if (!uri) return null;
  try {
    if (uri.startsWith('data:application/json;base64,')) {
      const b64 = uri.slice('data:application/json;base64,'.length);
      // UTF-8-safe decode: bare `atob` maps each byte straight to a UTF-16
      // code unit, mangling any non-ASCII character in the on-chain JSON
      // (emoji, accented names, etc.). Decode to raw bytes first, then
      // interpret those bytes as UTF-8.
      const json =
        typeof atob === 'function'
          ? new TextDecoder().decode(Uint8Array.from(atob(b64), c => c.charCodeAt(0)))
          : Buffer.from(b64, 'base64').toString('utf-8');
      return JSON.parse(json) as ParsedContractURI;
    }
    if (uri.startsWith('data:application/json,')) {
      const raw = decodeURIComponent(uri.slice('data:application/json,'.length));
      return JSON.parse(raw) as ParsedContractURI;
    }
    if (uri.trim().startsWith('{')) {
      return JSON.parse(uri) as ParsedContractURI;
    }
  } catch {
    return null;
  }
  return null;
}

/**
 * Pick the best available image for a token.
 * Tries: contractURI.image → imageUrl → null
 */
export function resolveImage(contractURI: string | undefined, imageUrl: string | undefined): string | null {
  const parsed = parseContractURI(contractURI);
  if (parsed?.image) return parsed.image;
  if (imageUrl && imageUrl.length > 0) return imageUrl;
  return null;
}
