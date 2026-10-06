# v2 review: factory and launch flow

independent review. scope: `src/v2/ArtCoinsFactoryV2.sol`, `src/v2/utils/ArtCoinsDeployerV2.sol`, `src/v2/interfaces/IArtCoinsFactoryV2.sol`, and the launch path through `ArtCoinsTokenV2`, `ArtCoinsHookV2.initializePool / initializeMevModule`, `ArtCoinsLpLockerV2.placeLiquidity`, `ArtCoinsMevLinearSkimV2.initialize`, `src/v2/extensions/`, `ArtCoinsFeeEscrowV2`.

base: started at 3f70dea; the factory and token changed under me (D47 exempt allowlist, D48 venue admin transfer, now in 267543e) and the hook and `HookCalldata` were still being patched (D41 to D44) during the runs. factory line numbers match 267543e; hook line numbers will drift.

proofs: `test/v2/review-v2/factory/V2FFactoryReview.fork.t.sol`. forks mainnet at the harness pin (26_130_269), deploys the real v2 stack as `test/v2/FactoryV2.fork.t.sol` does, skips without an rpc.

```
/tmp/claude-0/forge.sh test --match-path "test/v2/review-v2/factory/*" \
  --skip "test/v2/harness/Harness.t.sol" --skip "test/v2/review/**" --skip script -vv
```
5 tests, all pass (default profile). package suite `test/v2/FactoryV2*`: 32 pass with the same skips. no file had to be skipped for compile errors.

## findings

