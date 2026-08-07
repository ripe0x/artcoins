# Site review — UI, indexer, storage, IA, and copy

Reviewed 2026-08-07. Scope: `ui/` (the site), its client-side indexer and
storage layers, `script-js/`, and the docs surrounding them. Findings are
ordered by severity within each section; references are `file:line` at the
commit this doc was added.

---

## 1. Broken right now (correctness)

### 1.1 The UI's hook ABI has drifted from the deployed contracts

`ui/src/lib/abi.ts` is hand-written and no longer matches `src/`:

- **`skimConfig` shape mismatch.** The contract returns **8** values
  (`src/hooks/ArtCoinsHookSkimFee.sol:142-156`). The UI ABI declares **9**
  outputs, including a `permanentCollection` field that exists nowhere in
  `src/` (`ui/src/lib/abi.ts:130-146`). viem cannot decode 8 words against a
  9-output ABI, so the read fails outright.
- **Wrong positional indices on top of that.** `ReferralsPage.tsx:118-131`
  casts the result to a 12-tuple and reads `referralPayout` at `[9]` and
  `maxReferralBps` at `[3]`. Even under the UI's own 9-output ABI those
  should be `[6]` and `[2]`; `[3]` is `lpFee`. Net effect: **the referrals
  page is dead** — balances never load, claim buttons never enable, and the
  displayed referral cap is the wrong number.
- **`hookAbi` is a union of two incompatible hook generations**
  (`abi.ts:119-175`). `newMaterialIsToken0`, `poolCreationTimestamp`,
  `newMaterialFee`, `pairedFee` exist only on the legacy hook
  (`src/hooks/legacy/ArtCoinsHookV2.sol`); the current base renamed the
  mapping to `artCoinIsToken0` (`src/hooks/ArtCoinsHook.sol:92`). Against a
  current hook, `newMaterialIsToken0` reverts, `TokenDetailPage.tsx:380`
  coerces the `undefined` to `false`, and a wrong `isToken0` flips
  `zeroForOne` in `swap.ts:158/208` — **quotes and swaps break silently**
  (they revert; funds are safe).

**Fix:** stop hand-writing ABIs. The contracts live in this repo — generate
ABIs from the Foundry artifacts (wagmi-cli `foundry` plugin, or a small
codegen script), delete the hand-rolled unions, and drop every positional
`as` cast so wagmi's ABI-inferred types catch this class of bug at compile
time. This is the single highest-leverage change in the whole review.

### 1.2 Mainnet is dark in the UI even though mainnet is live

- Every mainnet artcoins address in `ui/src/lib/config.ts:28-44` is
  `ZERO`, so mainnet users see "factory isn't deployed on this chain" —
  yet AGENTS.md says mainnet went live 2026-05-18, and `broadcast/` has
  chain-1 runs.
- `factoryDeploymentBlocks[1] = 0n` (`config.ts:78-81`). The day someone
  fills in the factory address without also setting the block, the event
  scanner will walk mainnet **from genesis** in 2,000-block batches
  (~11,500 sequential `eth_getLogs` calls per cold load).
- The empty-state copy compounds it: "Switch to Sepolia to see deployed
  tokens." (`TokensListPage.tsx:70`) is wrong advice on a live mainnet.
- AGENTS.md says "see README for the current addresses" — the README has
  no addresses section.
- Related: `script-js/sync-addresses.mjs` (the tool meant to fix exactly
  this) defaults to patching `../artcoins/src/lib/launcher/config.ts` —
  an external sibling app with a *richer* field schema (`feeLocker`,
  `poolExtAllowlist`, `burnExtension`, `llCounter`, …) than this repo's
  `ui/src/lib/config.ts`. Two config schemas have drifted; the in-repo one
  is the stale one.

**Fix:** run/point `sync-addresses` at this repo's config, fill mainnet
addresses + real deployment block, fix the empty-state copy, and add an
addresses table to the README (or delete the AGENTS.md pointer).

