# v2 review b: periphery, extensions, renderers

independent review of code i did not write. scope: `src/v2/FeeAutoSwapperV2.sol`, `src/v2/protocol-fee/BurnRouterV2.sol`, `src/v2/protocol-fee/ProtocolFeeControllerV2.sol`, `src/v2/extensions/**`, `src/v2/renderer/**`, their interfaces. reviewed at `c0c80b6` plus the working tree of 2026-10-06 (D31 and D32 already landed in both swapper and router). proofs run on a mainnet fork (block 26,130,269) against the real `ArtCoinsHookV2` and `ArtCoinsTokenV2`, deployed by `test/v2/mocks/HookV2ForkBase.sol`.

run: `/tmp/claude-0/forge.sh test --match-path "test/v2/review-v2/b/**" --skip "test/v2/harness/**" --skip "test/v2/review/**" --skip script -vv`. result: 10 passed, 0 failed, 0 skipped (fork reachable). no extra `--skip` was needed: the hook, token and their mocks compiled. the factory is not imported.

proof files:
| file | what |
|---|---|
| `test/v2/review-v2/b/V2BPeriphery.fork.t.sol` | bug proofs V2B-01, V2B-02 (pass = bug present), and holds tests for HARD and VENUE flows through the real hook |
| `test/v2/review-v2/b/V2BExtensions.t.sol` | holds tests: airdrop against a vector built with the ui's own `@openzeppelin/merkle-tree`, window edges, vault cliff edges |

## findings

| id | sev | title | evidence | proof |
|---|---|---|---|---|
| V2B-01 | medium | burn router floor and reward count the hook's refundable skim, so any budget above a few times the per block fill can never burn; eth is unrescuable | `BurnRouterV2.sol:278,321,344,349`; hook `ArtCoinsHookV2.sol:370,404` | `test_V2B01_burnRouter_bigBudgetNeverBurns_defaultSettings`, `test_V2B01_burnRouter_bricked_evenAtOwnerLimits` |
| V2B-02 | medium | swapper convert is sandwichable by its own caller on low fee v2 pools: limit and floor are relative to the manipulated spot | `FeeAutoSwapperV2.sol:189,200,208,251` | `test_V2B02_swapper_sandwich_profitable_lowFeePool` |
| V2B-03 | low | burn router keeper reward and `Burned.ethIn` include skim that is refunded later (reward paid twice on the same eth) | `BurnRouterV2.sol:349` | logged in V2B-01 test (10 eth: ethIn 5.61, refund 0.28, reward at cap) |
| V2B-04 | low | ui claim page cannot claim v2 airdrops (v1 abi, no `index`); unclaimed supply goes to the sweep recipient after the window | `ui/src/pages/ClaimPage.tsx:17,111,148,190` | trace |
| V2B-05 | low | same tx sandwich of `processBurn` is the V2B-02 class, bounded by `maxImpactBps` (<= 3%); profitable only when lp fee plus baseline skim is under about half the impact | `BurnRouterV2.sol:299-325` | estimate, not proved |
| V2B-06 | info | controller `processFees(token)` is permissionless for any erc20; a token whose `transfer` returns false makes the controller (a depositor) write junk `storeFees` credits under the treasury. D33's spam concern reopened for one key | `ProtocolFeeControllerV2.sol:93,118`, `FeeDelivery.sol:61-63` | trace |
| V2B-07 | info | swapper and controller push fallback needs escrow depositor status (D33); nothing on chain checks it. a missed runbook step plus a rejecting `endRecipient` brings back LF-08 (flush and convert revert) | `FeeAutoSwapperV2.sol:371`, `FeeDelivery.sol:30` | trace |
| V2B-08 | info | dev buy escrow credit is shared across launches: if `claimTo` fails but the direct refund succeeds (recipient accepts eth only from the dev buy contract), the stale credit is paid to the next partial fill launch's refund recipient | `ArtCoinsUniv4EthDevBuyV2.sol:105-110,157-166` | trace |
| V2B-09 | info | owner levers without upper bound: router `minProcessThreshold` (up to uint96 max, disables burns), controller `rescue` of anything incl. eth in transit; router `initialize` does not check the key's hook. all owner trust, by DESIGN section 2 | `BurnRouterV2.sol:117-129,231-237`, `ProtocolFeeControllerV2.sol:147-156` | n/a |

### V2B-01 medium: burn router bricks once its balance outgrows the per block fill

