# script-js

Node/TS/Python utility scripts for operating the artcoins launcher: deploy
math, address syncing, on-chain scanning for the LiquidityLayer/`LAYER`
migration, airdrop-allowlist generation, and metadata-rendering QA. These
are operator tools run by hand from a terminal — none of them run in CI or
in the `ui/` app at runtime.

## Setup

```bash
cd script-js
npm install
```

Most scripts are plain ESM (`node some-script.mjs ...`). `build-allowlist.ts`
is TypeScript and is run with `npx tsx build-allowlist.ts ...`.
`build-ll-preview.py` is the one Python file — no dependencies beyond the
stdlib, run with `python3 build-ll-preview.py`.

## Scripts

| Script | What it does | How to run | Status |
|---|---|---|---|
| `sync-addresses.mjs` | Reads Foundry `broadcast/**/run-latest.json` artifacts and patches `MAINNET_ADDRESSES` / `SEPOLIA_ADDRESSES` (and `factoryDeploymentBlocks`) in `ui/src/lib/config.ts`; optionally updates a local `.env`. This is how deployed contract addresses get from a broadcast into the UI. | `node script-js/sync-addresses.mjs [--chain 1] [--dry-run]` (run from repo root) | live |
| `build-allowlist.ts` | Builds a merkle allowlist for `ArtCoinsAirdropV2` from a two-column `address,amount` CSV. Writes `ui/public/allowlists/<token-lowercase>.json` (root + per-address proofs) by default and prints the root to paste into the deploy/airdrop form. | `npx tsx script-js/build-allowlist.ts <input.csv> <token-address> [--out <path>]` | live |
| `compute-starting-tick.mjs` | Given a target FDV, supply, and ETH/USD price, computes the Uniswap V4 starting tick (`tickIfToken0IsArtCoins`) and previews the 4-position LP range preset from `script/LaunchDefaults.sol`. Pure math, no RPC calls. | `node script-js/compute-starting-tick.mjs --token 0x.. --weth 0x.. --fdv-usd 10000 --supply 1000000000 --eth-usd 3000` | live |
| `preview-claim-table.mjs` | Given an allowlist JSON plus a proposed `(totalSupply, allocationBps)`, simulates claim order and prints per-address claimable vs. shortfall, so you can sanity-check an airdrop allocation before deploying. | `node script-js/preview-claim-table.mjs <allowlist.json> <totalSupply> <allocationPct>` | live |
| `scan-liquidity-layer.mjs` | Scans Base mainnet for `Deposited` events on the `LiquidityLayerMigrationDeposit` contract (`0x6B19...4daC`) and aggregates per-recipient totals, writing `data/liquidity-layer-depositors.{csv,json}`. Source of the raw pro-rata migration snapshot. | `node script-js/scan-liquidity-layer.mjs [--rpc <url>]` (needs `viem`, resolves from `script-js/node_modules` now) | live (one-off per migration, re-run if the snapshot needs to be refreshed) |
| `decode-animation-url.mjs` | Decodes a `data:application/json;base64,...` `contractURI()` dump (as written by `PreviewLLAnimation.s.sol`) into a metadata JSON file plus the inlined `animation_url` HTML, so the on-chain SVG/canvas art can be opened directly in a browser. | `node script-js/decode-animation-url.mjs <input.uri.txt> <output.html>` | live |
| `fetch-token-uri.mjs` | Reads `contractURI()` off a deployed `ArtCoinsToken` on Sepolia via a raw `eth_call` (no `viem`/`ethers` dependency), decodes it, and dumps metadata JSON + animation HTML to `tmp/`. Also checks the animation HTML is self-contained (no external `<script src>` / `fetch()`). | `node script-js/fetch-token-uri.mjs <token-address>` (optionally set `RPC_URL`) | live |
| `decode-and-verify.mjs` | Same decode-and-self-containment-check as above, but reads the URI from a fixed path, `tmp/contract-uri.txt` — written by a specific Foundry script (`VerifyLLRenderer`) — and additionally loads the animation in Puppeteer and screenshots the canvas to `tmp/animation-50.png` after a 3s render. | `node script-js/decode-and-verify.mjs` (expects `tmp/contract-uri.txt` to already exist from that Foundry run) | historical one-off — tied to a specific `VerifyLLRenderer` run's output path |
| `build-ll-preview.py` | Builds a self-contained `tmp/ll-preview.html` embedding `data/ll/sketch.js` verbatim plus the Mona Lisa as a base64 data URI and synthetic trade data, so the LiquidityLayer canvas animation can be eyeballed in a browser without going through the contract + ScriptyBuilder on-chain storage pipeline. | `python3 script-js/build-ll-preview.py` | live (QA tool for `data/ll/sketch.js`) |
| `compress-mona.mjs` | Generates a grid of compressed Mona Lisa candidates (jpeg/webp/avif at various widths/qualities) with gas-cost estimates for on-chain `ScriptyStorageV2` storage, to pick the best size/quality tradeoff. Hardcodes a personal absolute default source path (`/Users/dd/Sites/liquidity-layer-node/web/monalisa.png`) — override with `--source`. | `node script-js/compress-mona.mjs [--source path/to/source.png]` | historical one-off — the winning candidate is already committed as `data/ll/mona.jpeg`; only rerun if re-deriving that asset from scratch |
| `scan-burns.mjs` | Base-chain scanner: reads `baseToken()`/`totalDeposited()`/balance off the `LiquidityLayerMigrationDeposit` contract and enumerates its `Burned` events from a hardcoded deploy block, to reconcile deposited vs. burned totals. | `node script-js/scan-burns.mjs` | historical one-off (hardcoded contract address + deploy block from one investigation) |
| `scan-token-burns.mjs` | Base-chain scanner: for a specific hardcoded `LAYER` token address, sums `Transfer` events to `0x...dEaD` and to `0x0` before a specific hardcoded block, to total up burns preceding a particular user burn event. Near-duplicate of `scan-token-zero-burns.mjs` / `scan-burns.mjs` from the same investigation. | `node script-js/scan-token-burns.mjs` | historical one-off |
| `scan-token-zero-burns.mjs` | Same investigation as `scan-token-burns.mjs`, narrowed to just `Transfer → 0x0` events, starting from a conservative fixed block instead of binary-searching the deploy block. | `node script-js/scan-token-zero-burns.mjs` | historical one-off |