### 1.3 Fake transaction confirmation on the referrals page

`ReferralsPage.tsx:191-194, 211-214`: after `writeContractAsync` returns a
hash, a `setTimeout(1500)` marks the tx "Confirmed" and refetches balances.
Mainnet blocks are ~12s, so the UI claims confirmation while the tx is in
the mempool and refetches pre-tx state (the just-claimed balance still shows
as claimable). `useWaitForTransactionReceipt` is already called at line 175
— its result is simply ignored. `ClaimPage.tsx:170-190` does this correctly;
copy that pattern.

### 1.4 The deploy flow will submit invalid input on-chain

- The deploy button gates only on `!name || !symbol`
  (`ReviewAndDeploy.tsx:376`). Every address field is blind-cast:
  `tokenForm.admin` (line 97), `customPairedToken` (line 104 — `'' as
  Address` if "Custom" is selected and left empty), reward
  recipients/admins (136-137), vault/airdrop admins (157, 171), merkle root
  (172). No `isAddress` check anywhere; the user gets a raw revert or a
  viem encoding exception on the money path.
- RewardsForm renders red warnings for bad ticks/bps but nothing propagates
  to the deploy gate — step 2 can be invalid while step 6's button is
  enabled.
- **Supply truncation:** `Number(tokenForm.totalSupply)` →
  `BigInt(Math.floor(n))` (`ReviewAndDeploy.tsx:144-145`,
  `encode.ts:55-57`). Any supply above 2^53 silently deploys wrong. Should
  be `BigInt(tokenForm.totalSupply) * 10n ** 18n` with digit-string
  validation.

### 1.5 Smaller correctness bugs

- `ReferralsPage.tsx:256` divides bps by **1,000** instead of 10,000 when
  rendering the referral cap percentage (10× overstated) — moot until 1.1
  is fixed, but fix together.
- `resolveTickSpacing` falls back to `60` when no candidate matches the
  event's poolId (`pool.ts:62-70`); no caller checks, so the SwapWidget
  can quote/swap against a nonexistent pool. Return `null` and gate the
  widget.
- SwapWidget "quoting" spinner sticks forever if the input is cleared while
  a quote is in flight (`SwapWidget.tsx:140-151` early-return path never
  resets `quoting`).
- `AntiSniperForm.tsx:250` shows the descending-fee duration in raw seconds
  ("4140s") while the slider legend says "1 min / 180 min"; the linear
  variant correctly shows minutes.
- SwapWidget says "See the MEV panel above" (`SwapWidget.tsx:379`) but the
  panel renders *below* the widget (`TokenDetailPage.tsx:375-400`).
- "Deployer" row on the token page actually renders `event.tokenAdmin`, not
  the tx sender (`TokenDetailPage.tsx:431-434`).
- Max button in buy mode fills the entire ETH balance — guaranteed
  unaffordable tx, no gas headroom (`SwapWidget.tsx:391-400`).
- `metadata.ts:29` decodes base64 with `atob`, which mangles non-ASCII
  UTF-8 in on-chain JSON metadata.

---

## 2. Indexer architecture

The "indexer" is `ui/src/lib/events.ts`: a client-side, full-history
`eth_getLogs` scan of the factory, per visitor, per cold load.

- **No persistence, unbounded growth.** Sepolia is already ~400 sequential
  `getLogs` calls per visitor (from block 10,665,708), growing 3–4
  calls/day forever. The cache is memory-only (`staleTime: 60s`,
  `gcTime: 5min`) — a refresh repeats the whole scan. `TokenCreated`
  events are immutable; persisting `{lastScannedBlock, events[]}` per chain
  in localStorage reduces every subsequent visit to one incremental call.
- **Batch size contradicts its own comment.** `events.ts:30-32` notes
  public RPCs cap at 1,000 blocks, then sets `BATCH_SIZE = 2_000n`. Without
  `VITE_ALCHEMY_API_KEY` the app uses public transports, where the scan is
  rejected/rate-limited — and react-query's default `retry: 3` restarts the
  *entire* scan on any single failed batch (no per-batch resume).
