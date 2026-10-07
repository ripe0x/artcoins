# review: extensions and renderers (second pass)

scope: `src/extensions/**`, `src/renderer/**`, `src/interfaces/{IMetadataRenderer,IArtCoinsExtension,IScripty}.sol`. legacy dev buy read for comparison only (diff is comments + native eth branch). live state read on a mainnet fork at block ~26.13M.

proofs: `test/v2/review/extensions-renderers/`

| file | needs | what |
|---|---|---|
| `RenderersReview.t.sol` | nothing | injection, utf8, json escaping, gas scaling with real shipped assets (`script-js/data/ll`) |
| `ExtensionsReview.t.sol` | nothing (test contract plays factory) | airdrop, vault, auto forward, access control |
| `ForkRenderersReview.t.sol` | mainnet rpc | gas of live LAYER and coin 111 `contractURI`, live LAYER renderer under forced trade counts |

run (other agents' dirs currently fail to compile, so skip them):

```
/tmp/claude-0/forge.sh test --skip "test/v2/harness/**" --skip "test/v2/review/factory-token/**" \
  --skip "test/v2/review/hooks-mev/**" --skip "test/v2/review/locker-fees/**" \
  --match-path "test/v2/review/extensions-renderers/**" -vv
```

result: 19 pass (17 local, 2 fork). tests named `test_bug_*` pass by demonstrating the bug, `test_holds_*` confirm a claim, `test_measure_*` log numbers.

## live context (verified on chain)

| fact | value |
|---|---|
| block gas limit | 60,000,000 |
| LAYER `0xb728…E6c9` renderer | `LiquidityLayerOnchainRenderer` `0x0572…d186`, owner `0xCB43…`, counter = `LiquidityLayerAutoForwardExtension` `0x38d0…03f7`, 1,994 live trades + 21.8K history bits, imageOverrideUri set (ipfs) |
| coin 111 renderer | `0x7604…eEc7` forwarding to `0x9438…53f4` (permanent collection code, not in this repo) |
| scripty content `ll/sketch…`, `ll/history…` | not frozen, owner `0xCB43…` |
| deploy time extensions (broadcast records) | airdrop `0xf937…`, dev buy `0xfcb6…`, vault `0x8473…`, burn `0x034d…` all bound to legacy factory `0xd159…`. none enabled on current `0x4959…` or older `0xf051…` factory |
| auto forward on current hook allowlist `0xd6D5…` | not enabled (it is bound to the LAYER hook `0xA5eA…`) |
| coin 111 deploy info | no extensions |

consequence: every extension bug below is latent on the current and open factories. renderer gas is live.

## findings

| id | sev | title |
|---|---|---|
| G1 | medium | coin 111 `contractURI` costs ~177M gas, reverts under any 50M or 100M eth_call cap and above the 60M block limit |
| G2 | low | LAYER renderer gas grows without bound with trade count: 32.4M today, >50M at ~150K to 250K live trades |
| A2 | medium | airdrop root is replaceable after lockup + 1 day while zero claims: admin can take the whole airdrop or front run the first claim |
| A1 | low | zero root airdrop plus a second airdrop entry in the same deploy overwrites accounting and strands the first tranche |
| A3 | low | airdrop admin can be zero: unclaimed remainder and root become unrecoverable |
| V1 | low | vault admin can be set to zero: allocation permanently bricked |
| R1 | low | name and symbol go into SVG `<text>` unescaped (DynamicBlock, Example): markup injection, raw `&` breaks the image |
| R3 | low | sprite renderer puts `token.imageUrl()` into an SVG `href` attribute unescaped |
| LL1 | low | auto forward extension on a native eth pool reverts every afterSwap; hook swallows it, counter silently dead |
| LL2 | low | any trader can starve the pool extension of gas so their trade is not recorded and the pipeline is skipped |
| AB1 | low | auto burn fires the LAYER buy and burn inside any trader's swap with a spot derived floor; keeper reward always fails |
| D1 | low | dev buy leg minimums are caller chosen and the paired hop runs on a public pool |
| R2 | info | byte truncation splits utf8 in SVG text |
| R4 | info | LL renderer splices owner set `monaMimeType` into inline js; scripty content unfrozen |
| D2 | info | dev buy is exempt from mev module and pool extension by ordering; partial fill leaves residue with no rescue |
| V2 | info | vault `AllocationClaimed` remaining amount is wrong |
| LL3 | info | `seedHistory` one shot check is bypassable for all sell chunks; renderer `counter` is immutable |
| F1 | info | per extension floor rounding leaves up to n-1 wei in the factory |

### G1 medium. coin 111 metadata needs ~177M gas

- evidence: `ArtCoinsToken.sol:524-538` forwards `contractURI`/`tokenURI` to the renderer with no fallback. live renderer `0x7604…` calls `0x9438…contractURI`, which calls `indexedPixelsOf` (~0.35M to 0.5M gas each) for every collected trait and composes pixel art in memory.
- proof: `test_measure_G4_liveLayerAnd111` logs `111 contractURI gas 179,363,374, bytes 314,817`. `cast call 0x61C9…8ae "contractURI()" --gas-limit 50000000` and `--gas-limit 100000000` both revert, `--gas-limit 200000000` returns 310KB. `cast estimate` reverts. tenderly answers only because its default call gas is huge.
- impact: any indexer, wallet or marketplace on a node with geth default `rpc.gascap` (50M) sees a revert. no contract can read it on chain (60M block). cost grows as more traits are collected. no fund risk.
- fix: renderer side (permanent collection): precompute and store the composed bitmap (sstore2) when the collection changes, render from the cache. artcoins v2 token: keep `setMetadataRenderer` available to the token admin (it is, admin `0xA96a…` not renounced) and add a gas budget check (< 30M) to renderer acceptance tests.

### G2 low. LAYER renderer gas is unbounded in trade count

- evidence: `LiquidityLayerOnchainRenderer.sol:313-321` reads every 256 trade chunk with an external call and a 32 step byte loop (`_readBitStream` :385-397), then the bitstream is base64ed inside js, the html base64ed again, then the json base64ed again (:230-243, :326-334).
- proof (real ScriptyBuilderV2 + real stored assets on fork, `test_bug_G2_liveLayerRendererExceeds50MGasAsTradesGrow`):

| live trades | gas | bytes |
|---|---|---|
| 1,994 (today) | 32,396,980 | 235,985 |
| 10,000 | 33,180,243 | 238,417 |
| 100,000 | 42,822,954 | 265,045 |
| 250,000 | 58,768,207 | 309,489 |
| 500,000 | 86,719,296 | 383,601 |
| 1,000,000 | 148,199,990 | 531,741 |

  local mock builder (`test_measure_G2_onchainRenderer_tradeCountScaling`) agrees on the slope: ~0.11M to 0.12M gas per 1K trades.
- impact: today 32M already exceeds some providers' eth_call caps of 30M (not verified per provider). crosses 50M at roughly 150K to 200K live trades and the 60M block limit near 260K. at the observed pace this is far off, but nothing stops it.
- fix: cap the on chain bitstream (last N trades plus totals) or pre-pack history into scripty and only append the live tail; drop one base64 layer (`data:text/html,` percent encoding or plain json string); make the renderer `counter` settable (see LL3).

### A2 medium. airdrop allocation is not frozen

- evidence: `ArtCoinsAirdrop.sol:127-152`. after `lockupEndTime + 1 days` with `totalClaimed == 0` the admin may set any root. with `MIN_LOCKUP_DURATION = 0` (:32) that is one day after launch.
- attack: admin waits a day, or watches the mempool for the first `claim`, front runs with `updateMerkleRoot(token, leaf(admin, supply))`, claims everything. the first claimer's proof fails.
- proof: `test_bug_A2_airdrop_adminSwapsRootAndTakesEverything`.
- fix v2: root set once. allow setting only while zero and only before lockup end; never allow replacing a nonzero root. this is a coin level allocation decision and should be frozen at launch.

### A1 low. duplicate airdrop entry strands tokens

- evidence: `ArtCoinsAirdrop.sol:67-69` uses `merkleRoot != 0` as the existence flag, so a zero root ("set later") entry does not block a second entry, which overwrites `totalSupply`, admin and times (:87-97). `ArtCoinsFactory.sol:348-372` does not dedupe extensions.
- proof: `test_bug_A1_airdrop_zeroRootThenSecondEntryStrandsFirstTranche`: 10% entry with zero root, then 5% entry; after `adminClaim` the 10% stays in the contract forever (`adminClaim` is one shot, no rescue).
- fix v2: explicit `exists` flag; reject zero root at creation or reject a second airdrop per token unconditionally; factory rejects duplicate extension addresses.

### A3 low. zero airdrop admin

- evidence: no `admin != 0` check at `ArtCoinsAirdrop.sol:94`; `updateAdmin` (:115) also accepts zero.
- proof: `test_bug_A3_airdrop_zeroAdminLocksUnclaimedForever`.
- fix v2: require nonzero admin, or let anyone sweep the unclaimed remainder after `adminClaimTime` to a beneficiary fixed at launch (or burn).

### V1 low. vault admin to zero bricks the allocation

- evidence: `ArtCoinsVault.sol:114-118` accepts zero; `claim` (:130-150) always transfers to `admin`, which reverts for zero, and nobody can change admin afterwards.
- proof: `test_bug_V1_vault_zeroAdminBricksClaims`.
- fix v2: reject zero; separate `beneficiary` from `admin`; two step admin transfer.

### R1 low. SVG text injection

- evidence: `DynamicBlockRenderer.sol:77,82`, `ExampleOnChainRenderer.sol:86,91` concat raw `name`/`symbol` into `<text>`. json fields are escaped (holds), svg is not.
- attack: name `</text><image href="//x.i"/>` (28 bytes, survives truncation) closes the text node and injects an element. symbol `A&B` makes the svg invalid xml so the image does not render.
- proof: `test_bug_R1_dynamicBlockRenderer_nameInjectsSvgMarkup`, `test_bug_R1_exampleOnChainRenderer_nameInjectsSvgMarkup`, `test_bug_R1_exampleOnChainRenderer_ampersandSymbolBreaksXml` (decode `contractURI` → json → `image` → svg, assert injected markup present).
- impact: the svg ships as `data:image/svg+xml` in `image`, which marketplaces render in `<img>` (no script). consumers that inline svg into the dom are exposed. name and symbol are set by whoever deploys; on the open factory `0xf051…` that is anyone. neither renderer is wired to a live coin that we found.
- fix v2: `LibString.escapeHTML` on every text node and attribute; truncate after escaping on a utf8 boundary.

### R3 low. sprite renderer href injection

- evidence: `LiquidityLayerSpriteRenderer.sol:105` puts `t.imageUrl()` inside `<image href="…">`; the token admin can change it any time (`ArtCoinsToken.sol:487`). `animationUrlBase` is spliced into json unescaped (:169, constructor only).
- proof: `test_bug_R3_spriteRenderer_imageUrlBreaksOutOfHrefAttribute` (output contains `<image href="x"/><script>alert(1)</script>`).
- fix v2: escape attribute values; escapeJSON the animation url. not deployed per broadcast records.

### LL1 low. auto forward extension on a native eth pool

- evidence: `LiquidityLayerAutoForwardExtension.sol:199-201,221` derives `weth` from the pool's paired currency and calls `IERC20(weth).balanceOf` outside any try. for `address(0)` that reverts, rolling back the counter write too. the hook catches it (`ArtCoinsHook.sol:623-629`), so trades succeed but nothing is recorded or forwarded, forever, silently.
- proof: `test_bug_LL1_autoForward_nativeEthPoolRevertsEverySwap`.
- live: not allowlisted on the current hook. latent.
- fix v2: bind weth and LAYER at construction like the auto burn extension does; reject pools whose paired currency differs in `initializePreLockerSetup`.

### LL2 low. trades can be omitted from the counter

- evidence: `ArtCoinsHook.sol:612-630` runs the pool extension via `try this._runPoolExtensionHelper` with all remaining gas. a trader (own router, or plain gas limit tuning) can leave enough for the swap to settle but not for the extension (63/64 rule). the catch emits `PoolExtensionFailed` and the swap succeeds. locker swaps are skipped by design (:616).
- impact: LAYER's on chain art is "every trade"; a seller can keep sells out of it. auto burn/forward stages are skipped (harmless, next swap does it).
- proof: trace only (needs the hook stack).
- fix v2: give the extension a fixed gas stipend and revert the swap if `gasleft()` after the call is below a floor, or accept and document.

### AB1 low. auto burn stage runs inside untrusted swaps

- evidence: `ArtCoinsAutoBurnPoolExtension.sol:273-283` calls `burnRouter.processBurnWethOpenTab(0)`. the floor is derived from the LAYER pool spot read in the same call (`BurnRouter.sol:272,346-360,380-383`), and the impact clamp is relative to that spot (:305-315, `MAX_SWAP_IMPACT_BPS = 100`).
- attack: inside one unlock, push LAYER price up, swap the art coin pool to trigger the burn at the manipulated spot, swap back. bounded per call by the 1% clamp and paid lp fees on both legs; profit needs router budget large relative to pool depth times fee. the same is possible by calling `processBurnWethOpenTab` directly (it is permissionless), so the extension widens who can trigger it, not the core issue. the core issue belongs to the BurnRouter review.
- second issue: `_payKeeperReward` sends eth to `msg.sender` (`BurnRouter.sol:433-443`); the extension has no `receive`, so every auto burn emits `KeeperRewardFailed` and the eth sits in the router until the next wrap. no loss, wasted gas.
- proof: trace only.
- fix v2: floor from an ema or twap, not spot; skip the reward when the caller is the extension.

### D1 low. dev buy slippage

- evidence: `ArtCoinsUniv4EthDevBuy.sol:126-164`. the intermediate hop (eth → paired erc20) runs on a public pool with `pairedTokenAmountOutMinimum` from calldata, possibly zero, so a mempool searcher can sandwich the launch tx. the final leg (:178) runs on the brand new pool in the same tx, so its minimum only guards against earlier extensions in the same list.
- fix v2: require nonzero minimum on the hop leg; private mempool guidance in the ui.

### info items

| id | evidence | note |
|---|---|---|
| R2 | `DynamicBlockRenderer.sol:232`, `ExampleOnChainRenderer.sol:141` | `_truncate` cuts bytes; `"a" + 11×€` leaves `e2 82` before `</text>`. proof `test_bug_R2_dynamicBlockRenderer_truncationSplitsUtf8` |
| R4 | `LiquidityLayerOnchainRenderer.sol:210,336` | mime spliced into a js string. owner only, and the owner can already swap the sketch. proof `test_bug_R4_onchainRenderer_mimeTypeInjectsScript`. scripty content for LAYER is unfrozen and owned by the eoa `0xCB43…`, so the eoa can append to the sketch js. freeze it once final |
| D2 | `ArtCoinsFactory.sol:263-264`, `ArtCoinsHook.sol:480-499,615` | extensions run before `initializeMevModule`, so the dev buy pays no mev or sniper fee and the pool extension (counter) does not see it. by design, no third party can join (same tx, pool created in tx). partial fill (only if the buy exceeds the range) leaves native eth in the universal router (anyone can sweep) or weth in the dev buy contract (no rescue, no receive). `IERC20(token).transfer` return unchecked (:96), safe for ArtCoinsToken |
| V2 | `ArtCoinsVault.sol:149` | event "remaining" is `amountTotal - amountToClaim`, should subtract `amountClaimed` |
| A4 | `ArtCoinsAirdrop.sol:219-225` | two leaves for one address share `amountClaimed`, so the user gets the max, not the sum; an over allocated tree pays first come first served (capped at supply, :228). claiming with the smaller leaf after the larger can underflow and revert. off chain tree builder must aggregate |
| LL3 | `LiquidityLayerAutoForwardExtension.sol:317-329`, `LiquidityLayerOnchainRenderer.sol:50` | `require(_chunks==0)` passes again for an all sell chunk; garbage high bits in the last seeded chunk are never cleared by sells. renderer `counter` is immutable (the natspec mentions a `setExtension` that does not exist), so each extension migration needs a renderer redeploy. the auto burn extension does not count trades: binding it to LAYER freezes the art |
| F1 | `ArtCoinsFactory.sol:371,430` | `pct*S/BPS` vs Σ `bps_i*S/BPS`: up to n-1 wei of the coin stays in the factory, sweepable by `claimTeamFees`. zero for the default 1B supply |
| AB2 | `ArtCoinsAutoBurnPoolExtension.sol:260,274,287,332` | balance and `availableFees` reads sit outside try; a revert there skips the whole extension (hook catches). acceptable |

## claims that hold

| claim | evidence |
|---|---|
| json string fields are escaped in every renderer (name, symbol, description, image), including quotes, backslash, control chars, `</script>`, `]]>`, unicode | `test_holds_jsonEscapingRoundTripsHostileName` (parses `.name`/`.symbol` back for all 5 renderers) |
| base64 and data uri prefixes are correct (`data:application/json;base64,`, `data:image/svg+xml;base64,`, `data:text/html;base64,`) | all renderer tests decode through them |
| src renderers other than LL are cheap: Default 22K, DynamicBlock 420K, Example 190K gas realistic; 12M to 24M with 4×24KB strings (which cost the deployer ~16M gas to store); sprite 7.4M at the 200+200 glyph cap | `test_measure_G1_*`, `test_measure_G3_*`. the prior "block gas limit" claim is refuted for these |
| `receiveTokens` is factory only on airdrop, vault, dev buy, burn | `test_holds_receiveTokensOnlyFactory` |
| factory side: extensions allowlisted (`ArtCoinsFactory.sol:144-151,366`), ≤10, ≤90% bps, `Σ msgValue + fee == msg.value` (:369), deploy is `nonReentrant`, allowance reset to 0 after each call (:436), any extension revert reverts the whole launch | read |
| each extension enforces its own msg.value: airdrop, vault, burn require 0; dev buy requires exact nonzero and zero bps | read |
| airdrop leaf is double hashed `keccak(keccak(abi.encode(addr, amt)))`: no leaf vs internal node collision; zero amount rejected; per user and total caps hold; window: claims blocked after `adminClaim` | read |
| vault vesting: min 7 day cliff, min 90 day linear, rounds down, monotone, exactly 100% at end, no admin early unlock, one allocation per token | `testFuzz_holds_vaultVestingMonotoneAndComplete` |
| burn extension burns exactly `extensionSupply` from its own balance, reflected in `totalSupply` | read |
| counter/auto forward/auto burn init and `afterSwap` are hook only; re-init for a different token reverts | read |
| dev buy cannot be piggybacked: runs inside the factory tx on a pool created in the same tx | read |

## rescue and mutability

| contract | owner / admin | mutable after launch | rescue path |
|---|---|---|---|
| ArtCoinsAirdrop | per token admin | root (A2), admin (incl. zero) | `adminClaim` once, after vest + 14 days. nothing for stray tokens or A1 tranche |
| ArtCoinsVault | per token admin | admin (incl. zero) | none |
| ArtCoinsUniv4EthDevBuy | none | nothing | none (no receive; stray weth or tokens stuck) |
| BurnExtension | none | nothing | none (holds nothing) |
| ArtCoinsAutoBurnPoolExtension | Ownable | thresholds, collectOnSwap | none needed (holds nothing). addresses immutable |
| LiquidityLayerAutoForwardExtension | Ownable | thresholds, one shot seeds | none needed. hook, locker, pfc, burn router immutable |
| LiquidityLayerCounterPoolExtension | none | nothing | n/a |
| LiquidityLayerOnchainRenderer | owner (eoa) | all strings, assets, supply config | counter, builder, storage immutable |
| LiquidityLayerSpriteRenderer | none | nothing | redeploy |
| Default / DynamicBlock / Example | none | nothing | token admin swaps renderer |

v2 target: periphery (renderers, pool extensions, thresholds) owner changeable with rescue for stray funds; coin level allocation (airdrop root, vault beneficiary floor, vesting, extension bps) frozen at launch. today airdrop root and both admins violate the second half, and no deploy time extension has a rescue for stray tokens.

## not verified

- dev buy end to end on a live launch (harness `test/v2/harness/ForkBase.sol` does not compile yet). D1, D2 are from reading.
- LL2 and AB1 need the hook stack and the live LAYER pool; reasoning only. AB1 profitability not computed.
- SetExtension event history: `cast logs` from block 24.9M returned nothing for both live factories; may be rpc truncation. only broadcast known extension addresses were checked with `enabledExtensions`.
- per provider eth_call gas caps (alchemy, infura, quicknode); only the geth default 50M and the 60M block limit are used above.
- permanent collection renderer source (`0x9438…`) not reviewed; G1 is measured, not root caused beyond the trace.