| id | sev | title | evidence | attack path | proof | fix |
|---|---|---|---|---|---|---|
| V2F-01 | medium | `minProtocolSkimShareBps` is not a floor: the launcher's referral cap can take the whole protocol skim leg | factory `_validateFee` `ArtCoinsFactoryV2.sol:353-363` bounds `bountyBps` only, never `maxReferralBpsOfVolume`. hook `_split` `ArtCoinsHookV2.sol:464-477` pays the referral out of the protocol leg (`if (referral > protocol) referral = protocol; protocol -= referral`). ui `encodeV2.ts:288` tells launchers "the protocol keeps at least X% of the skim" | owner sets min share 2000. public launcher: baseline 1%, bounty 8000 (the max accepted), referral cap 1% (max). every swap that names any referrer (D44: a router user may name its own wallet) moves 100% of the protocol leg to the referrer. a launcher front end names the launcher or the user and the protocol earns 0 on all its volume. with the deploy default `minProtocolSkimShareBps = 0` (`script/v2/DeployV2Lib.sol:125`) bounty may be 9999 and the protocol skim is launcher optional even without a referrer | `test_V2F01_referralCapZeroesProtocolSkimFloor`: 1 eth buy, protocol leg 0.002 eth without referrer, 0 with one; referrer receives 0.002 eth | factory: require `maxReferralBpsOfVolume * BPS <= baselineSkimBps * (BPS - bountyBps - minProtocolSkimShareBps)`, so referral is paid from the part above the floor. or store the floor in `SkimConfig` and cap `referral` at `protocol - floor` in the hook. set a nonzero min share in the deploy lib |
| V2F-02 | low | `lpFee` has no floor, so the protocol locker slot (the FT-03 fix) can be worth nothing | `_validateFee` `:355-358` checks only `lpFee > MAX_LP_FEE`. protocol slot appended at `_placeLiquidity` `:561-581` is a share of lp fees | public launcher sets `lpFee = 0` and moves all its fee into the skim bounty it controls. the 20% protocol slot is appended and the locker pays it 0 forever. together with V2F-01 the deploy fee is the only protocol revenue a public launcher cannot opt out of | same test: after two swaps `locker.collectRewards` pays `protocolR` 0 eth and 0 coin | decide what the protocol is owed per coin and enforce it in one unit: a `MIN_LP_FEE`, or a protocol share expressed on total fee (lp fee plus skim), checked by the factory. if skim only is intended, say so in DESIGN section 2 and drop the claim that the slot protects revenue |
| V2F-03 | low | a config the factory accepts can exceed the EIP-7825 per tx gas cap (16,777,216) | caps: D30 strings (10,320 bytes), 7 slots, 14 positions, 16 exempt, 32 venues, 10 extensions. none of them are checked against a gas budget | a launcher (or the ui) builds a config at the caps. `deployToken` needs 19.6m gas: the tx is invalid on mainnet, or runs out of gas if the wallet caps the limit. the string caps alone cost 12.3m. self dos only, no third party harm | `test_V2F03_maxConfigLaunch_overTxGasCap` (19,604,057 gas), `test_gas_breakdown` (table below) | lower the string caps (metadata and context share one 4 KiB budget, image url 512) or cap total string bytes; the ui must `estimateGas` and refuse above ~15m before asking for a signature |
| V2F-04 | low | D38: `isArtCoin` no longer implies `ArtCoinsTokenV2` code. the owner can repoint launches at a deployer that creates any token | `setTokenDeployer` `:725-736` checks only `factory() == this` and `constantsHash()`. `_checkCanonical` `:534-544` and hook `initializePool` read getters only. deployer `:50-66` is the only place the token code is fixed | owner key (single eoa, D20) or a compromised key deploys a contract that answers `factory()` and `constantsHash()` and creates a subclass of `ArtCoinsTokenV2` with a mint or an admin transfer hook. every later launch is registered `isArtCoin`, gets an official pool on the hook and the locker, and passes every factory check. integrators are told to trust `isArtCoin` (d6) | trace (owner trust; no proof test, low) | make the pointer set once (the reason for D38 was size, not rotation), or require a delay plus event before a new deployer is used. alternatively pin `keccak256(type(ArtCoinsTokenV2).creationCode)` in the factory and have the deployer expose the hash it deploys |
| V2F-05 | info | the factory comment says rounding dust goes to the pool; the locker sends its rounding dust to DEAD | factory `:56-58`; locker `ArtCoinsLpLockerV2.sol:126-130` (per position floors plus liquidity rounding) | wei scale (at most ~n positions wei plus liquidity rounding), not exploitable | read | fix the comment, or give the last position the remainder |
| V2F-06 | info | launcher chosen code runs inside the launch tx before `initializeMevModule` | dev buy refunds unspent eth to `refundRecipient` with a full gas call (`ArtCoinsUniv4EthDevBuyV2.sol:105-110`); factory refunds excess to `msg.sender` (`:310`, after the module init) | only on a partial dev buy fill. the recipient runs while the anti sniper window has not started and the add lock is off. it is the launcher's own tx, so nothing a launcher could not do from its own contract; no third party can reach it | trace | none needed; document. optionally move `initializeMevModule` before extensions and give the dev buy an explicit baseline (v1 parity was the reason for the order) |
| V2F-07 | info | recipients the factory accepts that can never be paid | `_validateLocker` `:366-379` rejects zero only; locker rejects only itself | a project reward recipient equal to the factory or the coin: eth pushes fail, the escrow credits an address with no claim path (factory has no `receive` and no escrow call). stranded for that slot only. same class as V2H-08 on the hook side | trace | reject `address(this)` in the factory and `token` and `msg.sender` in `placeLiquidity` |
| V2F-08 | info | owner can reprice a pending launch | `setDeployFee` `:744`, `setProtocolRecipient`, `setReferralPayout`, `setMinProtocolSkimShareBps` take effect for the next block; launch has no expected value parameters | owner front runs a launch that sent excess eth: raises `deployFee` up to `msg.value - Σ msgValue` (capped at `MAX_DEPLOY_FEE`, 1 eth). recipient changes are silent. bps changes make launches revert, which is the right failure | trace | owner trust (D20). ui should send the exact fee; an additive `deployTokenWithMaxFee` would close it |
| V2F-09 | info | no maximum supply | `_supply` `:250-254` | supplies up to ~1e36 launch and trade; above that the locker liquidity math reverts. affects only the launcher's own coin | trace | optional `MAX_TOKEN_SUPPLY` (e.g. 1e30) for integrator sanity |

## gas (default profile, token creationCode 21,044 bytes, initcode at max config 38,004 of 49,152)

tx gas = measured execution plus 21k and calldata (EIP-7623 floor checked). separate launches; the breakdown rows run in one test so later rows see some warm slots.

