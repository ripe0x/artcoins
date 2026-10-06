# ui review (ui/ website)

scope: all of `ui/` (src, public, package.json, lockfile, .env.example) against `src/ArtCoinsFactory.sol`, `IArtCoinsFactory.sol`, hooks, locker, mev modules, extensions, token. read only. live checks with `cast call` against the tenderly gateway on 2026-10-06. paths below are relative to `ui/` unless they start with `src/`.

## bottom line

the ui is a stale fork of an older "NewMaterial" launcher. it cannot deploy, sell, or read pools on any live factory, and on mainnet it has no factory address at all. nearly every failure is a safe revert, but there are two paths that can lose real money (eth sent to the zero address, wrong direction swaps) and several trust signals that mislead users. do not ship it to mainnet as is. it also fails `tsc -b`, so `npm run build` does not produce an artifact from a clean checkout.

| check | result |
|---|---|
| `npm ci` | ok, 899 packages |
| `npm run build` | fails at `tsc -b`, 5 errors (arweave.ts x2, ReferralsPage.tsx x2, FeeFlowPage.tsx x1) |
| `vite build` alone | ok, 4.7s, one 500kB+ chunk warning, direct `eval` in vm-browserify polyfill |
| `eslint .` | 1 error (FeeFlowPage unused var), 3 exhaustive-deps warnings |
| `npm audit` | 72 advisories, 18 high, 0 critical. mostly transitive, node only or dev only (see UI-18) |
| ci | no workflow builds or lints `ui/` (.github/workflows has only test.yml and mirror.yml) |

## ranked findings

severity: high = funds at risk or flow fully dead on the supported target; medium = misleading trust signal, unsafe default, or major breakage in a secondary flow; low = hardening; info = context.