- mechanism: `processBurn` swaps the whole balance minus the reward reserve (`:278`), exact input, with a price limit. the hook charges the skim on the whole requested input in `beforeSwap`; on a price limited partial fill it keeps only `charged * r / requested` and credits the rest to the router in the escrow (`ArtCoinsHookV2.sol:370,404`, D11). the router's delta still includes the full charge, so `ethIn = r + charged` (`:321`). `_finish` then requires `got >= spotFloorBps * spot * ethIn` (`:344`), i.e. it demands coin for eth that never reached the pool. revert condition, 1:1 price: `floor * (r + bps * budget) > r * (1 - lpFee) * (1 - impact/2)`.
- numbers on the fork (6% baseline skim, 0.5% lp fee, 1000 eth full range, 111 style config): 10 eth burns (ethIn 5.61, 0.28 refunded to escrow); 50 eth reverts `InsufficientOutput` every block; at the owner limits (impact 300 bps, floor 50%) 300 eth still reverts. default settings brick at about 2% of the pool's eth reserve; owner levers stretch that to about 24%. a 10% baseline is worse.
- why it sticks: budget is the whole balance with no step cap, the balance only grows (controller burn share, refunds, anyone's `receive`), eth cannot be rescued (`CannotRescue(0)`), and rotation in the controller strands the old router's eth. a griefer can brick a healthy router by donating (proved: 5 eth router plus 45 eth donation). the only unprivileged unblock is jit liquidity large enough to absorb the budget inside the impact limit.
- the DESIGN b6 claim "a big balance partial fills and drains over later blocks, never in one" does not hold on any pool with a nonzero baseline skim; p1's tests use a hookless pool, so they cannot see it.
- fix: read `escrow.balances(this, 0)` before and after the unlock and use `ethIn - refundCredited` for the floor, the reward and the event (the hook credits synchronously inside `afterSwap`); and/or add an owner bounded `maxStepIn` like the swapper, or size the input to the fill at the limit (`SqrtPriceMath.getAmount0Delta(spot, limit, liquidity)` grossed up by the skim). add a fork test on the real hook with budget >> fill.

### V2B-02 medium: swapper sandwich by the keeper itself

- mechanism: `convert(minOut)` is permissionless, the caller picks `minOut`, and both remaining guards are taken from `getSlot0` at call time (`:200`): the price limit (`maxSlippageBps` above that spot) and the floor (`spotFloorBps` of that spot). a contract sells coin, calls `convert(0)`, buys the coin back, all in one tx. pacing (`minBlocksBetweenConverts`) only stops a second convert in the block; it does not bound the pre move. the natspec "bounded by the limit and pacing" is wrong: the limit bounds the swapper's own move, not the attacker's.
- numbers on the fork (v2 hook, baseline skim 0, lp fee 0.5%, both allowed by `_validateSkim`; 1000 eth pool; step 20 coin, slippage 500 bps): honest convert pays the recipient 19.50 eth; sandwiched 13.61 eth (-30%); attacker nets +4.13 eth with coin flat, every `minBlocksBetweenConverts`.
- not profitable on 111 style config (6% skim each way, about 13% round trip on the push): break even needs step value above roughly `fee_roundtrip / 2 * reserve`, and the step is capped near 5% of reserve by the 10% slippage max. so the exposure is per pool config, unknown at swapper deploy time; LF-07's "add a reference price" was not done.
- fix: anchor to a price the same tx cannot move: record the pool price at the first swap of each block in the hook (transient or a per block slot) and use it as the reference for both limit and floor; or gate `convert` to an owner set keeper set that must pass an off chain `minOut` >= the floor; at minimum, have the swapper refuse configs where `maxStepIn` impact exceeds the pool's lp fee plus baseline skim.

### V2B-03 low: keeper reward on refundable skim

`rewardFor(ethIn)` (`:349`) uses the inflated `ethIn` from V2B-01; the refunded part is burned again later and rewarded again. capped at 0.01 eth per burn, so small. fix with V2B-01 (use `ethIn - refundCredited`).

### V2B-04 low: v2 airdrops are not claimable from the ui

`ClaimPage.tsx` imports the v1 `airdropAbi`, reads `airdrops(token)` and calls `claim(token, wallet, amount, proof)`. v2 is `claim(token, index, recipient, amount, proof)` and `tranche(token, index)`. the leaf encoding itself matches (`merkle.ts` builds `StandardMerkleTree.of([[address, amount]], ["address","uint256"])`, the contract hashes `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`, proved with a js generated vector). users who rely on the ui miss the claim window and the sweep recipient receives their share. fix: v2 claim path with index, before any v2 airdrop launches.

## claims that hold

| claim | evidence |
|---|---|
| HARD coin: swapper convert works through the real hook; in grant consumed exactly | `test_holds_hardMode_swapperConvert` (pendingCanonical out+in = 0 after) |
| HARD coin: burn router take gets the hook's out grant; supply drops by burned | `test_holds_hardMode_burnRouter` |
| VENUE coin: burn router take is covered by the attested budget, no tax to the sink | `test_holds_venueMode_burnRouter_untaxed` |
| HARD coin: dev buy before `initializeMevModule` (factory order) delivers coin to the recipient | `test_holds_hardMode_devBuy` |
| dev buy partial fill on the real hook: over charged skim reaches `refundRecipient` via `claimTo` in the same call, escrow left at 0 | `test_holds_devBuy_partialFill_skimRefundReachesRecipient` |
| airdrop leaf equals openzeppelin StandardMerkleTree with the ui's tuple order `[address, uint256]`; js proofs verify; wrong amount fails | `test_holds_airdrop_jsTreeVector_andWindowEdges` |
| airdrop windows exact: claim ok at `sweepTime - 1`, `ClaimWindowClosed` and sweep open at `sweepTime`; sweep pays the frozen recipient only the unclaimed rest | same test |
| vault cliff: `AllocationNotUnlocked` before `lockupEnd`, 0 at `lockupEnd`, 1 wei one second later, exactly 100% at `vestingEnd` | `test_holds_vault_cliffEdges` |
| swapper price limit `spot * sqrt(1 + bps)` rounded down; router limit `spot / sqrt(1 + bps)` rounded up; both keep the move <= bps. only one token ordering exists (router `initialize` and swapper `_key` force native currency0) | code `FeeAutoSwapperV2.sol:242-246`, `BurnRouterV2.sol:303-307`, p1 partial fill tests |
| floors round down (lenient by <= 1 wei); `floorFor` is the enforced function (LF-12) | code, p1 `floorView_matchesEnforcement` |
| one burn per block across `processBurn` and `processBurnOpenTab` (shared `lastBurnBlock`); open tab gated to `openTabCaller`, default none (D31) | code `:152-162,269-271`, p1 tests |
| router `initialize` once, owner only; setters bounded (impact [25,300], threshold >= 0.001 eth, floor [5000,9500]) | code, p1 tests |
| swapper and router `unlockCallback` reachable only through their own `unlock` (PoolManager calls back the unlocker) | code |
| swapper `rescue` cannot reach eth or the coin; the swapper never approves anyone, so a wrapper token's `transfer` cannot pull the coin | code `:337-343` |
| swapper flush/convert: reentrant `endRecipient` hits `nonReentrant`, its push fails and the amount is escrowed; keeper reward failure goes to the recipient | code, p1 tests |
| swapper `selfClaimOnly` set in the constructor; hook skim refunds never land under the swapper (exact input sell: skim is on the unspecified quote side, no over charge) | code, hook `_afterSwap` |
| keeper reward loop with dust: reward is 0.5% of the swapper's own output, paced per block, capped; a donor gets back less than donated | code |
| controller `receive` never reverts (gas gated `try this.processFees`); rounding dust goes to the burn share; rotation makes no call into the old router; treasury reentry is blocked by `nonReentrant` and falls back to escrow | code, p1 tests |
| extensions: `onlyFactory` on every entry; `nonReentrant` per extension blocks a nested launch reusing the same extension; airdrop and vault require `msg.value == 0 == msgValue`, dev buy requires `msg.value == msgValue != 0` | code |
| renderers: every token string reaches svg or json only through `SvgText` (`text`, `attrUrl`, `jsonText`, `jsonUrl`); the rest are literals, hex, decimals, base64. `escapeHTML` covers `" & ' < >`, so a `'` cannot leave the sprite `href`. `clean` strips C0, DEL, C1 and invalid utf8 before `escapeJSON`, so the json stays valid. `data:` prefixes are constant literals; OpenZeppelin `Base64` pads | code `SvgText.sol:46-173`, r1 fuzz tests |
| sprite `_glyphs` writes at most 32 bytes per element; the overlapping word writes stay below the hash scratch | code `SpriteRendererV2.sol:161-211` |

## not verified

| item | why |
|---|---|
| D34 netting (token commit `44aa280` is docs and tests only; the hook working tree is mid edit) against the swapper, router and dev buy | in flux. re-run `test_holds_*` above once t1 and h1 land; the swapper's coin inflow and the router's take must still be covered in both modes |
| factory side of extensions: exact `msgValue` forwarding, approvals of `extensionSupply`, extension order relative to `initializeMevModule`, reentrant launch through a non extension callback | factory package in progress, not imported |
| render gas at the D30 caps | relied on r1's `test_renderV2_maxGlyphsUnderBudget` and `oversizeTokenStringsStillValid`; not re-measured |
| V2B-05 burn router sandwich profitability | estimate only |
| renderer output in real marketplaces and browsers (svg in `<img>` versus inline) | out of reach |
