# ui/public/allowlists/

Airdrop merkle allowlists, served as static assets. `ClaimPage`
(`ui/src/pages/ClaimPage.tsx`) fetches exactly one path here:

```
/allowlists/<lowercased-token-address>.json
```

e.g. token `0xABC...` → `/allowlists/0xabc....json`. Any other filename in
this directory is unreachable by the app — it's dead weight, not a
fallback.

Generate a file for a token with `script-js/build-allowlist.ts` (see
`script-js/README.md`), which writes to this naming convention by default.
Each file contains the merkle root plus every address's amount and proof —
this is intentionally public data; a valid proof can be recomputed from
the on-chain root by anyone anyway.

`liquidity-layer.json` (a sample built around the placeholder
`0x...dEaD` token address) was removed for exactly this reason — it can
never match a real token address, so `ClaimPage` could never fetch it.