| id | sev | title | evidence | fix |
|---|---|---|---|---|
| UI-01 | high | mainnet addresses are all zero, deploy is not gated, eth can be sent to 0x0 | src/lib/config.ts:28-45 (factory, hook, locker, mev, vault, airdrop, devBuy, stateView, quoter all ZERO); components/ReviewAndDeploy.tsx:234-240 writes to `addresses.factory` with no zero check; value = dev buy eth (line 197) | gate every write on nonzero factory and chain in {1}; disable button otherwise; simulate before send. throw on zero in `getAddresses` consumers |
| UI-02 | high | unknown chain falls back to sepolia addresses | src/lib/config.ts:71 `addressMap[chainId] ?? SEPOLIA_ADDRESSES` | return undefined for unsupported chains, show "switch network" and block writes. likely reachable because wagmi `useChainId` can report the wallet chain (unverified at runtime) |
| UI-03 | high | stale `deployToken` abi: wrong selector, deploy reverts on every live factory | src/lib/abi.ts:4-55: TokenConfig lacks `renderer` (after totalSupply, line 17), DeploymentConfig lacks `sniperFeeConfig`. ui selector `0xdf40224a`, live selector `0x3f1638ea`; bytecode of 0x4959 and 0xf051 contains only the live one (cast code grep). factory has no fallback | regenerate abi from `foundry-out`, add `renderer` and `sniperFeeConfig`, rename `tickIfToken0IsArtCoins`. add a test that encodes against the compiled abi |
| UI-04 | high | deploy never sends or reads the deploy fee | ReviewAndDeploy.tsx:197 `totalValue` = sum of extension msgValue only. factory `_prepareExtensions` requires `msg.value == deployFee + sum(msgValue)` (src/ArtCoinsFactory.sol:348-372). live `deployFee()` on 0x4959 = 0.069 eth, never read by ui | `useReadContract deployFee()`, show it in review, send `deployFee + sum`. refresh right before send (owner can change it, cap 1 eth) |
| UI-05 | high | reward bps sum to 10000 but factory injects a protocol slot, every default deploy reverts `ProjectSideBpsMismatch` | pages/DeployPage.tsx:98 default `bps: 10000`; ReviewAndDeploy.tsx:138 sends as is, calls `deployToken` so protocol bps = `defaultProtocolFeeBps` = 2000 (live, cast). factory requires project side + protocolBps == 10000 (src/ArtCoinsFactory.sol:388-402). RewardsForm.tsx:139 tells the user "all LP rewards go to your connected wallet", false by 20% | read `defaultProtocolFeeBps()`, cap project side at 10000 minus it, validate sum client side (ui never blocks deploy on bad bps), disclose the protocol cut in review |
| UI-06 | high | sell always reverts | lib/swap.ts:205 commands `V4_SWAP, UNWRAP_WETH`; swap.ts:70 uses `TAKE_ALL`, which pays the output to `msgSender()` (the user), so the router holds 0 weth; `UNWRAP_WETH` with `amountMin = minEthOut > 0` reverts `InsufficientETH` (lib/universal-router Payments.sol:90-94, V4Router.sol TAKE_ALL). fails safe, but sell is dead | use `TAKE` to `address(2)` (router) then `UNWRAP_WETH`, or drop unwrap and tell user they receive weth. add a fork test |
| UI-07 | high | hook abi is the old "newMaterial" abi; swap direction silently wrong, pool panels dead | lib/abi.ts:120,125,127 (`newMaterialIsToken0`, `newMaterialFee`, `protocolFeeNumerator`); live hook 0x636c reverts on `newMaterialIsToken0` and has `artCoinIsToken0` (cast). TokenDetailPage.tsx:114 read fails, line 380 passes `newMaterialIsToken0={!!isToken0}` so undefined becomes false, so a wrong `zeroForOne` (swap.ts, SwapWidget.tsx:156) | rename to current abi, treat undefined as "not ready" and block swaps, derive token0 locally from address order instead of trusting a read |
| UI-08 | high | live pools are native eth pairs, swap widget only supports weth pools | TokenDetailPage.tsx:375 renders SwapWidget only when `pairedToken == weth`. coin 111 pool: currency0 = 0x0, tickSpacing 200, `quoteToken` 0x0 (skimConfig, cast). skim hook init requires native quote (SkimFeeInitLib `QuoteTokenMustBeNative`). quoter and stateView are ZERO on mainnet (config.ts:40-41) so quotes show "not configured" | add native pair path (no wrap, `value` as input currency), fill quoter 0x52f0e24d…1203 and stateView 0x7ffe42c4…7227 (both have code, `poolManager()` = 0x0000…8A90, checked) |
| UI-09 | medium | no `deprecated()` gating, no pre-flight simulation | grep: ui never calls `deprecated`, `simulateContract` is used only for the quoter. factory 0x4959 `deprecated() = true` (live), so strangers sign a tx that reverts `Deprecated`; wallet may warn but can be overridden, gas lost. older factory 0xf051 is `deprecated() = false` (open) | read `deprecated()` and `owner()`, show "launching is invite only" unless connected wallet is owner or admin, `simulateContract` before `writeContract`, surface the decoded revert |
| UI-10 | medium | `Verified` badge is self-asserted by the deployer | TokenDetailPage.tsx:315 and :453 show "Verified" from `token.isVerified()`; `verify()` in src/ArtCoinsToken.sol:516-520 is callable once by the original admin, i.e. the scammer | rename ("creator confirmed") or drop it; use a curated registry keyed by address |
| UI-11 | medium | strangers' metadata is rendered with no filter: lookalikes, tracking images, content hosting | TokenCard.tsx:20-21 and TokenDetailPage.tsx:282-283 load `<img src>` from any url in `tokenImage` for every token in the list (ip and referrer leak, tracking pixels, large images); names and symbols unrestricted (TokenConfigForm.tsx:257-274); no duplicate symbol or impersonation warning; any hosted image shows under your domain (legal exposure) | proxy or allowlist image hosts (arweave.net, ipfs gateway you control), `referrerPolicy="no-referrer"`, size cap, show contract address prominently, flag duplicate names and symbols, curated list default, report flow |
| UI-12 | medium | token list scans from block 0 on mainnet | src/lib/config.ts:79 `1: 0n`; lib/events.ts:32-47 loops 2000 block getLogs sequentially, about 12k calls on mainnet, no persistence, no pagination, unbounded strings in each log. single factory only, so LAYER (0xd159…) and coin 111 (0x4959…) are invisible; detail page says "Token not found" | set the real deployment blocks, support a list of factories, cache last scanned block, page results, or use an indexer |
| UI-13 | medium | dev buy encoding is wrong and has no min out | ReviewAndDeploy.tsx:187-193 sets `extensionBps = pct*100` and `extensionData = '0x'`. `ArtCoinsUniv4EthDevBuy.receiveTokens` requires `extensionBps == 0` (`InvalidEthDevBuyPercentage`) and decodes `Univ4EthDevBuyExtensionData{pairedTokenPoolKey, pairedTokenAmountOutMinimum, tokenAmountOutMinimum, recipient}` (src/extensions/ArtCoinsUniv4EthDevBuy.sol:70-85, interface :23-28). form has no min out field | encode the struct, force bps 0, require a nonzero `tokenAmountOutMinimum` derived from a quote or a user chosen max price impact. a zero min is sandwichable at launch |
| UI-14 | medium | swap quote handling is weak: stale quote, no price impact, zero min possible | SwapWidget.tsx:140-207 quote computed only when inputs change, never refreshed; `minOut = quote*(1-slip)` (line 209); quote uses `hookData '0x'` (line 176) while the swap sends attribution; `canSwap` (line 326-332) allows `quote == 0n` so min out 0; no price impact anywhere (grep "impact": none); deadline fixed 10 min (line 47); "max" fills whole eth balance (line 393) | refresh quote on each block and again before send, hard block when quote is 0 or revert, show price impact and fee (including the anti sniper fee), pass same hookData to the quoter, reserve gas on max |
| UI-15 | medium | mev defaults conflict with contracts | DeployPage.tsx:92 descending default 4140s but `ArtCoinsMevDescendingFees` reverts `TimeDecayLongerThanMaxMevDelay` above `MAX_MEV_MODULE_DELAY` = 900s (src/mev-modules/ArtCoinsMevDescendingFees.sol:101-107, hook :97). linear default 69 min (DeployPage.tsx:89) but base hook disables any module at 15 min (src/hooks/ArtCoinsHook.sol:504-512; skim hook plumbing differs, see its :289-293), so the fee would cliff from about 78% to base. time delay seconds field (AntiSniperForm.tsx:276-284) is never encoded (ReviewAndDeploy.tsx:130-133), module delay is a constructor constant. a zero module address silently disables anti sniper (factory returns early at src/ArtCoinsFactory.sol:305-307) while review still prints "Linear (99% -> 1%…)" | clamp durations to the hook limit read on chain, drop the time delay input or read `timeDelay()`, refuse to build config when a module address is zero |
| UI-16 | medium | pool data and fee units only fit the static fee hook | lib/encode.ts:8-17 builds `(address,bytes,bytes)` flat with `feeData = (uint24,uint24)`. decodes by luck: the zero address in word 0 doubles as a zero struct offset, so `abi.decode(poolData,(PoolInitializationData))` passes (confirmed with cast abi-decode). any nonzero extension address would break it. live hook is the skim hook, which needs `SkimHookFeeData` (8 fields) so this reverts. fee units are pips (1% = 10000), correct for `ArtCoinsHookStaticFee`, `MAX_LP_FEE` 100000 matches the 10% slider cap | encode `PoolInitializationData` as a real tuple, add a skim form (baseline skim, bounty bps, referral cap, recipients, payout), pick encoder by hook |
| UI-17 | medium | referral injection is silent and sticky | SwapWidget.tsx:263-274 always adds attribution with `defaultReferrer` or `?ref`, no ui disclosure. lib/useReferrer.ts:63-72 accepts the zero address, `:100-104` stores any `?ref` forever, so a crafted link replaces the default referrer persistently and `?ref=0x0` disables it. `fetch('/config.json',{cache:'force-cache'})` (line 38) means operator edits may not propagate. cost to trader: none, referral is carved from the protocol leg (ArtCoinsHookSkimFee.sol:541-559, capped by `protocolShare`) | show "referred by 0x…" with opt out, reject zero and the user's own address if unwanted, expire stored refs, drop force-cache or version the file |
| UI-18 | low | supply chain and build health | package.json uses caret ranges, lockfile has 957 packages all from registry.npmjs.org with integrity hashes (good). install scripts: bufferutil, esbuild, fsevents, keccak, secp256k1, utf-8-validate. `@irys/*` are 0.0.x (irys bundles 0.0.3, upload-core 0.0.10) and pull axios 1.13.6 (2 high advisories: ssrf, prototype pollution); react-router-dom flagged for framework mode rce (not used, library mode). rainbowkit default wallet list pulls walletconnect, metamask sdk (telemetry), coinbase sdk. vite polyfills ship direct `eval` (vm-browserify) so a strict csp needs care | pin exact versions, `npm ci --ignore-scripts` in ci, trim wallet list, evaluate dropping irys sdk for a plain https upload, add `npm audit --omit=dev` to ci, add tsc and eslint to ci |
| UI-19 | low | secrets and privacy in the bundle | `VITE_WALLETCONNECT_PROJECT_ID` and `VITE_ALCHEMY_API_KEY` are inlined (main.tsx:12-33; verified by building with a dummy id, it appears in `assets/index-*.js`). `.env.example` does not say to domain restrict either key. nothing else secret in src or public; ui/.env is gitignored (root .gitignore:31). reads go through alchemy or default eth.merkle.io (no key), so ip and wallet address leak to the rpc; walletconnect pulse, verify and metamask analytics endpoints are in the bundle | document domain allowlists for both keys, prefer a proxy rpc you run, drop optional telemetry connectors |
| UI-20 | low | allowance scope | SwapWidget.tsx:247 `approve(permit2, MAX_UINT256)` and :259 `permit2.approve(token, universalRouter, MAX_UINT160, now+30d)`. for this token the first step is a no op (solady permit2 shortcut returns max allowance), so the real exposure is the 30 day max permit2 allowance to the router. no eip712 or permit signatures are used (grep `signTypedData`: none) | approve exact amount or use a short expiry, offer revoke |
| UI-21 | low | metadata link and parser hardening | TokenMetadataModal.tsx:119-121 renders `external_url` from the renderer json as `href` unvalidated. react 19 blocks `javascript:` (string present in react-dom, not exercised in a browser) but `data:` and phishing urls pass. lib/metadata.ts:316-335 trusts any json `image`. no `dangerouslySetInnerHTML`, `innerHTML`, iframe, `animation_url` or `tokenURI` rendering found. default token json escapes name, symbol, description, image with `escapeJSON` (src/ArtCoinsToken.sol:540-552) so quote injection into on chain json is closed for the default renderer | allow only https and ar schemes, add `rel` as now, never render svg inline |
| UI-22 | low | image upload | lib/arweave.ts:393-424 uploads via irys with the user's wallet, no payment, default node `uploader.irys.xyz` (bundle). free under 100 KiB (ImageUploader.tsx:21 hard cap). check is client side by `file.type` (line 38), svg allowed, url scheme of the manual field unchecked and the placeholder suggests `ipfs://` and `ar://` which `<img>` cannot load. the user signs an irys data item hash with `personal_sign` style prompt (blind). nothing is stored on chain except the url string | validate scheme, resolve ipfs and ar via gateway, reject svg or sanitize, explain the signature in the ui |
| UI-23 | low | tx state handling | ReviewAndDeploy.tsx:64-82 sets state during render and decodes any log without `log.address == factory`; a reverted receipt shows no error and no state; a dropped tx waits forever; no error boundary (invalid `:address` route params go straight into viem reads, ClaimPage.tsx:77 also builds a fetch path from the raw param) | check `receipt.status`, filter by factory address, add `useReplaced`, add an error boundary, validate params with `isAddress` |
| UI-24 | low | referrals page decodes the wrong shape | ReferralsPage.tsx:118-131 reads index 9 and 3 of a 9 output abi (abi.ts:132-147 has `permanentCollection`, live hook returns 8 values and no such field, cast confirmed). viem decode fails, so `referralPayoutAddr` is undefined and the page is dead. `flushReferral` and `heldReferral` (abi.ts:160-175) do not exist on the live skim hook. the payout address comes from deployer supplied `skimConfig`, so `claim()` is sent to an address chosen by the token deployer (no args, no value, low impact) | regenerate abi from `IArtCoinsHookSkimFee`, remove flush and held, show the payout address and check it against a known `ReferralPayout` before enabling claim |
| UI-25 | info | provenance and staleness | branding is "NewMaterial" (index.html, Header.tsx). `script-js/sync-addresses.mjs:36-37` patches `../artcoins/src/lib/launcher/config.ts`, a different app, so this ui is not what the sync script feeds. FeeFlowPage.tsx:62-79 hardcodes an unrelated sepolia stack (factory 0xac2c… vs config.ts sepolia factory 0x3c3a…). footer "Source on GitHub" is bare github.com (Footer.tsx:96). no escrow ui at all (grep escrow: none), so lp recipients cannot claim from `ArtCoinsFeeEscrow` here. default tick -230400 gives roughly 0.1 eth fdv at the default 1B supply (price about 9.9e-11 weth per token) and the form shows no implied price or fdv | decide whether this ui is shipped. if yes, rebrand, delete FeeFlowPage, add escrow claim, show implied fdv from tick and supply |