- **Per-token pages re-run the full scan to find one token**
  (`TokenDetailPage.tsx:63-77`, `ReferralsPage.tsx:69-83`). `tokenAddress`
  is an indexed topic — filter on it, or use the factory's
  `tokenDeploymentInfo` view that's already in `abi.ts` but never called.
- **Un-debounced quoting.** The quoter is `simulateContract`-ed on every
  keystroke of the amount field (`SwapWidget.tsx:140-207`). Debounce
  ~300ms or move it into react-query for dedupe.
- **Longer term:** at any real token volume, move indexing off the client
  entirely (Ponder / subgraph / tiny worker writing a JSON snapshot the UI
  fetches). The localStorage cache is the cheap 90% solution until then.

What's already good: the batching pins `head` once (no moving-target
range), args are defensively checked, the bigint sort is correct, all three
consumers share the `['tokens', chainId]` query key (dedupe + instant
list→detail navigation), and `ReviewAndDeploy` invalidates it after deploy.

---

## 3. Storage layer

- **Arweave propagation race.** `arweave.ts:75` returns
  `https://arweave.net/${id}` immediately after an Irys upload; that URL is
  baked into the token's on-chain `image` at deploy. Irys data is served
  instantly from `gateway.irys.xyz` but can take a while to resolve on
  `arweave.net`, so fresh tokens can show a broken image. Verify the URL
  resolves before enabling deploy, or store the Irys gateway URL.
- **ethers v6 is a dependency for one adapter.** The only ethers import is
  `BrowserProvider` in `arweave.ts:4`, needed by
  `@irys/web-upload-ethereum-ethers-v6`. Irys ships a viem adapter —
  switching drops ~300 KB of bundle and the unsafe
  `transport as unknown as …` cast at `arweave.ts:27`.
- **`config.json` runtime editability is defeated by `force-cache`.**
  `useReferrer.ts:38` fetches `/config.json` with `cache: 'force-cache'`,
  so returning visitors may never see an updated `defaultReferrer` — the
  exact thing the runtime-config mechanism exists for. Use default caching
  or `no-cache`.
- The 1,000-character `_comment` in `ui/public/config.json` (including
  internal notes about payout routing) ships to every visitor's browser.
  Move the explanation to a README and trim the comment.

---

## 4. Frontend architecture & code health

- **Four different tx-submission patterns** across ReviewAndDeploy,
  ClaimPage, ReferralsPage, SwapWidget — including setState-during-render
  receipt handling (`ReviewAndDeploy.tsx:64-82`) and the fake timer (1.3).
  Extract one `useTxFlow` hook (submit → pending → confirming →
  confirmed/error + explorer link); it deletes ~150 lines and prevents this
  bug class recurring.
- **Copy-pasted helpers:** `explorerUrl` exists in 6 files; the
  revert-decoder skeleton in 2; the event-lookup + poolKey derivation block
  in 2 (make a `useTokenEvent(address)` hook); `inputClass`/`labelClass` in
  6 files (one already drifted); the image-with-fallback block in 3; `Row`
  in ReviewAndDeploy is a clone of `InfoRow`.
- **Positional multicall casts everywhere.** `TokenDetailPage.tsx:134-158`
  destructures `staticData?.[0..15]` by magic index with `as` casts — one
  inserted row silently mis-assigns seven fields. This exact pattern is
  what shipped bug 1.1. Named results or per-call `useReadContract` fixes
  it.
- **No ErrorBoundary; missing env = white screen.** `main.tsx:13-18` throws
  at module scope if `VITE_WALLETCONNECT_PROJECT_ID` is unset, and any page
  render error blanks the app.
- **Deploy form state is ephemeral** — a refresh discards a fully
  configured mainnet deploy (`DeployPage.tsx:64-108`). A localStorage draft
  is cheap insurance. Step cards also never mark complete/invalid.