The three Base burn-scanners (`scan-burns.mjs`, `scan-token-burns.mjs`,
`scan-token-zero-burns.mjs`) were written for one debugging session
(reconciling a specific LAYER-token burn on Base) and hardcode contract
addresses / block numbers from that session. Keep them as a record of how
the numbers were derived; don't extend them — write a fresh script for any
new investigation.

## `data/`

- **`ll-allowlist-final.json`** and **`ll-allowlist-100M.json`** — two
  merkle allowlists built from the same 16 LiquidityLayer depositors, built
  by `build-allowlist.ts` from different input CSVs, and they are **not**
  interchangeable:
  - `ll-allowlist-100M.json` (root `0x67e99df6795c55652274e25884dca33c9198a49c34f5854faab1fefb5e297239`)
    is built from `liquidity-layer-depositors-100M.csv`, whose amounts are
    each depositor's raw pro-rata share scaled up so the 16 entries sum to
    exactly 100,000,000 `LAYER`. This is the one actually referenced
    on-chain: `script/LaunchLLToken.s.sol` hardcodes its merkle root as
    `MERKLE_ROOT`, and documents it as "Final 16-entry post-window root
    with 100M-rounded pro-rata bonus."
  - `ll-allowlist-final.json` (root `0xe05e60d5a586e541e75b9ed09a6169cf2a59fc3eceea950ad402595ecc7eb647`)
    is built from `liquidity-layer-depositors.csv` (unrounded — the raw
    output of `scan-liquidity-layer.mjs`, summing to the actual amount
    deposited, not a round 100M). It is **not** referenced by any script or
    contract in this repo; kept as the record of the pre-rounding pro-rata
    numbers.
  - Both were kept (rather than deleting one) because the roots differ and
    the 100M version is a deliberate, documented adjustment of the raw one
    — not a stale duplicate.
- **`liquidity-layer-depositors.csv`** / **`.json`** — raw output of
  `scan-liquidity-layer.mjs`: each depositor's actual pro-rata amount from
  the Base migration contract. Source for `ll-allowlist-final.json`.
- **`liquidity-layer-depositors-100M.csv`** — the same 16 depositors with
  amounts scaled so the column sums to exactly 100,000,000 `LAYER`. Source
  for `ll-allowlist-100M.json` (the live one).
- **`ll/mona.jpeg`** — the chosen compressed Mona Lisa asset (winner of the
  `compress-mona.mjs` trials), read directly by
  `script/Deploy.s.sol` (`LL_MONA_PATH`, default
  `script-js/data/ll/mona.jpeg`) when deploying the LiquidityLayer stack.
  **Keep.**
- **`ll/history.v1.bin`** — historical Base-chain trade-bit data, read by
  `script/Deploy.s.sol` (`LL_HISTORY_PATH`, default
  `script-js/data/ll/history.v1.bin`) and referenced by
  `script/DeployLLOnchainRenderer.s.sol`. **Keep.**
- **`ll/sketch.js`** — the canvas animation source, embedded on-chain via
  ScriptyBuilder and previewable locally with `build-ll-preview.py`.
- **`ll/candidates/`**, **`ll/mona.webp`**, **`ll/sketch.js.b64`**,
  **`liquidity-layer-depositors.csv.bak`/`.preclose`** — deleted (see repo
  history). `candidates/` was ~19 image-compression trial outputs from
  `compress-mona.mjs` (the winner already lives at `ll/mona.jpeg`);
  `mona.webp` was an alternate-format export with zero references anywhere
  in the repo; `sketch.js.b64` was a derived base64 duplicate of the
  tracked `sketch.js`; the `.bak`/`.preclose` CSVs were working snapshots
  superseded by the committed CSVs above. `.gitignore` now excludes
  `script-js/data/**/candidates/`, `*.bak`, `*.preclose`, and `*.b64` so
  these classes of file don't get re-committed.