## addresses: where they come from and what is right

sources: all chain addresses are compile time constants in `src/lib/config.ts`. no env var, no `public/config.json` field, no onchain discovery. `public/config.json` holds only `defaultReferrer`. `.env.example` has only the two VITE keys.

| item | ui value | live or expected | verdict |
|---|---|---|---|
| factory (mainnet) | 0x0 (config.ts:29) | current 0x49596c37…4e0e, deprecated, owner 0xCB43…17F9, deployFee 0.069 eth, defaultProtocolFeeBps 2000, teamFeeRecipient 0xCB43…17F9 | missing. ui points at no mainnet factory |
| factory (sepolia) | 0x3c3aEfC8…DF7A (config.ts:48) | not a mainnet record | testnet only, not checked (no sepolia rpc) |
| other factories | none | 0xf051… `deprecated=false`, fee 0, owner 0xCB43; 0xd159… deprecated | ui cannot see tokens of either |
| hook | 0x0 | skim hook 0x636c0502…a9cc, `factory()` = 0x4959, `enabledHooks` true | missing |
| locker | 0x0 | 0x866ea3Dc…6aab, owner 0xCB43, `enabledLockers(locker,hook)` true | missing |
| escrow | not present | 0x75596897…25F2 | not used by ui |
| mev modules | all 0x0 | linear skim 0xb038D597…8B83 enabled on factory; ui has no skim module at all, only linear fees, descending, time delay | missing and wrong module family for the skim hook |
| vault, airdrop, devBuy | 0x0 | not verified on 0x4959 (not in preamble) | missing |
| weth | 0xC02aaA39…Cc2 | canonical, code present | ok |
| permit2 | 0x00000000…8BA3 | canonical, code present | ok |
| poolManager | 0x00000000…8A90 | canonical v4, code present | ok (never used by ui logic) |
| universal router | 0x66a9893c…A8Af | code present, `poolManager()` = 0x…8A90 | ok |
| quoter, stateView | 0x0 | 0x52f0e24d…1203 and 0x7ffe42c4…7227 have code and point at the right pool manager | fill in |
| defaultReferrer | 0x41c3BD8A…A6A4 (public/config.json) | 89 byte proxy with code, `owner()` = 0xCB43…17F9, accepts plain eth (eth_call with value succeeded), implementation 0xfe87400c…8dafc not inspected | matches preamble, payable, ok |