- **URL params trusted:** `/tokens/foo` runs the full event scan before
  showing "not found"; ClaimPage fetches `/allowlists/foo.json`. Guard with
  `isAddress`.
- `useReferrer` monkey-patches `history.pushState/replaceState`
  (`useReferrer.ts:130-139`) inside a react-router app — `useSearchParams`
  gives the same reactivity without patching globals.
- Effect-based prop-sync with load-bearing missing deps in three form
  components (TokenConfigForm, ExtensionsForm, RewardsForm) — move
  defaulting to the parent or submit time (ReviewAndDeploy already
  re-defaults at lines 97/136-137/157/171).
- Dead code: `getStoredReferrer`/`clearStoredReferrer`,
  `feeUnitsToPercent`, several never-called ABI entries, unused
  `zeroAddress` export; dead assets `ui/src/assets/react.svg`, `vite.svg`,
  `hero.png` (referenced nowhere).
- Accessibility: zero `htmlFor`/`id` label associations across all forms;
  the Toggle is a bare button with color-only state; the modal lacks
  `role="dialog"`/focus trap (Escape + scroll-lock are handled, credit
  due); validity states are color-only.
- Layout nits: `<main>` on four pages but `<div>` on two (let Layout own
  it); max-width varies 3xl/4xl/5xl without a system; Header has no mobile
  treatment (~360px overflow); `grid-cols-2/3` form rows don't collapse on
  mobile; hardcoded `bg-[#0a0a0a]` and SVG hexes vs zinc/violet tokens
  elsewhere.

What's already good: clean minimal routing with a 404 catch-all;
TokensListPage covers all four fetch states; ClaimPage verifies the merkle
proof locally *and* against the on-chain root, with humane revert
decoding; SwapWidget's two-step Permit2 flow and quote-effect cancellation
are correct; `attribution.ts` and `swap.ts` document genuinely non-obvious
encoding gotchas; lib/ separation is real.

---

## 5. Information architecture & language

