// Everything a token deployer controls (name, symbol, image, metadata, urls) is hostile input.
// These helpers are the single place that decides what the ui will render or fetch (UI-11, UI-21, UI-22).

export const IPFS_GATEWAY = 'https://ipfs.io/ipfs/';
export const ARWEAVE_GATEWAY = 'https://arweave.net/';

const MAX_URL_LENGTH = 2048;
/** inline data images are capped, a token cannot make every card download megabytes */
const MAX_DATA_IMAGE_LENGTH = 256 * 1024;
const DATA_IMAGE_RE = /^data:image\/(png|jpe?g|gif|webp|avif|svg\+xml)(;[a-z0-9=._+-]+)*(;base64)?,/i;

function hasCredentials(u: URL): boolean {
  return u.username !== '' || u.password !== '';
}

/**
 * Returns a url safe to put in `<img src>`, or null. Allowed schemes: `https:`, `ipfs:` and `ar:` (mapped to
 * a public gateway) and `data:image/`. Everything else (`http:`, `javascript:`, `blob:`, `file:`, bare
 * hosts) is refused. Render with `referrerPolicy="no-referrer"`.
 */
export function safeImageUrl(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const s = raw.trim();
  if (!s) return null;
  if (/^data:/i.test(s)) {
    if (s.length > MAX_DATA_IMAGE_LENGTH) return null;
    return DATA_IMAGE_RE.test(s) ? s : null;
  }
  if (s.length > MAX_URL_LENGTH) return null;
  const lower = s.toLowerCase();
  try {
    if (lower.startsWith('ipfs://')) {
      const path = s.slice('ipfs://'.length).replace(/^ipfs\//i, '');
      if (!/^[A-Za-z0-9][A-Za-z0-9._~\-/%]*$/.test(path)) return null;
      return IPFS_GATEWAY + path;
    }
    if (lower.startsWith('ar://')) {
      const path = s.slice('ar://'.length);
      if (!/^[A-Za-z0-9_-][A-Za-z0-9_./%-]*$/.test(path)) return null;
      return ARWEAVE_GATEWAY + path;
    }
    if (lower.startsWith('https://')) {
      const u = new URL(s);
      if (u.protocol !== 'https:' || hasCredentials(u)) return null;
      return u.toString();
    }
  } catch {
    return null;
  }
  return null;
}

/** An outbound link rendered from token metadata: https only, no credentials. */
export function safeLinkUrl(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const s = raw.trim();
  if (!s || s.length > MAX_URL_LENGTH) return null;
  try {
    const u = new URL(s);
    if (u.protocol !== 'https:' || hasCredentials(u)) return null;
    return u.toString();
  } catch {
    return null;
  }
}

// control characters, zero width and bidi override/isolate characters used for spoofing

// eslint-disable-next-line no-control-regex -- stripping control characters is the point
const UNSAFE_CHARS = new RegExp('[\\u0000-\\u001f\\u007f-\\u009f\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2069\\ufeff]', 'g');

/** Strips control and bidi characters and clamps the length. Names and symbols come from strangers. */
export function cleanText(raw: string | null | undefined, max: number): string {
  if (!raw) return '';
  const s = raw.replace(UNSAFE_CHARS, '');
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

export const MAX_NAME = 64;
export const MAX_SYMBOL = 16;
export const MAX_DESCRIPTION = 1000;

/** normalised key for duplicate / lookalike detection */
export function lookalikeKey(s: string): string {
  return s
    .normalize('NFKD')
    .replace(/[^\p{L}\p{N}]/gu, '')
    .toLowerCase();
}
