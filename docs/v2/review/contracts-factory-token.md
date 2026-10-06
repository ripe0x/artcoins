# contracts review: factory, token, deployer, escrow

second pass. scope: `src/ArtCoinsFactory.sol`, `src/ArtCoinsToken.sol`, `src/utils/ArtCoinsDeployer.sol`, `src/utils/OwnerAdmins.sol`, `src/interfaces/IArtCoinsFactory.sol`, `src/interfaces/IArtCoinsTaxable.sol`, `src/ArtCoinsFeeEscrow.sol`, `src/legacy/` for comparison. line numbers are at commit 8f8c62a.

proofs: `test/v2/review/factory-token/`. every `test_bug_*` passes by asserting the bad outcome; flip the assertion when v2 fixes it. `test_holds_*` pin claims that hold.

```
/tmp/claude-0/forge.sh test --match-path "test/v2/review/factory-token/**" \
  --skip "test/v2/harness/**" --skip "test/v2/review/hooks-mev/**" \
  --skip "test/v2/review/locker-fees/**" --skip "test/v2/review/extensions-renderers/**" --skip "script/**" -vv
```
(the skips only dodge other agents' in progress files that did not compile at the time.) 16 tests, all pass. `FactoryTokenFork.t.sol` forks mainnet at block 26_130_269 (`MAINNET_RPC_URL`, default tenderly) and skips without an rpc.

## live facts read on chain (2026-10-06)

| item | value |
|---|---|
| factory 0x4959 | deprecated=true, deployFee 0.069 eth, defaultProtocolFeeBps 2000, teamFeeRecipient 0xCB43 (owner eoa) |
| factory 0xf051 ("open", version "3") | deprecated=false, deployFee 0, has `deployTokenWithProtocolBps`, hook 0xAAd6 and locker 0xd914 enabled. anyone can launch today |
| coin 111 | taxEnabled, taxBps 1500, taxBpsMax 2000, canonicalHook 0x636c, canonical pool eth/111 dyn fee, tickSpacing 200 |
| 111 tax sink | `taxBurnAddress` = 0xf5c3eC7e…8753, a contract (2095 bytes), not 0xdEaD |
| 111 admin | 0xA96a…6258 (contract, also originalAdmin), renderer 0x7604…eEc7, isVerified=false |
| 111 venues | v2 weth, v2 usdc, v3 weth 100/500/3000/10000, v3 usdc 1% are venues. sushi v2 weth is not |
| 111 exempt | locker 0x866e exempt. escrow, hook, sink not exempt |
| 111 locker split | one slot, 10000 bps, admin 0xdEaD, recipient 0xeBD9…A961. launched with protocol bps 0 (owner override) |

## findings

| id | sev | title | live? |
|---|---|---|---|
| FT-01 | high | canonical tax exemption budget can be minted for free by add+remove on the canonical pool, then spent on any side venue | yes, coin 111 |
| FT-02 | medium | launch hijack: token address binds only factory + tokenAdmin + salt + ctor args, not sender or pool/locker/extension config | yes, factory 0xf051 |
| FT-03 | medium | `deployTokenWithProtocolBps` lets any permitted caller set protocol bps to 0 | yes, factory 0xf051 |
| FT-04 | low | an allowlisted hook/locker/extension/mev module cannot be disabled once its erc165 answer changes | no |
| FT-05 | medium | coin mutable after launch beyond the renderer (image, metadata, tax rate, admin) | yes, all coins |
| FT-06 | low | tax config is not bound to the pool the factory creates | owner only today |
| FT-07 | medium (if public) | tax sink and exempt list are arbitrary deployer input: 20% buy tax to self, self exempt | owner only today |
| FT-08 | low | venue set frozen at construction, covers only listed (factory, counter, fee) tuples; sub 7 wei buys untaxed | partial |
| FT-09 | info | extension rounding dust stays in the factory, swept to team | yes |
| FT-10 | low | protocol slot injection silently truncates mismatched reward arrays | owner only today |
| FT-11 | low | escrow `claim` is a permissionless push; a griefer can strand an erc20 balance in a fee owner contract before it calls `claimTo` | yes |
| FT-12 | info | `TokenCreated` is incomplete | yes |
| FT-13 | info | misc: ownable single step + renounce, escrow depositors add only, permit2 fixed infinite allowance, no votes | yes |

### FT-01 high: free canonical exemption budget

evidence: `ArtCoinsToken.sol:281-307` (budget consumed by ANY venue outflow), `:318-323`, `:342-356` (accumulates, fungible within tx). hook side: `ArtCoinsHookSkimFee.sol:455-467` attests every canonical `afterRemoveLiquidity` from the pool delta, `:479-493`, and `afterSwap` at `:387`. v4 `PoolManager.modifyLiquidity` passes `callerDelta = principal + fees` to the hook before any token moves (`lib/v4-core/src/PoolManager.sol:169-176`).

mechanism: the attested amount is a pool delta, not a token transfer. in one unlock:
1. `modifyLiquidity(canonical, +L)` on a single sided range below price. caller owes X PCT (delta only, nothing paid).
2. `modifyLiquidity(canonical, -L)`. caller is owed X back. hook attests X. budget += X.
3. net PCT delta ≈ 0 (1 to 2 wei rounding). nothing leaves the pool manager for the canonical pool, so the budget is never consumed by a canonical outflow.
4. buy on any side v4 pool (same pool manager) or a listed v2/v3 pair. its outflow consumes the budget and is untaxed.

answers to the prior pass questions:
| question | answer |
|---|---|
| partial amounts | every removal call attests its own delta; partial removals each add budget |
| multiple positions | budget sums across positions and across repeated add/remove of the same position. unbounded in practice, cost is gas plus a wei or two |
| donations | `donate` has no attest hook, but a `liquidityDelta == 0` poke routes to `afterRemoveLiquidity` and attests collected fees, so donate+poke as sole in range lp also mints budget. dominated by add/remove |
| other mint paths | canonical buy then sell in the same unlock (no take) mints budget at the cost of fees; a canonical buy whose output feeds a second hop without `take` leaves budget behind |
| capital needed | none. flash accounting nets the add and the remove |
| window | blocked only while the mev skim module is operational (`_beforeAddLiquidity`) |

proof:
- `test_bug_FT01_live111_addRemoveCanonicalSkipsSidePoolTax` (fork, live 111): baseline side pool buy of 183,185 PCT pays 27,477 tax. same buy after add+remove of L=1e22 on the canonical pool: hook attests 7,819,294 PCT, router spends ≤ 2 wei, bob receives the full 168,474 PCT.
- `test_bug_FT01_unbackedCanonicalBudgetExemptsSideVenues` (unit): two stacked attestations exempt a v4 side buy and a v2 pair buy, then tax resumes.
- the hooks reviewer has the same mechanism at hook level (`test/v2/review/hooks-mev/TaxBudget.t.sol`, H14).

fix for v2: do not attest from pool deltas. options, best first: (a) drop the budget model: exempt by recipient (canonical router / position manager allowlist) or tax only non canonical pools by having the hook mark side pools; (b) attest only in `afterSwap`, and burn the budget on any canonical `beforeAddLiquidity` in the same tx (tstore a "lp touched" flag and zero the budget), and never attest on removal; exempt lp exits by exempting the locker and the v4 position manager as recipients instead; (c) bind the budget to the take: key it by recipient (hook passes `sender`) and consume only on transfers to that recipient. any variant must be tested against add+remove, buy+sell round trip, and multi hop.

### FT-02 medium: launch hijack

evidence: `ArtCoinsDeployer.sol:49-61`. salt = `keccak256(abi.encode(tokenAdmin, tokenConfig.salt))`. the library is `external`, so it runs by delegatecall and the create2 deployer is the factory.

| bound into the address | not bound |
|---|---|
| factory address | `msg.sender` |
| tokenAdmin, salt | poolConfig (hook, pairedToken, start tick, tickSpacing, poolData) |
| name, symbol, supply, image, metadata, context, renderer (ctor args in initcode) | lockerConfig (reward admins, recipients, bps, positions) |
| full taxConfig (ctor arg) | extensions + their bps and eth, mev module + data, sniper config, protocol bps |

attack: watch the mempool (or an announced address), copy `tokenConfig` (and `taxConfig` if any), submit first with attacker reward recipients/admins, a 90% vault/dev buy extension paid to the attacker, an absurd start tick. the token lands at the planned address; the real launch reverts on create2 collision. only `tokenAdmin` stays with the victim. for a taxed coin the attacker can also pick a different pool tickSpacing so the factory pool is not the token's canonical pool (FT-06), making every buy from it taxed.

proof: `test_bug_FT02_launchHijackSameAddressDifferentConfig` (unit, also shows the off chain prediction formula matches); `test_bug_FT02_FT03_liveOpenFactoryHijackAndZeroProtocol` (fork, live public factory 0xf051).

fix: v2 salt = `keccak256(abi.encode(msg.sender, keccak256(abi.encode(deploymentConfig)), protocolBps, userSalt))`, or at least sender + tokenAdmin + salt. now: call `setDeprecated(true)` on 0xf051 (public, zero fee, nothing launched).

### FT-03 medium: protocol bps override is caller chosen

evidence: `ArtCoinsFactory.sol:176-185`, `:388-393` (bps 0 returns the config untouched, skips the team recipient and sum checks). any caller who passes the deprecated gate picks 0..3000. the default 2000 is only a default.

proof: `test_bug_FT03_publicCallerZeroesProtocolSlot` (unit), live leg of `test_bug_FT02_FT03_liveOpenFactoryHijackAndZeroProtocol` (0xf051: locker records one 10000 bps slot for the attacker). on 0x4959 only owner/admins can call; coin 111 itself was launched with 0.

fix: gate the override (`onlyOwnerOrAdmin`) or replace with a floor (`protocolBps >= defaultProtocolFeeBps` for public callers).

### FT-04 low: cannot disable an allowlisted contract whose erc165 changes

evidence: `ArtCoinsFactory.sol:119-151`. the interface check runs on disable too. a contract that reverts or returns false from `supportsInterface` (bug, proxy upgrade, deliberate) can never be removed; only `setDeprecated(true)` stops it, and owner/admin deploys still reach it.

proof: `test_bug_FT04_cannotDisableExtensionWhoseInterfaceCheckFails`. fix: check the interface only when `enabled == true`.

### FT-05 medium (v2 principle): coin mutable beyond the renderer

evidence: `ArtCoinsToken.sol:467-473` updateAdmin, `:487-500` updateImage / updateMetadata, `:363-370` setTaxBps (0..taxBpsMax, so a 15% coin can go to 20%), `:507-513` setMetadataRenderer. only `name`, `symbol`, `context`, supply, tax caps, venues, exempt list, sink are fixed.

proof: `test_bug_FT05_tokenAdminMutatesMoreThanRenderer`. fix for v2: drop `updateImage`/`updateMetadata` (move display data behind the renderer), make tax rate immutable or decrease only, keep `setMetadataRenderer` + admin transfer + renounce.

### FT-06 low: tax config not bound to the factory pool

evidence: `ArtCoinsFactory.sol:200-209` passes `taxConfig` straight to the token; nothing checks `canonicalHook == poolConfig.hook`, `pairedToken`, `canonicalTickSpacing == poolConfig.tickSpacing`, fee = dynamic flag, `poolManager == hook.poolManager()`. a mismatch launches a coin whose own launch pool is a taxed side pool and whose lp exits are taxed.

proof: `test_bug_FT06_taxCanonicalPoolNotBoundToFactoryPool`. fix: factory derives the tax canonical fields from `poolConfig` and the hook, or asserts `token.canonicalPoolId() == poolKey.toId()` after init.

### FT-07 medium if the and-tax path is public: arbitrary tax sink and exemptions

evidence: `ArtCoinsToken.sol:186-204`, `:412-416`. `burnAddress` is any non zero address, `exempt` any list, rate up to 20%, admin can raise to the cap. on a public factory this is a ready made 20% buy tax paid to the deployer while the deployer buys untaxed. the sink is surfaced only by `taxBurnAddress()` and the token's `TaxEnabled` event, not by `TokenCreated`. on 111 the sink is a contract, not 0xdEaD; the name "burn" is not enforced.

proof: `test_bug_FT07_publicDeployerRoutesTaxToSelfAndExemptsSelf`. fix: restrict the and-tax entry to owner/admin, or fix the sink to 0xdEaD / a protocol contract, cap exempt list to protocol contracts, emit the tax config in the launch event.

### FT-08 low: venue coverage

evidence: `ArtCoinsToken.sol:385-387`, `:412-462`. venues are frozen (no add path); any dex, counter token or fee tier not listed is a tax free side venue. live 111 lists uniswap v2/v3 weth and usdc tiers, so the practical gap is other dex factories (sushi verified not taxed) and other counter tokens. rounding: `tax = taxable * bps / 10000` floors, so outflows below 7 wei at 15% pay nothing (not economic).

proof: `test_bug_FT08_unlistedVenuesAreUntaxed`. fix: accept; document. if the tax survives into v2, prefer taxing by "not the canonical pool" at the hook level (see FT-01) over enumerating venues.

### FT-09 info: extension rounding dust

evidence: `ArtCoinsFactory.sol:371` floors the summed bps, `:430` floors each extension; up to n-1 wei stays in the factory and `claimTeamFees` (`:108-113`) sends it to the team. any allowance an extension or locker does not pull also stays. proof: `test_bug_FT09_extensionRoundingDustSweptToTeam`. fix: give the remainder to the pool supply (compute pool supply as total minus the sum of per extension floors).

### FT-10 low: reward array truncation

evidence: `ArtCoinsFactory.sol:397-419` loops over `rewardBps.length` and rebuilds all three arrays from it; extra admins/recipients are dropped and the protocol slot takes the next index, so the locker never sees the mismatch. with bps 0 the arrays pass through unchecked. proof: `test_bug_FT10_mismatchedRewardArraysTruncatedByInjection`. fix: require equal lengths before injection.

### FT-11 low: escrow forced push

evidence: `ArtCoinsFeeEscrow.sol:85-99`. `claim` is permissionless and pushes to `feeOwner`. `claimTo` (`:102-125`) exists for owners that cannot receive, but for an erc20 a push to a contract that cannot move erc20s succeeds, and anyone can front run the owner's `claimTo`. eth pushes that fail just revert (no loss). proof: `test_bug_FT11_escrowForcedClaimStrandsErc20InFeeOwner`. fix: make `claim` callable only by `feeOwner` (or an approved operator), keep `claimTo`.

### FT-12 info: launch event incomplete

`IArtCoinsFactory.sol:173-190`, emitted at `ArtCoinsFactory.sol:278-295`. missing: total supply, renderer, salt, tickSpacing, poolData, protocol bps used, reward admins/recipients/bps, positions, mev module data, sniper config, extension bps/eth (partly in `ExtensionTriggered`), tax config (only in the token's own `TaxEnabled`). `startingTick` is `tickIfToken0IsArtCoins`, not the real starting tick when the coin sorts as token1 (always, for native eth pairs). `DeploymentInfo` (`:271-276`) also lacks the pool key. fix: emit `keccak256(abi.encode(deploymentConfig))` plus supply, protocol bps, pool id; indexers can then verify calldata.

### FT-13 info: misc

| item | evidence | note |
|---|---|---|
| ownable single step, renounce enabled | `OwnerAdmins.sol:5,9`, escrow `:6,20` | renounce on the factory freezes allowlists and `recoverETH`; use Ownable2Step and disable renounce in v2 |
| admins equal owner for deploy safety | `OwnerAdmins.sol:19-28`, factory `:119-151,222` | an admin can allowlist any extension/hook and deploy while deprecated |
| escrow depositors add only | `ArtCoinsFeeEscrow.sol:31-34` | harmless (depositors can only add value), but retired lockers/hooks cannot be revoked |
| protocol slot admin is the factory | `ArtCoinsFactory.sol:413-414`, locker `:527-552` | factory has no call to the locker, so per coin protocol recipients can never rotate (0x4959 team recipient is the owner eoa) |
| permit2 fixed infinite allowance | solady `ERC20.sol:165-196,594-598` | holders cannot revoke permit2; documented design |
| no votes extension | `ArtCoinsToken.sol:33` | the prior brief assumed erc20votes; none exists, no checkpoint risk |
| transfer to address(0) allowed | solady `_transfer` | tokens lost without supply drop; burn() exists |
| tax hits pool manager flash takes and v2 multi hop | `ArtCoinsToken.sol:281-307` | flash borrowing 111 from v4 costs 15%; v2 routes with 111 mid route revert (fee on transfer). expected |
| state written after extensions run | `ArtCoinsFactory.sol:263-276` | extensions see empty `tokenDeploymentInfo`; mev module initialized after extensions, so a dev buy runs before mev protection (by design for the deployer's own buy) |

## claims from the prior pass that hold

| claim | why it holds |
|---|---|
| tax exemption minted by add then remove | confirmed and extended, FT-01, live on 111 |
| create2 salt ignores sender and pool config | confirmed, FT-02, live on 0xf051. note: ctor args (name, symbol, image, metadata, context, renderer, supply, taxConfig) ARE bound |
| deploy fee exact match, no refund path needed | `ArtCoinsFactory.sol:353-369` requires `msg.value == fee + Σ msgValue`. `test_holds_deployFeeExactAndExtensionEthIsolated` |
| fee sink | `teamFeeRecipient`, paid by call before pool init (`:374-382`); reverts if unset and fee > 0; owner/admin deploys pay too |
| deprecated gating | owner or any admin bypasses (`:222`). `test_holds_deprecatedGate` |
| extension eth isolation | each extension gets exactly its `msgValue`; the fee is forwarded first; stray factory eth cannot be spent by a deployer. same test |
| reentrancy via extensions / dev buy | all three deploy entries are `nonReentrant`; other external functions need owner/admin. no path found |
| protocol bps cap 3000 | enforced on setter and both override entries (`:87,180,205`); but see FT-03 for the floor |
| token json escaping | default `contractURI` escapes name, symbol, description, image with `LibString.escapeJSON`. `test_holds_contractUriEscapesJson`. a custom renderer's output is not escaped (renderer's job) |
| tax cap 20% | `TAX_BPS_ABSOLUTE_MAX = 2000`, ctor rejects above, setter bounded by `taxBpsMax` |
| tax sink fixed | immutable, surfaced by `taxBurnAddress()` and `TaxEnabled`; not in `TokenCreated` |
| venue list add only | stronger: no add path at all, frozen in ctor; exempt list frozen too |
| supply min 1 token, overflow | `MIN_TOKEN_SUPPLY = 1e18`; huge supplies revert in checked math or the locker's int128 cast, no silent overflow |
| permit / nonces | stock solady permit, name hash read live (name immutable in practice), nonces per owner |
| burn accounting | `_burn` lowers supply; `burnFrom` spends allowance; permit2 never calls `burnFrom` |
| escrow reentrancy on claim | `nonReentrant` and state zeroed before the transfer |
| escrow native eth | only `storeFeesNative` (depositor gated) accepts eth; no `receive`; no rescue path |
| who can credit escrow | allowlisted depositors only; credit is balance delta for erc20, `msg.value` for eth |
| verification helper | it is `verify()` (one shot, original admin, event only). original admin is immutable. 111 is unverified |

## legacy comparison

`src/legacy/ArtCoinsFactory.sol` differs only by the protocol bps override entries, the tax entry, `receive()`, and the mev module interface. same salt scheme (FT-02 applies), same fee and extension accounting, same disable check (FT-04).

## not verified

| item | why |
|---|---|
| bytecode of 0xf051 vs any repo commit | registry marks it version "3", not head. fork proof shows FT-02/FT-03 behaviour on it directly |
| identity of 111's tax sink 0xf5c3 and admin 0xA96a | unverified source; etherscan v2 needs a key. comments say admin is permanent-collection's TokenAdminPoker |
| 111's full exempt list | not enumerable on chain; checked locker (exempt), escrow, hook, sink (not) |
| hook side over attestation from skim deltas on exact output | hooks reviewer's area |
| `ArtCoinsVault`, dev buy, airdrop internals | extensions reviewer's area; only the factory side of value and allowance flow was checked |