## encoding and math checks

| area | result |
|---|---|
| attribution hookData | correct. 1-tuple `PoolSwapData` wrapping 1-tuple `PCSwapData`, outer offset present (attribution.ts:107-114). round trip decoded with cast. `_decodeAttribution` swallows errors so a mistake would silently skip referral, but this one is right. bps 250 vs hook cap `maxReferralBpsOfVolume` (live pool 111 = 250, init cap 1000) |
| factory salt | ui draws 32 random bytes (encode.ts:3-6). factory derives `keccak256(abi.encode(tokenAdmin, salt))` (ArtCoinsDeployer.sol:`_deploy`). no sender in the salt, so no mining step is needed and none is done. front running the same admin and salt only delivers the token to that admin and reverts the original (grief, no theft) |
| ticks | `tickIfToken0IsArtCoins` flipped by hook and locker when the token sorts as currency1 (ArtCoinsHook.sol:454, ArtCoinsLpLocker.sol:322-338). ui rules (lower >= start, multiples of spacing, upper 887220 <= max tick) match `_mintLiquidity` (lines 301-309). negative rounding helpers checked by hand, ok |
| supply units | whole tokens times 1e18 through `Number` (encode.ts:55-57), loses precision above 2^53 tokens, harmless at 1e9. 0 means factory default 1B |
| fee units | pips, 1% = 10000 (`percentToFeeUnits`), matches `FEE_DENOMINATOR` 1e6 and static hook. skim hook uses `SKIM_DENOMINATOR` 100000 and its own struct, not supported |
| mev data | linear `(uint24,uint24,uint32)` ok; descending `(uint24,uint24,uint256)` ok (static struct inlines). duration bounds 1 to 180 min match the form |
| vault and airdrop data | `(address,uint256,uint256)` and `(address,bytes32,uint256,uint256)` match the structs. vault min lockup 7d and vest 90d not enforced by the form. airdrop with empty root encodes a zero root silently (ReviewAndDeploy.tsx:172-173): nobody can claim until the admin sweep window |
| swap buy path | `WRAP_ETH(address(2), CONTRACT_BALANCE)`, `V4_SWAP[SWAP_EXACT_IN_SINGLE, SETTLE(payerIsUser=false), TAKE_ALL(min)]` is structurally right for a weth pool. min out is enforced by `TAKE_ALL` and the swap leg |
| deadline | 10 minutes from click, passed to `execute` (SwapWidget.tsx:267). deploy has no deadline concept in the factory |