| config | calldata bytes | tx gas |
|---|---|---|
| typical: 2 positions, mev module, no tax, no extensions | 2,180 | 4,843,900 |
| strings at D30 caps only | 12,356 | 12,267,884 |
| 7 reward slots + 14 positions only | 3,652 | 6,810,973 |
| VENUE, 16 exempt + 32 venues only | 7,812 | 7,488,004 |
| 10 extensions (9 vaults + 1 eth dev buy) only | 5,060 | 6,678,547 |
| every cap except extensions | 19,460 | 17,013,143 |
| every cap (V2F-03) | 22,340 | 19,604,057 |

token deployment (code deposit plus string storage) dominates. a launch with 1 to 2 KiB of strings and a handful of positions sits around 5 to 7m. ci profile (runs 200) not measured; it changes the code deposit by a few hundred thousand gas, not the conclusion.

## claims that hold

| claim | why it holds | test |
|---|---|---|
| value accounting: each extension gets exactly its `msgValue`, fee pushed to team, excess refunded, factory ends with 0 eth | `required = fee + Σ msgValue` checked before any call (`:266-268`); `receiveTokens{value: e.msgValue}` (`:606`); factory has no `receive`, so an extension cannot hand value back into the refund; `_settleEth` last (`:310`, `:620-628`) | package `test_extensions_valueAndSupplyIsolated`, `test_deployFee_*`; `test_holds_hardCoinLaunchesWithDevBuyAndTrades` asserts factory eth 0 |
| extension pulls more or less than its share | allowance is exactly the share and reset after; balance delta must equal share (`SupplyNotPulled`) | package `test_extensions_mustPullExactShare` |
| extension that reverts after taking value | single tx, everything reverts, nothing recorded | by construction |
| reentrancy from an extension, the dev buy, the refund or fee push | both entries `nonReentrant` (transient); owner setters need `owner` and the extension is `msg.sender`; locker and hook launch calls require the factory as launcher; mev `initializeMevModule` requires `info.launcher` | package `test_extensions_reentry_blocked` |
| salt binds sender and the full config | `salt = keccak256(abi.encode(sender, keccak256(abi.encode(c))))`; `abi.encode` of one fixed type is injective, so no two configs (strings, arrays, `extensionData` boundaries) share a hash; protocolBps is owner only so the owner path needs no extra binding | package `test_launch_frontrunCopiedConfig_differentAddress`, `test_launch_changedLockerConfig_differentAddress` |
| predict equals deploy | `deploy` and `predict` hash the same `_initCode`; factory passes the same supply, canon, launcher and salt; a replaced deployer moves the prediction with it | package `test_launch_predictTokenMatches`, `test_tokenDeployer_replaced_predictFollows` |
| deployer cannot be called or front run by others | `NotFactory`, `LauncherMismatch`; the CREATE2 origin is the deployer and only the factory computes the salt with `msg.sender`, so nobody can occupy a victim's address. same sender and config twice: second CREATE2 fails `DeployFailed` (change `token.salt`) | package `test_tokenDeployer_setAndRequired` |
| supply accounting | `poolSupply = supply - Σ floor(bps * supply / BPS)`, extension bps capped at 9000, factory holds 0 coin after launch | package `test_dust_toPool_neverTeam` |
| locker slot construction (FT-10) | project lengths checked before the protocol slot is appended; zero recipient and zero bps rejected; sum including the protocol slot must be BPS; slots <= 7; `protocolBps == 0` (owner only) appends nothing. duplicates are accepted and harmless | package `test_bpsSumRules`, `test_protocolBps_ownerOnlyOverride` |
| `minProtocolSkimShareBps` vs `protocolBps` | different units by design: protocolBps is the locker lp fee slot, min share caps the skim bounty. both are bypassable economically (V2F-01, V2F-02), the checks themselves are correct | V2F-01 test |
| hook init fields | dynamic fee flag, eth currency0, coin currency1, `-tickIfToken0IsArtCoin`, lp fee set once; token requires `tickSpacing > 0`, the PoolManager bounds the rest; launcher is the factory; `_beforeInitialize` always reverts so no foreign init; locker rejects ranges below the start so every position is coin only at init (a range touching the start is valid: current tick equals the mirrored upper) | package `test_realLocker_launch`, `test_versionTag_*` |
| `initializeMevModule` with no module | factory sends empty bytes, hook skips the module call and still arms `_started` | `test_V2F01_*` launches with no module and trades; package `test_mevConfigBounds` for the bounds |
| tax binding (FT-06) | token derives its canonical pool from hook, tickSpacing and PoolManager; hook checks `canonicalHook`, `canonicalPoolId`, `launcher`; factory re checks hook, pool id, PoolManager, mode and sink after init | package `test_factoryV2_taxSinkOutsideAllowedSet_reverts` |
| HARD coin launches and trades | `placeLiquidity` settle into the PoolManager is covered by the hook's `afterAddLiquidity` IN grant; a dev buy `take` and public buy and sell are covered by `afterSwap` grants; a bare transfer to the PoolManager still reverts | `test_holds_hardCoinLaunchesWithDevBuyAndTrades`, package `test_taxedLaunch_hard_placesAndTrades` |
| venues | derived addresses are hashes, so a venue cannot be aimed at the locker, escrow or a holder; the PoolManager (the canonical pool's custodian), the hook, the launcher and the token are refused | read, `TaxVenues.sol`, token `_addVenue` |
| exempt set (FT-07, V2A-02) | D47: every entry must be owner allowlisted or this launch's locker, hook, an enabled escrow or extension, and have code. this also closes the EIP-7702 variant (a delegated eoa has 23 bytes of code and passed the old code length rule). none of the implicit entries has a public sweep | package `test_exemptAllowlist` |
| sink rule (D10) | VENUE: DEAD or bounty recipient; HARD: 0, DEAD or bounty recipient; NONE: nothing configured. factory and token agree | package `test_factoryV2_taxSinkOutsideAllowedSet_reverts` |
| owner surface | every setter bounded by Constants; Ownable2Step; `renounceOwnership` reverts (FT-13); disabling never calls the target (FT-04); no `claimTeamFees`, fees are pushed so `rescue` never reaches team money or user eth; `deployTokenAsOwner` is the only protocolBps override (FT-03) and works while deprecated; public `deployToken` blocked while deprecated, owner bypasses | package `test_owner_setterBounds`, `test_disable_failingModule`, `test_deprecated_gate_ownerBypasses`, `test_rescue_ethAndErc20` |
| launch event (FT-12) | `TokenCreatedV2` carries the full config, config hash, injected recipients, protocol bps and both supplies. derivable: default supply, venueAdmin default, mev end value (= baseline), extension shares, venue addresses (token `TaxVenueAdded`) | package `test_event_fullConfig` |
| `isArtCoin` / `deploymentInfo` | written only in `_record` inside a launch; CREATE2 makes a second record for one address impossible; keyed by address, so a same name token is irrelevant (but see V2F-04) | read |
| DoS by other users | nothing a launch writes is shared with other coins except append only records; per launch loops are bounded by Constants | read |

## v1 findings the factory claims to fix

| v1 | status in v2 |
|---|---|
| FT-02 launch hijack | fixed (sender and full config in the salt) |
| FT-03 caller chosen protocol bps | fixed as a gate; economically bypassable, V2F-02 |
| FT-04 cannot disable | fixed |
| FT-06 tax not bound to factory pool | fixed |
| FT-07 arbitrary sink and exempt | fixed (D10 sink, D47 exempt allowlist) |
| FT-09 extension dust to team | fixed (dust to pool supply; the locker then sends its own rounding to DEAD, V2F-05) |
| FT-10 array truncation | fixed |
| FT-12 incomplete event | fixed |
| FT-13 ownable single step, renounce | fixed |
| FT-01, FT-05, FT-08, FT-11 | token, hook and escrow scope; not re reviewed here |

## not verified

| item | why |
|---|---|
| gas at the ci profile (runs 200) | measured at the default profile only |
| airdrop as a launch extension | only vault and dev buy were run in a launch; airdrop shares the same factory path |
| pool extensions (`initializePreLockerSetup` / `PostLockerSetup`) | none are ported (D27); the hook path exists but nothing exercised it |
| dev buy partial fill refund and escrow dust claim inside a launch | needs a buy that exhausts all launch liquidity; not built |
| hook behaviour after the in flight D41 to D44 patch lands | runs used the working tree at review time; rerun this suite after the hook commit |
| mainnet block gas limit and EIP-7825 activation height | not read from chain; the cap is a protocol constant since fusaka |