- **Two brands, no bridge.** The site is "NewMaterial Token Launcher"
  (`index.html:7`, Header, Footer, RainbowKit appName) but the repo,
  README, and Fee-flow page say "artcoins" ("Fee architecture — artcoins
  v1"). Pick one public name and apply it everywhere.
- **`/fee-flow` is a QA artifact in primary nav.** Its own header comment
  calls it a hardcoded "one-shot record" of a Sepolia rehearsal; the page
  title is "Sepolia rehearsal — fee flow"; it contains operator notes ("Do
  not change the position table without re-running the simulator") and
  stamps `new Date()` on a "snapshot" so it claims today's date on every
  visit. It also describes a *different fee model* than TokenDetailPage
  (`protocolFeeNumerator` locked at 0 vs a nonzero protocol split) with no
  reconciliation. Demote it to docs or a `/debug` route; if kept, move the
  ~400 lines of hardcoded data to a typed constants file and reuse the
  existing UI primitives instead of its private `ShortAddr`/`KV`/`FeeBox`.
- **Operator copy shown to end users.** The claim page's empty state tells
  visitors to "Generate it with `script-js/build-allowlist.ts` and place
  the resulting file in `ui/public/allowlists/`" (`ClaimPage.tsx:225-229`).
  The referrals intro is written for integrators and its "attribution
  hookData" link points at `/` where no such docs exist
  (`ReferralsPage.tsx:250-268`).
- **Raw error internals leak.** `writeError.message.slice(0, 500)` in a
  `<pre>` (`SwapWidget.tsx:526-528`), `.slice(0, 200)` raw
  (`ReviewAndDeploy.tsx:365-369`), `Reverted: ${name}` for unmapped cases.
  ClaimPage's `decodeClaimError` is the model — wrap swap/deploy errors the
  same way.
- **Jargon debt:** MEV is never expanded and the same step is called
  "Anti-Sniper / MEV Protection", "Anti-Sniper (MEV)", and "MEV
  Protection" in three places; "tick" and "hook" are never defined;
  "Flush held → ledger", "Accrued (in-tx, rare)", "admin swept" are
  internal-model words on user buttons/statuses; one concept is variously
  "LP Rewards" / "Rewards" / "Fee Distribution" / "LP Locker".
- **Consistency pass:** deploy flow is Title Case, detail/claim/referrals
  flow is sentence case; "Confirm in wallet…" exists in three variants
  (casing × ellipsis style); ASCII `->` vs `→`; back-link labels have four
  formats; "Completed / inactive" hedges. Footer's "Source on GitHub ↗"
  links to bare `https://github.com`.
- Route structure itself is good — nothing is URL-only, sub-pages nest
  under `/tokens/:address`, slugs are clean. Consider whether `/` should be
  the token list rather than the deploy form (the unused `hero.png`
  suggests a landing page was once planned), and link "head to the Deploy
  page" in the empty state.

---

## 6. Repo hygiene

- **`ui/README.md` is the stock Vite template.** Replace with real docs:
  required env (`VITE_WALLETCONNECT_PROJECT_ID`, recommended
  `VITE_ALCHEMY_API_KEY`), the `config.json` runtime-config mechanism, the
  allowlist publishing flow, dev/build commands.
- **`script-js/` needs a README and a cleanup:**
  - Committed working artifacts: `data/liquidity-layer-depositors.csv.bak`
    and `.csv.preclose`; `data/ll/candidates/` (~1.6 MB of one-time
    image-compression trials); `data/ll/sketch.js.b64` (derived duplicate
    of a tracked source); `data/ll/history.v1.bin` (undocumented binary);
    two Mona images with no note on which is canonical. Delete or document.
  - `package.json` declares only `puppeteer` + `sharp`, but six scripts
    import `viem` (and one `@openzeppelin/merkle-tree`) — they only run
    because comments say to invoke them from `ui/` to borrow its
    `node_modules`. Declare the deps or document the convention.
  - 14 scripts, three run conventions (repo root / from `ui/` / python3),
    several one-offs with personal-machine absolute paths
    (`compress-mona.mjs:20`). A short README table (script → purpose → how
    to run → live or historical) is the highest-leverage fix here.
  - `sync-addresses.mjs` should say explicitly that its default target is
    the sibling app, not this repo's UI.
- `ui/public/allowlists/liquidity-layer.json` is unreachable by the app
  (ClaimPage fetches `/<lowercased-token-address>.json` and this file's
  token is `0x…dEaD`) — a stale sample; remove or add a rename-on-launch
  note.
- Root README's site coverage is one sentence; it never mentions
  `script-js/` and (per 1.2) lacks the addresses AGENTS.md promises.
- `.gitignore` coverage is otherwise correct (verified); `ui/.env` is
  listed twice.

---

## 7. Suggested order of attack

1. **ABI codegen from Foundry artifacts + delete positional casts**
   (fixes 1.1, prevents recurrence; unblocks referrals + swap).
2. **Mainnet config**: addresses + real deployment block + empty-state
   copy + README addresses table (1.2).
3. **Deploy-flow validation + bigint supply** (1.4) — the money path.
4. **`useTxFlow` hook**; fix the fake confirmation (1.3) in the process.
5. **Persist the event index** in localStorage with incremental scans;
   `BATCH_SIZE ≤ 1000`; topic-filtered single-token lookup; debounce
   quotes (§2).
6. **IA/copy pass**: one brand, demote `/fee-flow`, humane error decoding
   everywhere, de-jargon user-facing strings, casing/ellipsis/arrow
   consistency, real GitHub link (§5).
7. **Hygiene**: real `ui/README`, `script-js/README` + junk deletion +
   declared deps, dead assets removed (§6).
8. Opportunistic: accessibility labels, ErrorBoundary, form draft
   persistence, Irys viem adapter, `config.json` cache mode.