## live reads (2026-10-06)

| call | result |
|---|---|
| 0x4959 `deprecated()`, `owner()` | true, 0xCB43078C32423F5348Cab5885911C3B5faE217F9 |
| 0x4959 `deployFee()`, `defaultProtocolFeeBps()` | 69000000000000000, 2000 |
| 0xf051 `deprecated()`, `deployFee()` | false, 0 |
| 0xd159 `deprecated()` | true |
| 0x4959 `enabledHooks(0x636c…)`, `enabledLockers(0x866e…,0x636c…)`, `enabledMevModules(0xb038…)` | true, true, true |
| 0x636c `factory()` | 0x4959 |
| 0x636c `newMaterialIsToken0(bytes32)`, `artCoinIsToken0(bytes32)` | first reverts (selector absent); second exists (queried with a zero pool id only, returned false) |
| coin 111 pool id (currency0 0x0, currency1 token, fee dynamic, spacing 200, hook 0x636c) `skimConfig` | 6000, 8333, 250, 5000, bounty 0x8C72…CD01, protocol 0xed3E…2ba9, payout 0xB03C…9d4c, quote 0x0 (8 values) |
| coin 111 `isVerified()`, `admin()` | false, 0xA96a1125…E6258 |

## wallet, network, chain mismatch

| item | note |
|---|---|
| chains | mainnet and sepolia only (main.tsx:23). no switch chain prompt, no testnet banner, no block when connected to another chain (UI-02) |
| rpc | alchemy transports only when `VITE_ALCHEMY_API_KEY` is set, else viem defaults (eth.merkle.io). reads leak ip and address to that provider. writes go through the wallet rpc |
| project ids | walletconnect id required at start, throws if missing (main.tsx:15-19), exposed in bundle by design |
| failed or partial deploy | a deploy is one atomic tx, so no partial state. a revert refunds eth and burns gas. the ui shows no revert state (UI-23). stuck approvals: only the 30 day permit2 allowance (UI-20) |
| hosting | no csp, headers, or host config in repo. ui is a static spa, so headers depend on the host (unknown) |

## recommendations in order

1. do not publish this ui against mainnet until UI-01 to UI-08 are fixed. a safer interim is to hide the deploy page and keep a read only token list.
2. regenerate abis from `foundry-out` in a script and fail ci when the ui abi drifts (UI-03, 07, 16, 24).
3. read `deprecated`, `owner`, `deployFee`, `defaultProtocolFeeBps` on chain and drive the form from them (UI-04, 05, 09).
4. add a fork test that executes the ui built calldata (deploy, buy, sell, dev buy) against the live stack.
5. add ui to ci: `npm ci --ignore-scripts`, `tsc -b`, `eslint`, `npm audit --omit=dev`.
6. treat all token strings, images and urls as hostile: host allowlist, no verified badge, duplicate warnings.

## what i could not verify

| item | why |
|---|---|
| sepolia addresses in config.ts and FeeFlowPage | no sepolia rpc used, only mainnet reads |
| browser runtime behavior: wagmi `useChainId` on unsupported chains, wallet gas estimation warnings on reverting txs, wallet display of the irys signature | no browser or wallet in the sandbox, code reading only |
| sell revert on the deployed router | proven from `lib/universal-router` source (`TAKE_ALL` recipient, `unwrapWETH9`), not by forking the deployed 0x66a9 bytecode. very likely identical |
| irys free tier terms, permanence of free uploads, rate limits | external service, not queried |
| alchemy getLogs block range limits and rate limits for the 0 to head scan | no key, not tested. the comment at events.ts:30 is unverified |
| deployment block of factory 0x4959 | not looked up (UI-12 fix needs it) |
| vault, airdrop, devBuy, other mev modules enabled on 0x4959 | not in the preamble table, not read |
| implementation behind defaultReferrer proxy 0xfe87…dafc | not inspected, only that it holds eth and has owner 0xCB43 |
| which of the `npm audit` advisories are reachable in the browser bundle | triaged by dependency name only, not by exercising code paths |
| javascript: blocking in react-dom | grep of the production bundle string only, not run |
| whether any hosted copy of this ui exists, and its headers | no deployment info in repo |
| production app that `sync-addresses.mjs` targets (`../artcoins/src/lib/launcher/config.ts`) | not in this checkout |
