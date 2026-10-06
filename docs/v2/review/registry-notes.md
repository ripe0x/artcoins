# registry notes (job 1)

deployment registry for artcoins mainnet, derived from chain reads and broadcast records, not from memory. written for the next agent that points readme, ui and scripts at it.

| artifact | path |
|---|---|
| registry (single source of truth) | `deployments/mainnet.json` |
| checker and filler | `script-js/verify-registry.mjs` (node 22, `viem` only) |
| deps | `script-js/package.json` (viem added, existing deps untouched) |
| ci | `.github/workflows/registry.yml` |
| this file | `docs/v2/review/registry-notes.md` |

registry generated against repo commit `f99442250a7ac9e6f1c2d4b422d992dc8e32270b` (branch v2). `src/` has been identical to the squashed first commit `a60bf15` for every contract in the registry, other agents only added new files under `src/v2` and `src/Constants.sol`.

## headline answers

| question | answer | evidence |
|---|---|---|
| which factory is current | `0x49596c375c139E79bb937bcf826068a8F78D4e0e` (stack `current`) | deployed 2026-06-06 block 25260062, owner `0xCB43…17F9`, `deprecated()` true, `version()` "1", `deployFee()` 0.069 eth, launched coin 111, `enabledHooks`/`enabledLockers`/`enabledMevModules` point at hook 0x636c, locker 0x866e, mev 0xb038 |
| does 0x4959 match repo head | yes, for runtime code, under profile `ci` (optimizer_runs 200) | table below: factory, hook, locker, escrow, mev module, token, controller and both external libraries are byte equal to a head build once immutable slots, library link slots and the metadata hash are masked. under the default profile (runs 20000) it does not match: factory 15029 bytes vs 12662 on chain |
| caveat on that match | on-chain code carries ipfs metadata, head's foundry.toml disables it | chain code is exactly 53 bytes (one cbor block) longer than a head build with metadata off, same bytes before it. a head build with metadata on has identical length, identical bytes, and a different 32 byte ipfs hash. the hash covers settings, remappings and source text, so it proves nothing either way. the deploy used a different foundry config than head (tune profile, metadata on) |
| does the broadcast folder contain 0x4959 | no | no file in `broadcast/` mentions 0x4959, its hook, locker, escrow, mev module, libraries, controller 0xd8c6, burn router 0x0EB2 or fee swapper 0xeBD9 |
| last factory in broadcast | `0xf051cd4c4f3f36f9f24d8a19d60ee8f84fc6793e` (open stack, 2026-05-19) | `DeployNativeEthStack.s.sol/1/run-latest.json`. it is not current and not at head: `version()` returns "3", head returns "1" |
| zero coins on 0xf051 | confirmed | `TokenCreated` logs on 0xf051 from block 25125708 to head: 0. its locker emitted 1 log (ownership), its hook 0 logs, its escrow 3 logs (ownership, depositors). no pool was ever initialised on its hook |
| coins launched in total | 2 | LAYER (legacy factory 0xd159, block 25045152) and 111 (current factory 0x4959, block 25275351). `TokenCreated` count: legacy 1, open 0, current 1 |
| etherscan data | not available | `api.etherscan.io/v2` answers `Missing/Invalid API Key` without a key, so `etherscanVerified` is `unknown` everywhere. creator, creation tx and verification flags came from blockscout (`eth.blockscout.com/api/v2/addresses/<addr>`) and are in each contract's notes as `blockscout verified/unverified` |

## stacks

| id | factory | deployed | status | public deploys | deploy fee | coins | notes |
|---|---|---|---|---|---|---|---|
| legacy | 0xD1595A2742C392d1c109b616b4F08918D02292f9 | 2026-05-07 | legacy | no (`deprecated` true) | 0 | LAYER | static fee hook V2, multi position locker, fee locker, 4 mev modules, vault, airdrop, burn ext, dev buy. teamFeeRecipient is controller 0x5fdc |
| open | 0xF051cd4C4F3F36F9f24d8a19d60Ee8F84FC6793e | 2026-05-19 | superseded | yes (`deprecated` false) | 0 | none | static fee hook, no skim, no tax. teamFeeRecipient is burn router 0xe600. still callable by anyone today. its allowlist 0xd6d5 is reused by the current hook |
| current | 0x49596c375c139E79bb937bcf826068a8F78D4e0e | 2026-06-06 | current | no (`deprecated` true) | 0.069 eth | 111 | skim hook, lean locker, escrow, linear skim module. teamFeeRecipient is the owner |

owner of nearly everything: `0xCB43078C32423F5348Cab5885911C3B5faE217F9` (single eoa). every `owner()` in the registry equals it. protocol payout `0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4` is a 0xSplits pass through wallet clone (implementation `0xfE87400C…`), also owned by the eoa.

### factory 0x4959 timeline from its own events

| utc | block | event |
|---|---|---|
| 2026-06-06 18:11 | 25260062 | deployed, owner set (constructor sets deprecated true) |
| 2026-06-06 18:13 | 25260068 | `SetDeprecated(false)`, public deploys open |
| 2026-06-06 18:13 to 18:15 | 25260069 to 25260078 | teamFeeRecipient = owner, hook, mev module, locker enabled |
| 2026-06-06 20:09 | 25260648 | `SetDeprecated(true)`, public window about 2 hours, no coin launched in it |
| 2026-06-06 20:11 | 25260658 | deployFee 0.069 to 0 |
| 2026-06-08 | 25275351 | 111 launched by owner, tokenAdmin 0xA96a (TokenAdminPoker) |
| 2026-07-31 22:17 | 25655778 | deployFee 0 to 0.069 eth |

## what the broadcast folder wrongly implies

| claim the folder makes | reality |
|---|---|
| the four 2026-05-05 mainnet runs (`Deploy.s.sol/1/run-1777994761002.json`, `DeployBurnExtension`, `DeployProtocolFeeStack`, `LaunchLayer`) are a mainnet stack at factory 0xbcd583c9… | rehearsal on an anvil fork: sender is anvil account 0 (`0xf39F…2266`), chain id recorded as 1, 34 txs, none exist on mainnet, every address has no code. never deployed |
| the last factory is 0xf051… | 0x4959 is current and has no broadcast record at all (DeployV1Stack was run without committing its broadcast, or from another checkout) |
| `LaunchLayer.s.sol/1/run-latest.json` is the LAYER launch (tx 0x2b735bf8…, block 25045168) | that hash is not on chain. the real launch is tx `0x0f3f06c737955b2d99560a6d8277baa2e0010ae6d068a7159787917593145841` at block 25045152 (same calldata length, same sender) |
| four more records are the deploys of PoolSwapTest 0x3c78 and 0x87cf, LAYER renderer 0x0572, autoforward extension 0x38d0 | the addresses exist but with different tx hashes and blocks than the records (e.g. 0x38d0 created in block 25054786, record says 25054790). records come from a later resimulation of the script, chain data is used in the registry |
| `TraceTestTokenFees.s.sol/1` (9 txs) happened on mainnet | fork only, nothing on chain |
| `run-latest.json` per script is the live deployment | for `Deploy.s.sol` it is the legacy stack (real, 2026-05-07). for `DeployProtocolFeeStack` it is the real LAYER router and controller. the 2026-05-05 files in the same folders are fork runs. timestamps in file names are the local clock in ms, not block time |
| the first `Deploy.s.sol` run created a `setTokenImplementation` token proxy design (`ArtCoinsToken` 0xa27b…) | fork only. mainnet tokens are direct CREATE2 deploys by the factory |
| broadcast `commit` fields identify the source | commits `15c1d03`, `dd39caf`, `e3d7bac`, `a5b57f2`, `caba6ea` are not in this repo (history was squashed to `a60bf15`), so source provenance of the deploys cannot be recovered from git |
| `script-js/sync-addresses.mjs` can regenerate mainnet addresses from `run-latest.json` | it would emit the legacy and open stacks, never the current one, and it patches a file in a sibling repo (`../artcoins/src/lib/launcher/config.ts`) |

mainnet txs in records: 133 distinct hashes. on chain: 89 (all status 1). not on chain: 44 (28+2+2 first fork stack, 3 LaunchLayer, 9 TraceTestTokenFees). unique mainnet CREATE/CREATE2: 51, of which 31 exist on chain with code, 20 are fork only.

## contract inventory and bytecode match

56 contracts, 2 coins. `source.bytecodeMatch` is recomputed by the checker on every run. rule: runtime code from chain vs `deployedBytecode` of the artifact whose compilation target equals `source.repoPath`; immutable slots and library link slots masked; every ipfs metadata hash masked; an artifact built without metadata is compared against chain code with its trailing metadata block (and the `0xfe` before it) removed. two artifact sets are tried: `foundry-out` (default profile, runs 20000) and `out/ci` (profile ci, runs 200, metadata on). `verified` means equal under either set.

| contract | address | stack | role | state | bytecodeMatch | detail |
|---|---|---|---|---|---|---|
| ArtCoinsDeployer | 0xbb0F4d9762387B2be45E4Ac6cAC2d264f98B82C2 | legacy | other | unknown | mismatch | first diff @2 (chain 12530 vs artifact 16811, foundry-out runs=20000) |
| ArtCoinsFeeLocker | 0x1143db0913Ca5eCe8A42FC01b625fD81F9386b05 | legacy | escrow | unknown | verified | foundry-out runs=20000 |
| ArtCoinsFactory | 0xD1595A2742C392d1c109b616b4F08918D02292f9 | legacy | factory | deprecated | mismatch | first diff @1252 (chain 13804 vs artifact 13804, foundry-out runs=20000) |
| ArtCoinsPoolExtensionAllowlist | 0xDD06Ba83198a2A74c3EE0C3a5405DB481bE601e4 | legacy | allowlist | unknown | verified | foundry-out runs=20000 |
| ArtCoinsHookStaticFeeV2 | 0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc | legacy | hook | enabled | mismatch | first diff @33 (chain 21202 vs artifact 21162, foundry-out runs=20000) |
| ArtCoinsLpLockerMultiple | 0x75BE7E95745915fD0C1761B74F3f9650ad2d1118 | legacy | locker | enabled | verified | foundry-out runs=20000 |
| ArtCoinsMevTimeDelay | 0xf080D741D069B107D728B68F781843d83A0EA8Fb | legacy | mevModule | enabled | mismatch | first diff @358 (chain 1208 vs artifact 1262, foundry-out runs=20000) |
| ArtCoinsMevDescendingFees | 0x7958DE7d8C857CdD37465FB920A961B1f8F74301 | legacy | mevModule | enabled | mismatch | first diff @163 (chain 3677 vs artifact 3731, foundry-out runs=20000) |
| ArtCoinsMevLinearFees | 0xAe19E402420359062eE422a03589e04a52cD8C6F | legacy | mevModule | enabled | mismatch | first diff @218 (chain 2831 vs artifact 2880, foundry-out runs=20000) |
| ArtCoinsMevSniperSteppedFees | 0x1AB013ebEf60E82DFC55Ec90B0974A86d283B935 | legacy | mevModule | enabled | mismatch | first diff @194 (chain 3988 vs artifact 4037, foundry-out runs=20000) |
| ArtCoinsVault | 0x84732a79e4Ec8F03063a138c7ef866a9d222C661 | legacy | extension | enabled | verified | foundry-out runs=20000 |
| ArtCoinsAirdropV2 | 0xF937dFf16a45E417951794758E77CbEd0A7F27eC | legacy | extension | enabled | verified | foundry-out runs=20000 |
| BurnExtension | 0x034d6bAbBB067EEE4A67357B687c9B1267aEA1CE | legacy | extension | enabled | verified | foundry-out runs=20000 |
| ArtCoinsUniv4EthDevBuy | 0xfCB6a929dB98A1D69b5F33A2f7E073cB7449cF30 | legacy | extension | enabled | mismatch | first diff @36 (chain 6904 vs artifact 6934, foundry-out runs=20000) |
| DefaultMetadataRenderer | 0x7dBfF01528AC8B1e7c7B75eeCFA123962319070A | legacy | renderer | unknown | mismatch | first diff @180 (chain 2429 vs artifact 1952, foundry-out runs=20000) |
| LiquidityLayerCounterPoolExtension | 0xc4a1E94749c0C3c608577FcD7567a5fBcAcE0A65 | legacy | extension | enabled | verified | foundry-out runs=20000 |
| ScriptyContentChunk | 0x8d14554814403970755e104655E1847939E6cCcB | legacy | other | unknown | unverified | no repoPath, not compared |
| ScriptyContentChunk | 0x049Ef213Dda0Bf2E3F1bFca78B3eB94AD3f7165C | legacy | other | unknown | unverified | no repoPath, not compared |
| ScriptyContentChunk | 0xb18D0c05d7855BA26aAC3222eD01902BbC9B2D0c | legacy | other | unknown | unverified | no repoPath, not compared |
| ScriptyContentChunk | 0x2F144CD580B75D2BB6b792750bfFaD8e651BbBb5 | legacy | other | unknown | unverified | no repoPath, not compared |
| ScriptyContentChunk | 0x10F4aBE453A44954a991127559D5A5CCB42cC07A | legacy | other | unknown | unverified | no repoPath, not compared |
| ScriptyContentChunk | 0x2Ebd66Cc00782A74c5A7C8C48030916D7adBDc55 | legacy | other | unknown | unverified | no repoPath, not compared |
| LiquidityLayerOnchainRenderer | 0x93bDB2462d23720BE9A635F526287A3fD0f6D7d4 | legacy | renderer | unknown | mismatch | first diff @945 (chain 14193 vs artifact 13930, foundry-out runs=20000) |
| ScriptyContentChunk | 0xD85dC362918be07657630E7a16C22F1c0E6aDEe5 | legacy | other | unknown | unverified | no repoPath, not compared |
| BurnRouter | 0x2eDBdF011768d8cd4Ef537658b41440900C52000 | legacy | router | unknown | verified | foundry-out runs=20000 |
| ProtocolFeeController | 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60 | legacy | controller | unknown | verified | foundry-out runs=20000 |
| ArtCoinsToken | 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9 | legacy | token | unknown | mismatch | first diff @34 (chain 9147 vs artifact 8336, out/ci runs=200) |
| LiquidityLayerAutoForwardExtension | 0x38d03af54ba9F80c3476B3D3B3a6415A399303f7 | legacy | extension | enabled | verified | foundry-out runs=20000 |
| LiquidityLayerOnchainRenderer | 0x0572C1754378c2f9Aef51b57b2830D343ee9d186 | legacy | renderer | unknown | mismatch | first diff @945 (chain 14193 vs artifact 13930, foundry-out runs=20000) |
| PoolSwapTest | 0x3C78371fDa8B11c1fCe7e88Cab15E888b9CdDA90 | legacy | other | unknown | unverified | no repoPath, not compared |
| PoolSwapTest | 0x2C0A19db425AC50Fb79b0A5c8E39c2031cfA248E | legacy | other | unknown | unverified | no repoPath, not compared |
| PoolSwapTest | 0x87cfCe91e7BCFD0bAE2EbC9F207ee3608E972166 | legacy | other | unknown | unverified | no repoPath, not compared |
| ArtCoinsFactory | 0xF051cd4C4F3F36F9f24d8a19d60Ee8F84FC6793e | open | factory | enabled | mismatch | first diff @44 (chain 13926 vs artifact 12662, out/ci runs=200) |
| ArtCoinsPoolExtensionAllowlist | 0xd6D5fb5CfE386d0eB73a09cba5d190beb802e6E8 | open | allowlist | unknown | verified | foundry-out runs=20000 |
| ArtCoinsFeeEscrow | 0xDD1b8C9C99Be3C717B9A5eb3C84297C5bfca1C06 | open | escrow | unknown | verified | foundry-out runs=20000 |
| ArtCoinsLpLocker | 0xd914c864D9AEf3D8E51370139300aC534FB497b2 | open | locker | enabled | mismatch | first diff @1972 (chain 18504 vs artifact 18504, foundry-out runs=20000) |
| BurnRouter | 0x9304a81965Ef3F7A092bd9eFd8c2fFc411E5F34d | open | router | unknown | mismatch | first diff @2 (chain 9247 vs artifact 10374, foundry-out runs=20000) |
| ArtCoinsHookStaticFee | 0xAAd673ea3945dF5F7Ef328974d2c07c8BdcAA8Cc | open | hook | enabled | mismatch | first diff @41 (chain 21302 vs artifact 18959, foundry-out runs=20000) |
| BurnRouter | 0xE60046ee745B235109C10d322A1cbDB3c029De43 | open | router | unknown | mismatch | first diff @2 (chain 11038 vs artifact 10374, foundry-out runs=20000) |
| PassThroughWallet | 0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4 | current | other | unknown | unverified | no repoPath, not compared |
| ArtCoinsDeployer | 0x92584B320A8B871934A50b9D6f05833f6F82Cb81 | current | other | unknown | verified | out/ci runs=200 |
| SkimFeeInitLib | 0x115510a709d1AfD798325F3FFb74B127a08dD3C9 | current | other | unknown | verified | out/ci runs=200 |
| ArtCoinsFactory | 0x49596c375c139E79bb937bcf826068a8F78D4e0e | current | factory | deprecated | verified | out/ci runs=200 |
| ArtCoinsFeeEscrow | 0x7559689765aE86cBB38e68CD1294830CccB125F2 | current | escrow | unknown | verified | out/ci runs=200 |
| ArtCoinsHookSkimFee | 0x636c050296B5Cc528D8785169Bf8923716FCa9cc | current | hook | enabled | verified | out/ci runs=200 |
| ArtCoinsMevLinearSkim | 0xb038D597365FfD108D63C265Bb0621444a1D8B83 | current | mevModule | enabled | verified | out/ci runs=200 |
| ProtocolFeeController | 0xd8C63401268744d430EbE0C18412211421498013 | current | controller | unknown | verified | out/ci runs=200 |
| ArtCoinsLpLocker | 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab | current | locker | enabled | verified | out/ci runs=200 |
| LiveBidAdapter | 0x8C72FBc2bB32e76aa54243F76745266a0F92CD01 | current | other | unknown | unverified | no repoPath, not compared |
| ProtocolFeePhaseAdapter | 0xed3E9D3Bf693372060b7ce62aDB49650145b2ba9 | current | other | unknown | unverified | no repoPath, not compared |
| UnverifiedPcRenderer | 0x760421B7916917Ffd72ECeAa4c1F7ffC4D12eEc7 | current | renderer | unknown | unverified | no repoPath, not compared |
| TokenAdminPoker | 0xA96a11257890ED1C43C16c098E286e18e45E6258 | current | other | unknown | unverified | no repoPath, not compared |
| UnverifiedPcContract | 0xB03Cbd862F47059e928C113182814c676eA29d4c | current | other | unknown | unverified | no repoPath, not compared |
| FeeAutoSwapper | 0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961 | current | swapper | unknown | mismatch | first diff @45 (chain 11033 vs artifact 10072, foundry-out runs=20000) |
| ArtCoinsToken | 0x61C9d89fe1212F6b55fF888816A151463287B8ae | current | token | unknown | verified | out/ci runs=200 |
| BurnRouter | 0x0EB22955E8904b8C5a4EC6f1D476f5b0C93854ca | current | router | unknown | verified | foundry-out runs=20000 |

### mismatches, what they are

| contract | address | finding |
|---|---|---|
| legacy factory | 0xD1595A27 | same length (13804), 2 diff segments of 4 bytes at offsets 1252 and 2272. source drifted a tiny bit from the deploy build |
| open locker | 0xd914c864 | same length (18504), two single byte diffs at 1972 and 11648 |
| legacy hook StaticFeeV2 | 0xA5eA9904 | chain 21202 vs head 21162, 576 diff segments, real source change |
| legacy mev modules x4 | 0xf080, 0x7958, 0xae19, 0x1ab0 | chain 49 to 54 bytes shorter than head |
| legacy dev buy | 0xfCB6a929 | chain 6904 vs legacy source 6934 |
| default renderer | 0x7dBfF015 | chain 2429 vs head 1952 |
| LAYER renderers | 0x93bD, 0x0572 | chain 14193 vs head 13930 (same code at both addresses) |
| LAYER token | 0xb7287e4A | chain 9147 vs head 8336 (ci, metadata on) or 10177 (default). token predates head |
| open factory | 0xF051cd4C | `version()` "3", chain 13926 vs head 15029 (default) or 12662 (ci, metadata on). not head |
| open hook, routers | 0xAAd673ea, 0x9304a819, 0xE60046ee | hook chain 21302 vs head 18959 (default). routers chain 9247 and 11038 vs head 10374 (0x0EB2 on the current stack equals head exactly) |
| fee swapper | 0xeBD9B74A | chain 11033 vs head 10072 (default). head FeeAutoSwapper changed after the 111 deploy |
| legacy deployer | 0xbb0F4d97 | chain 12530 vs head 16811 |

### things only the chain tells

| item | detail |
|---|---|
| current factory links an external library | `ArtCoinsDeployer` at 0x92584b320a8b871934a50b9d6f05833f6f82cb81 (read from the code at the link slot, created 2026-06-06 block 25260060). it is not the legacy 0xbb0F deployer |
| current hook links an external library | `SkimFeeInitLib` at 0x115510a709d1afd798325f3ffb74b127a08dd3c9 (block 25260061) |
| hook size | head `ArtCoinsHookSkimFee` is 24578 bytes at the default profile, 2 bytes over EIP-170, so it cannot be deployed with default settings. at profile ci it is 20612 bytes with metadata (20558 without), because `SkimFeeInitLib` was split out (the foundry.toml comment saying about 24547 is stale) |
| open stack allowlist is live infrastructure | current hook 0x636c reads `poolExtensionAllowlist()` = 0xd6D5…, created in the open stack |
| 111 wiring | locker reward: 100% to FeeAutoSwapper 0xeBD9 (admin 0xdEaD); swapper endRecipient LiveBidAdapter 0x8C72; hook bounty recipient 0x8C72, protocol recipient ProtocolFeePhaseAdapter 0xed3E (forwards to controller 0xd8C6, 86.67% treasury 0x41c3 / 13.33% burn router 0x0EB2), referral payout 0xB03C; pool fee flag 0x800000 (dynamic), tick spacing 200, paired with native eth (currency0 is the zero address) |
| controller 0xd8C6 burn router | `burnRouter()` is 0x0EB22955…, not the LAYER router 0x2edb that `DeployPCController.s.sol` documents |
| LAYER wiring | locker rewards: owner 38%, burn router 0x2edb 42%, controller 0x5fdc 20%; renderer 0x0572; pool extension autoforward 0x38d0; mev module 0x1ab0 |
| off record owner txs | legacy factory `SetAdmin(owner)` at block 25044233, LAYER launch 25045152, all of the current stack, router 0x0EB2, fee swapper and the permanent-collection contracts |
| permanent-collection contracts | TokenAdminPoker 0xA96a, LiveBidAdapter 0x8C72, ProtocolFeePhaseAdapter 0xed3E, 0xB03C (unverified, `hook()` getter), 0x7604 (111 renderer, unverified), pass through wallet 0x41c3 are listed with role `other` or `renderer`, `repoPath` null. their source is in the permanent-collection repo. the rest of that project (patron, vault, auction modules, 25270164 to 25270213) is not listed |
| not listed on purpose | other contracts created by the owner eoa that are not artcoins (vouch, pull, midway, fwa and others, blocks 25.2M to 26.0M), external infra (PoolManager, PositionManager, Permit2, WETH, universal router, StateView 0x7fFE42C4…, ScriptyStorage 0xbD11…, ScriptyBuilder 0xD758…) |

## coins

| symbol | name | address | stack | launch tx | block | pool |
|---|---|---|---|---|---|---|
| LAYER | Liquidity Layer | 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9 | legacy | 0x0f3f06c737955b2d99560a6d8277baa2e0010ae6d068a7159787917593145841 | 25045152 | hook 0xA5eA9904, paired WETH, fee 8388608 (dynamic flag), tick spacing 200, pool id 0x85c15a70…1e50 |
| 111 | permanent collection | 0x61C9d89fe1212F6b55fF888816A151463287B8ae | current | 0x3aca132bed96c778e90408dacfc3621966ea29a70a30040722d071f3dbc63cf2 | 25275351 | hook 0x636c0502, paired native eth (pairedToken null), fee 8388608, tick spacing 200, pool id 0xf860d8f4…f795 |

pool fee, tick spacing and paired token come from the stack locker's `tokenRewards(token).poolKey`, name and symbol from the token, launches from the factory `TokenCreated` logs. the checker fails if a factory logs a coin the registry does not list.

## mainnet broadcast records, mined

51 unique CREATE/CREATE2 and 65 wiring calls (10 chunk uploads to ScriptyStorage summarised, 17 test swap/approve/WETH calls summarised). `*` means the value comes from the record only (fork run, not on chain). block times are from the chain where the tx exists, else the run's local clock. constructor args are from the record's `arguments`; addresses are shown as `name[0xabcd..ef12]` when known. the 20 fork only rows are the 2026-05-05 anvil stack (`0xf39F…2266` sender) and 2 fork PoolSwapTest helpers.

### creates

| script | contract | address | kind | deployer (from) | tx hash | block | utc | on chain | constructor args |
|---|---|---|---|---|---|---|---|---|---|
| Deploy | ArtCoinsDeployer | 0x786c12a36657fc0da39fa2adf7413355f6c4756c | CREATE2 | anvil0[0xf39f..2266] | 0xa374602f7334e53c03a8c68418489055407f5a6b678cfe6a733276b3a6bd6758 | 25029685* | 2026-05-05 15:26* | no (fork) | none |
| Deploy | ArtCoinsFactory | 0xbcd583c9769ae1bc31374168acfb7c434987a947 | CREATE | anvil0[0xf39f..2266] | 0x2eaf30a78657d0013e86882ac95e55027b96bfb13c6850a6601ca2833f59b945 | 25029686* | 2026-05-05 15:26* | no (fork) | anvil0[0xf39F..2266] |
| Deploy | ArtCoinsFeeLocker | 0x83753fe5461b0a3330772c5362d163baf253486a | CREATE | anvil0[0xf39f..2266] | 0x7bb8c1eb76fcce2008b98b6fc537b6cb365d0fc3c9861f2953e65812b4d8e2b7 | 25029687* | 2026-05-05 15:26* | no (fork) | anvil0[0xf39F..2266] |
| Deploy | ArtCoinsToken | 0xa27bc0b03c9f75c8fd8110770bd612585e2d60ca | CREATE | anvil0[0xf39f..2266] | 0x2ff8cb1c85248a810731e0764da4487f33f5a9211513d1f3fc7732292959b4fe | 25029687* | 2026-05-05 15:26* | no (fork) | none |
| Deploy | ArtCoinsPoolExtensionAllowlist | 0x3fc853d14a86fbe2de14ae2670433c5dee3b99e5 | CREATE | anvil0[0xf39f..2266] | 0x25385b59265e1417b59dffb9c515b41ee287325982620cf092e2a367d93f8257 | 25029687* | 2026-05-05 15:26* | no (fork) | anvil0[0xf39F..2266] |
| Deploy | ArtCoinsHookStaticFeeV2 | 0x693112ce349788a835998906dc798276bd5c28cc | CREATE2 | anvil0[0xf39f..2266] | 0xc4658bbb8c6c4f65422fce8b7940cb11ef2420a933df415975c4714625347254 | 25029687* | 2026-05-05 15:26* | no (fork) | PoolManager[0x0000..8A90], ArtCoinsFactory (fork)[0xbcd5..A947], ArtCoinsPoolExtensionAllowlist (fork)[0x3fc8..99e5], WETH[0xC02a..6Cc2] |
| Deploy | ArtCoinsLpLockerMultiple | 0xe008520f77fd5c7ef5d0f6533969b8605065c59c | CREATE | anvil0[0xf39f..2266] | 0x12a501cbea29413425f62e1be54aae5c9d4a30ac6d593897f4bba84340ab8517 | 25029687* | 2026-05-05 15:26* | no (fork) | anvil0[0xf39F..2266], ArtCoinsFactory (fork)[0xbcd5..A947], ArtCoinsFeeLocker (fork)[0x8375..486a], PositionManager[0xbD21..ee9e], Permit2[0x0000..8BA3] |
| Deploy | ArtCoinsMevTimeDelay | 0x7797ddf03f7637caf4d33f257d123f60ac5f8313 | CREATE | anvil0[0xf39f..2266] | 0x8b2caf5e43bd4e0aa76cccf29393562a91adaabe4585379637f06f8652994227 | 25029687* | 2026-05-05 15:26* | no (fork) | 120 |
| Deploy | ArtCoinsMevDescendingFees | 0x1f3249a661012a1dfa0b085f5716851c45023548 | CREATE | anvil0[0xf39f..2266] | 0x10d0861a2bc4c300cef097ddbee3e12b2be4c088c18a96828311f5f061a6f941 | 25029687* | 2026-05-05 15:26* | no (fork) | none |
| Deploy | ArtCoinsMevLinearFees | 0xc2214d88c9ae33dfc275f088a5808b321af43972 | CREATE | anvil0[0xf39f..2266] | 0x0f50f2ae48d6dacde500887a4d0f00724c31c5198a9bcc5be61e943328e25f0b | 25029687* | 2026-05-05 15:26* | no (fork) | none |
| Deploy | ArtCoinsMevSniperSteppedFees | 0xabd78942eca28f15e0f37e6bae7da6879fd1257a | CREATE | anvil0[0xf39f..2266] | 0xe017c0c3b3b7be16cc4ef1a826efa1393529212784a3c03c2efa2778f1e34cc3 | 25029687* | 2026-05-05 15:26* | no (fork) | none |
| Deploy | ArtCoinsVault | 0x710e9fbed43da7da297c46e868de78d16e309afb | CREATE | anvil0[0xf39f..2266] | 0x1c5bfe35a4adf3480817339ea579ec22a5558c8e3ef30bd24a4867c4efe2a40e | 25029687* | 2026-05-05 15:26* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..A947] |
| Deploy | ArtCoinsAirdropV2 | 0xd826ba44cfcf70627ed999baaee3dada341f4a23 | CREATE | anvil0[0xf39f..2266] | 0xeeb413795260d8fe0fe56630260f3f60a15d15a2ba5e9c77cb02e6d91e6145e7 | 25029687* | 2026-05-05 15:26* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..A947] |
| Deploy | ArtCoinsUniv4EthDevBuy | 0x6b7d126dc94037361acf6174342c43724d91d477 | CREATE | anvil0[0xf39f..2266] | 0x58849782c38240b71bbecad1fc1595fccda5c86f22c2c9de5bf4eb83ffccd4d4 | 25029687* | 2026-05-05 15:26* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..A947], WETH[0xC02a..6Cc2], UniversalRouter[0x66a9..A8Af], Permit2[0x0000..8BA3] |
| Deploy | DefaultMetadataRenderer | 0xb4e960b50c4dbf99ba832e70d455f509073d17df | CREATE | anvil0[0xf39f..2266] | 0x28e1f4293251000f7471961cd48924bc887222d1f8e32caf3bf2dbf600c53ff0 | 25029687* | 2026-05-05 15:26* | no (fork) | none |
| DeployProtocolFeeStack | BurnRouter | 0x16a2fbbc99be726f9e760ed809c54bacabf74224 | CREATE | anvil0[0xf39f..2266] | 0xf46e0d43f2e7212e596f663d86a821544b3a08497f0b80a102e8ea089ddf4aa7 | 25029688* | 2026-05-05 15:26* | no (fork) | anvil0[0xf39F..2266] |
| DeployProtocolFeeStack | ProtocolFeeController | 0xb7ec8831829c670d6f83dd9e530c680fa4505d9b | CREATE | anvil0[0xf39f..2266] | 0x0dc7f009ea67b194907842a1559c4e0de1be609ef9c1ecfa7e0cf98ee8961440 | 25029689* | 2026-05-05 15:26* | no (fork) | anvil0[0xf39F..2266], anvil1[0x7099..79C8], BurnRouter (fork)[0x16a2..4224] |
| DeployBurnExtension | BurnExtension | 0x8353221c0971d5ff223d25768dd6ba8459b519a9 | CREATE | anvil0[0xf39f..2266] | 0xc8d56eccf1eb8db56d75d1a4d39597a9d6153689188798a75ef3926ac60c8232 | 25029690* | 2026-05-05 15:26* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..A947] |
| Deploy | ArtCoinsDeployer | 0xbb0f4d9762387b2be45e4ac6cac2d264f98b82c2 | CREATE2 | owner[0xcb43..17f9] | 0x9ed47bd8764c0e2bdebc5dc8a2c3cc57a5d6c7bba5d060d4b3b7102e70d8eb8c | 25040117 | 2026-05-07 02:17 | yes | none |
| Deploy | ArtCoinsFeeLocker | 0x1143db0913ca5ece8a42fc01b625fd81f9386b05 | CREATE | owner[0xcb43..17f9] | 0xc97356182b76d9136ae30416dddbdb494977e17c3c37b9033cadb7fe371e9622 | 25040119 | 2026-05-07 02:17 | yes | owner[0xCB43..17F9] |
| Deploy | ArtCoinsFactory | 0xd1595a2742c392d1c109b616b4f08918d02292f9 | CREATE | owner[0xcb43..17f9] | 0x9b4f995838cbf9079f0d8b8a513ad94128974d809b479f2415c9c4b7681aefbb | 25040120 | 2026-05-07 02:17 | yes | owner[0xCB43..17F9] |
| Deploy | ArtCoinsPoolExtensionAllowlist | 0xdd06ba83198a2a74c3ee0c3a5405db481be601e4 | CREATE | owner[0xcb43..17f9] | 0xd336e260c8d3723389472cf49b8e371ab5fd0bd223e472f4c4e4757d0d881ffa | 25040122 | 2026-05-07 02:18 | yes | owner[0xCB43..17F9] |
| Deploy | ArtCoinsHookStaticFeeV2 | 0xa5ea9904f2cd572c638a1ef81463bdabea9d28cc | CREATE2 | owner[0xcb43..17f9] | 0xdc5f2ebf773edd7605bfa47e1cf67b188f4046a09b8a6ba1877c3d0061bf238b | 25040124 | 2026-05-07 02:18 | yes | PoolManager[0x0000..8A90], ArtCoinsFactory[0xD159..92f9], ArtCoinsPoolExtensionAllowlist[0xDD06..01e4], WETH[0xC02a..6Cc2] |
| Deploy | ArtCoinsLpLockerMultiple | 0x75be7e95745915fd0c1761b74f3f9650ad2d1118 | CREATE | owner[0xcb43..17f9] | 0xb4a7e6a10bd274a2e3f4cf7ba26bc1f94b8705133d62c6cd497494f07b4739e7 | 25040125 | 2026-05-07 02:18 | yes | owner[0xCB43..17F9], ArtCoinsFactory[0xD159..92f9], ArtCoinsFeeLocker[0x1143..6b05], PositionManager[0xbD21..ee9e], Permit2[0x0000..8BA3] |
| Deploy | ArtCoinsMevTimeDelay | 0xf080d741d069b107d728b68f781843d83a0ea8fb | CREATE | owner[0xcb43..17f9] | 0xc0c947b9a15bcd13a4394c6d08bcf1bb10ed0479dd498bbba3849f37509f2afa | 25040126 | 2026-05-07 02:18 | yes | 120 |
| Deploy | ArtCoinsMevDescendingFees | 0x7958de7d8c857cdd37465fb920a961b1f8f74301 | CREATE | owner[0xcb43..17f9] | 0x7e2cf84df1457925207e1df7ebb391c0ac0d2db00deab0320a4b9a0acec2b5b0 | 25040127 | 2026-05-07 02:19 | yes | none |
| Deploy | ArtCoinsMevLinearFees | 0xae19e402420359062ee422a03589e04a52cd8c6f | CREATE | owner[0xcb43..17f9] | 0x85eeb3efe136df39f9a90bb4c5b9f7c232f02c456fcd52a81fa95f84f3163376 | 25040129 | 2026-05-07 02:19 | yes | none |
| Deploy | ArtCoinsMevSniperSteppedFees | 0x1ab013ebef60e82dfc55ec90b0974a86d283b935 | CREATE | owner[0xcb43..17f9] | 0x4a15b9c6373f7e6513a9eb2ec5bce37da71c077914cd00ab2f66fe931f4660fd | 25040130 | 2026-05-07 02:19 | yes | none |
| Deploy | ArtCoinsVault | 0x84732a79e4ec8f03063a138c7ef866a9d222c661 | CREATE | owner[0xcb43..17f9] | 0x9bd920ef33c9c6c99f8ee8a09cf64e22abe5f689185d0ce241bad4e5933423e9 | 25040131 | 2026-05-07 02:19 | yes | ArtCoinsFactory[0xD159..92f9] |
| Deploy | ArtCoinsAirdropV2 | 0xf937dff16a45e417951794758e77cbed0a7f27ec | CREATE | owner[0xcb43..17f9] | 0xb422bb34a51c0b330f4f2dddcc51c144482fc867d9a8699c721c2f79a67dc395 | 25040132 | 2026-05-07 02:20 | yes | ArtCoinsFactory[0xD159..92f9] |
| Deploy | BurnExtension | 0x034d6babbb067eee4a67357b687c9b1267aea1ce | CREATE | owner[0xcb43..17f9] | 0x609399da5c89e8d5f9a287daf02cfca7f20d5210c5d481387cb1a573bf199103 | 25040133 | 2026-05-07 02:20 | yes | ArtCoinsFactory[0xD159..92f9] |
| Deploy | ArtCoinsUniv4EthDevBuy | 0xfcb6a929db98a1d69b5f33a2f7e073cb7449cf30 | CREATE | owner[0xcb43..17f9] | 0xd15444cda4b96b9decb25abd9fdf6e8edc8e50d567da83d05f380697bd2bad3e | 25040134 | 2026-05-07 02:20 | yes | ArtCoinsFactory[0xD159..92f9], WETH[0xC02a..6Cc2], UniversalRouter[0x66a9..A8Af], Permit2[0x0000..8BA3] |
| Deploy | DefaultMetadataRenderer | 0x7dbff01528ac8b1e7c7b75eecfa123962319070a | CREATE | owner[0xcb43..17f9] | 0xeefd8a70e31c41008a57dde2982654d79cc3bfa72430bdad941c4a1d39b0602d | 25040135 | 2026-05-07 02:20 | yes | none |
| Deploy | LiquidityLayerCounterPoolExtension | 0xc4a1e94749c0c3c608577fcd7567a5fbcace0a65 | CREATE | owner[0xcb43..17f9] | 0xe8db9a918f9c7ab63fdee17e4ee8c5801c57e5d10e0a531dbdcb8166ce8eee0c | 25040136 | 2026-05-07 02:20 | yes | ArtCoinsHookStaticFeeV2[0xA5eA..28cc] |
| Deploy | LiquidityLayerOnchainRenderer | 0x93bdb2462d23720be9a635f526287a3fd0f6d7d4 | CREATE | owner[0xcb43..17f9] | 0x2de85fa4d2bde84a2a7013fc9e59816729313087b65a8e62a2b1dcfec41436d4 | 25040149 | 2026-05-07 02:23 | yes | owner[0xCB43..17F9], LiquidityLayerCounterPoolExtension[0xc4a1..0A65], ScriptyBuilder[0xD758..f022], ScriptyStorage[0xbD11..7699], ll/sketch.b64.1778120217836, ll/mona.1778120217836, image/jpeg, Until nothing remains but speculation |
| DeployProtocolFeeStack | BurnRouter | 0x2edbdf011768d8cd4ef537658b41440900c52000 | CREATE | owner[0xcb43..17f9] | 0x35fc0f40148ce3ae60a94308f29b32831e7f4241bcc58d82f2bb6d1fa738c322 | 25040225 | 2026-05-07 02:38 | yes | owner[0xCB43..17F9] |
| DeployProtocolFeeStack | ProtocolFeeController | 0x5fdc39756a64a84518ef00cb6a0ed46971e00a60 | CREATE | owner[0xcb43..17f9] | 0x1b785a149eef2c99052fa33caef437943b071be80a0b856c550b986fa32df4f2 | 25040226 | 2026-05-07 02:39 | yes | owner[0xCB43..17F9], PassThroughWallet[0x41c3..A6A4], BurnRouter[0x2eDB..2000] |
| TraceTestTokenFees | PoolSwapTest | 0x28c0c543f20e777dfa7a76ce60cc38e7daa0aa5f | CREATE | owner[0xcb43..17f9] | 0xd110af36721a03736d2c40f6d42a8cca78eedfe960cc92c8094e42d842bb6cfd | 25045259* | 2026-05-07 19:05* | no (fork) | PoolManager[0x0000..8A90] |
| TraceTestTokenFees | PoolSwapTest | 0x8b57f9d3a83e0fc03c051d87ba49f5cf27e3636f | CREATE | owner[0xcb43..17f9] | null | n/a* | 2026-05-07 19:06* | no (fork) | PoolManager[0x0000..8A90] |
| SetUpLayerAutoForward | LiquidityLayerAutoForwardExtension | 0x38d03af54ba9f80c3476b3d3b3a6415a399303f7 | CREATE | owner[0xcb43..17f9] | 0x30340e3c934c05267f23094f09a45703380e23a39d1bf8952785f27ae4be8136 | 25054790 | 2026-05-09 03:20 | yes | ArtCoinsHookStaticFeeV2[0xA5eA..28cc], ArtCoinsLpLockerMultiple[0x75BE..1118], ArtCoinsFeeLocker[0x1143..6b05], ProtocolFeeController[0x5fDc..0A60], BurnRouter[0x2eDB..2000], owner[0xCB43..17F9] |
| MigrateLayerRenderer | LiquidityLayerOnchainRenderer | 0x0572c1754378c2f9aef51b57b2830d343ee9d186 | CREATE | owner[0xcb43..17f9] | 0xcfe6d73314db804a35d0ceaaa4a172a5f76d74f48a67296a886b3e2b11be8391 | 25054793 | 2026-05-09 03:20 | yes | owner[0xCB43..17F9], LiquidityLayerAutoForwardExtension[0x38d0..03f7], ScriptyBuilder[0xD758..f022], ScriptyStorage[0xbD11..7699], ll/sketch.b64.1778120217836, ll/mona.1778120217836, image/jpeg, Until nothing remains but speculation |
| LiveSwapVerify | PoolSwapTest | 0x3c78371fda8b11c1fce7e88cab15e888b9cdda90 | CREATE | owner[0xcb43..17f9] | 0xccb32228ec862c45204a9250438a043d8b761e6ed69b9f60d5fbe7396d69e25a | 25054890 | 2026-05-09 03:40 | yes | PoolManager[0x0000..8A90] |
| LiveSellVerify | PoolSwapTest | 0x2c0a19db425ac50fb79b0a5c8e39c2031cfa248e | CREATE | owner[0xcb43..17f9] | 0x1f1957a2fbb59a80a10064664251ac8467f8f4e3537fc57a4875f1129b194dca | 25054995 | 2026-05-09 04:01 | yes | PoolManager[0x0000..8A90] |
| LiveNoOpVerify | PoolSwapTest | 0x87cfce91e7bcfd0bae2ebc9f207ee3608e972166 | CREATE | owner[0xcb43..17f9] | 0x3d654e531906b38de2616419a4ca8a813fbfea3a122d0f12e88aada4140d0f2b | 25055008 | 2026-05-09 04:03 | yes | PoolManager[0x0000..8A90] |
| DeployNativeEthStack | ArtCoinsFactory | 0xf051cd4c4f3f36f9f24d8a19d60ee8f84fc6793e | CREATE | owner[0xcb43..17f9] | 0xa2924e04c4f20322a8e28b74ea0a8a1ca45d46317e08d2fafeaf0cb64a2c8444 | 25125708 | 2026-05-19 00:34 | yes | owner[0xCB43..17F9] |
| DeployNativeEthStack | ArtCoinsPoolExtensionAllowlist | 0xd6d5fb5cfe386d0eb73a09cba5d190beb802e6e8 | CREATE | owner[0xcb43..17f9] | 0xccbc3fcc26f17eac92034ae1e1189f86f23027663f88121bdd5cc1be4e1e03f4 | 25125709 | 2026-05-19 00:34 | yes | owner[0xCB43..17F9] |
| DeployNativeEthStack | ArtCoinsFeeEscrow | 0xdd1b8c9c99be3c717b9a5eb3c84297c5bfca1c06 | CREATE | owner[0xcb43..17f9] | 0xc1eb1c4afac84d5f775c9846f0ccfac81b9a5cd98c44904bdcd82baa2c89c04e | 25125710 | 2026-05-19 00:35 | yes | owner[0xCB43..17F9] |
| DeployNativeEthStack | ArtCoinsLpLocker | 0xd914c864d9aef3d8e51370139300ac534fb497b2 | CREATE | owner[0xcb43..17f9] | 0xa2769100e720e7bb3ac3ae7d842b2f2fbf37e196f817d51af43f934ad998c6b7 | 25125711 | 2026-05-19 00:35 | yes | owner[0xCB43..17F9], ArtCoinsFactory[0xF051..793e], ArtCoinsFeeEscrow[0xDD1b..1C06], PositionManager[0xbD21..ee9e], Permit2[0x0000..8BA3] |
| DeployNativeEthStack | BurnRouter | 0x9304a81965ef3f7a092bd9efd8c2ffc411e5f34d | CREATE | owner[0xcb43..17f9] | 0x945e48719581af4b2c83b62a481b42786ced8832633d8c6a4211b93cfc4e62fb | 25125712 | 2026-05-19 00:35 | yes | owner[0xCB43..17F9] |
| DeployNativeEthStack | ArtCoinsHookStaticFee | 0xaad673ea3945df5f7ef328974d2c07c8bdcaa8cc | CREATE2 | owner[0xcb43..17f9] | 0xcfe2c7d616d79f73d4f9bd4397aed96552b8b1e3b63387594301a145c2657705 | 25125713 | 2026-05-19 00:35 | yes | PoolManager[0x0000..8A90], ArtCoinsFactory[0xF051..793e], ArtCoinsPoolExtensionAllowlist[0xd6D5..e6E8], WETH[0xC02a..6Cc2], ArtCoinsFeeEscrow[0xDD1b..1C06] |
| RedeployBurnRouter | BurnRouter | 0xe60046ee745b235109c10d322a1cbdb3c029de43 | CREATE | owner[0xcb43..17f9] | 0x1c3cd508b53f04228c730e3ffe0cb6ab1251be56f42306dcb4055fdcb4a424ab | 25126435 | 2026-05-19 03:01 | yes | owner[0xCB43..17F9] |

### wiring calls (CALL txs, excluding swaps, WETH deposit, approvals and chunk uploads)

| script | block | on chain | to | function | args | tx hash |
|---|---|---|---|---|---|---|
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setTokenImplementation(address) | ArtCoinsToken (fork)[0xA27B..60cA] | 0xf8683c5ce5.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setTeamFeeRecipient(address) | anvil0[0xf39F..2266] | 0x05b37bf8d1.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setHook(address,bool) | ArtCoinsHookStaticFeeV2 (fork)[0x6931..28Cc], true | 0x43f1b524ac.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setLocker(address,address,bool) | ArtCoinsLpLockerMultiple (fork)[0xe008..c59C], ArtCoinsHookStaticFeeV2 (fork)[0x6931..28Cc], true | 0x006a806f4b.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setMevModule(address,bool) | ArtCoinsMevTimeDelay (fork)[0x7797..8313], true | 0x9c2ccc4c96.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setMevModule(address,bool) | ArtCoinsMevDescendingFees (fork)[0x1F32..3548], true | 0x9e9a586984.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setMevModule(address,bool) | ArtCoinsMevLinearFees (fork)[0xc221..3972], true | 0x5abcca4c11.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setMevModule(address,bool) | ArtCoinsMevSniperSteppedFees (fork)[0xABd7..257a], true | 0x07a29bc1fc.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setExtension(address,bool) | ArtCoinsVault (fork)[0x710E..9Afb], true | 0xbbcbe5e185.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setExtension(address,bool) | ArtCoinsAirdropV2 (fork)[0xD826..4a23], true | 0xb9c26483f5.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setExtension(address,bool) | ArtCoinsUniv4EthDevBuy (fork)[0x6B7D..d477], true | 0x035ea373d5.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFeeLocker (fork)[0x8375..486a] | addDepositor(address) | ArtCoinsLpLockerMultiple (fork)[0xe008..c59C] | 0x94a6857e2b.. |
| Deploy | 25029687* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setDeprecated(bool) | false | 0xa04f22e87a.. |
| DeployBurnExtension | 25029691* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | setExtension(address,bool) | BurnExtension (fork)[0x8353..19a9], true | 0x63582db911.. |
| LaunchLayer | 25029693* | no (fork) | BurnRouter (fork)[0x16a2..4224] | initialize(address,address,address,address,(address,address,uint24,int24,address)) | 0x59A7..89C4, WETH[0xC02a..6Cc2], UniversalRouter[0x66a9..A8Af], Permit2[0x0000..8BA3], (0x59A7D87DFCdaCe9f7.. | 0x1b2023a8da.. |
| LaunchLayer | 25029694* | no (fork) | ArtCoinsFactory (fork)[0xbcd5..a947] | deployToken(((address,string,string,bytes32,string,string,string,uint256,address),(address,address,int24,int24,bytes),(address,address[],address[],uint16[],int24[],int24[],uint16[],bytes),(address,bytes),(address,bool),(address,uint256,uint16,bytes)[])) | ((0xf39Fd6e51aad88F6.. | 0xbf5b6a93e3.. |
| Deploy | 25040121 | yes | ArtCoinsFactory[0xd159..92f9] | setTeamFeeRecipient(address) | owner[0xCB43..17F9] | 0x55c6e3e35b.. |
| Deploy | 25040151 | yes | LiquidityLayerOnchainRenderer[0x93bd..d7d4] | setSupplyConfig(uint256,uint8) | 1000000000000000000000000000, 18 | 0x2297d12c93.. |
| Deploy | 25040152 | yes | LiquidityLayerOnchainRenderer[0x93bd..d7d4] | setImageOverrideUri(string) | ipfs://bafkreiguuln4.. | 0x8f4486dd16.. |
| Deploy | 25040156 | yes | LiquidityLayerOnchainRenderer[0x93bd..d7d4] | setHistoryAsset(string) | ll/history.b64.1778120217836 | 0xf914d9ede1.. |
| Deploy | 25040158 | yes | ArtCoinsFactory[0xd159..92f9] | setHook(address,bool) | ArtCoinsHookStaticFeeV2[0xA5eA..28cc], true | 0xd997d4f393.. |
| Deploy | 25040159 | yes | ArtCoinsFactory[0xd159..92f9] | setLocker(address,address,bool) | ArtCoinsLpLockerMultiple[0x75BE..1118], ArtCoinsHookStaticFeeV2[0xA5eA..28cc], true | 0xdda0884126.. |
| Deploy | 25040160 | yes | ArtCoinsFactory[0xd159..92f9] | setMevModule(address,bool) | ArtCoinsMevTimeDelay[0xf080..A8Fb], true | 0x649b221606.. |
| Deploy | 25040161 | yes | ArtCoinsFactory[0xd159..92f9] | setMevModule(address,bool) | ArtCoinsMevDescendingFees[0x7958..4301], true | 0xf3e0656366.. |
| Deploy | 25040162 | yes | ArtCoinsFactory[0xd159..92f9] | setMevModule(address,bool) | ArtCoinsMevLinearFees[0xAe19..8C6F], true | 0x5616e25f98.. |
| Deploy | 25040163 | yes | ArtCoinsFactory[0xd159..92f9] | setMevModule(address,bool) | ArtCoinsMevSniperSteppedFees[0x1AB0..B935], true | 0xa0de9c2f82.. |
| Deploy | 25040164 | yes | ArtCoinsFactory[0xd159..92f9] | setExtension(address,bool) | ArtCoinsVault[0x8473..C661], true | 0x67aad7d2af.. |
| Deploy | 25040165 | yes | ArtCoinsFactory[0xd159..92f9] | setExtension(address,bool) | ArtCoinsAirdropV2[0xF937..27eC], true | 0x6abf1ceb9b.. |
| Deploy | 25040168 | yes | ArtCoinsFactory[0xd159..92f9] | setExtension(address,bool) | BurnExtension[0x034d..A1CE], true | 0x0130acba1b.. |
| Deploy | 25040169 | yes | ArtCoinsFactory[0xd159..92f9] | setExtension(address,bool) | ArtCoinsUniv4EthDevBuy[0xfCB6..cF30], true | 0x15a0d4f238.. |
| Deploy | 25040170 | yes | ArtCoinsPoolExtensionAllowlist[0xdd06..01e4] | setPoolExtension(address,bool) | LiquidityLayerCounterPoolExtension[0xc4a1..0A65], true | 0xa96abda051.. |
| Deploy | 25040171 | yes | ArtCoinsFeeLocker[0x1143..6b05] | addDepositor(address) | ArtCoinsLpLockerMultiple[0x75BE..1118] | 0x413dca9310.. |
| Deploy | 25040172 | yes | ArtCoinsFactory[0xd159..92f9] | setDeployFee(uint256) | 0 | 0xb32213fe3b.. |
| BindProtocolFeeController | 25040234 | yes | ArtCoinsFactory[0xd159..92f9] | setTeamFeeRecipient(address) | ProtocolFeeController[0x5fDc..0A60] | 0x56e2a218b4.. |
| PrepareLayerLaunch | 25040237 | yes | BurnRouter[0x2edb..2000] | initialize(address,address,address,address,(address,address,uint24,int24,address)) | LAYER[0xb728..E6c9], WETH[0xC02a..6Cc2], UniversalRouter[0x66a9..A8Af], Permit2[0x0000..8BA3], (0xb7287e4A5b605aB92.. | 0xa73ebd2d40.. |
| LaunchLayer | 25045168* | no (fork) | ArtCoinsFactory[0xd159..92f9] | deployToken(((address,string,string,bytes32,string,string,string,uint256,address),(address,address,int24,int24,bytes),(address,address[],address[],uint16[],int24[],int24[],uint16[],bytes),(address,bytes),(address,bool),(address,uint256,uint16,bytes)[])) | ((0xCB43078C32423F53.. | 0x2b735bf866.. |
| SetUpLayerAutoForward | 25054786 | yes | LiquidityLayerAutoForwardExtension[0x38d0..03f7] | seedCounters(bytes32,uint128,uint128) | 0x85c15a70d86374f345.., 321, 410 | 0xe446f6e2bd.. |
| SetUpLayerAutoForward | 25054786 | yes | LiquidityLayerAutoForwardExtension[0x38d0..03f7] | seedHistory(bytes32,uint256[]) | 0x85c15a70d86374f345.., [7416691298458646117.. | 0x24f055f8fd.. |
| SetUpLayerAutoForward | 25054789 | yes | ArtCoinsPoolExtensionAllowlist[0xdd06..01e4] | setPoolExtension(address,bool) | LiquidityLayerAutoForwardExtension[0x38d0..03f7], true | 0xfb1cb76262.. |
| SetUpLayerAutoForward | 25054789 | yes | ArtCoinsHookStaticFeeV2[0xa5ea..28cc] | setPoolExtension((address,address,uint24,int24,address),address,bytes) | (0xb7287e4A5b605aB92.., LiquidityLayerAutoForwardExtension[0x38d0..03f7], 0x | 0x25bae07c47.. |
| MigrateLayerRenderer | 25054793 | yes | LAYER[0xb728..e6c9] | setMetadataRenderer(address) | LiquidityLayerOnchainRenderer[0x0572..d186] | 0x7084f1507c.. |
| MigrateLayerRenderer | 25054794 | yes | LiquidityLayerOnchainRenderer[0x0572..d186] | setHistoryAsset(string) | ll/history.b64.1778120217836 | 0x5983fe208e.. |
| MigrateLayerRenderer | 25054795 | yes | LiquidityLayerOnchainRenderer[0x0572..d186] | setSupplyConfig(uint256,uint8) | 1000000000000000000000000000, 18 | 0xb59d57ee69.. |
| MigrateLayerRenderer | 25054796 | yes | LiquidityLayerOnchainRenderer[0x0572..d186] | setImageOverrideUri(string) | ipfs://bafkreiguuln4.. | 0x9df100c8e4.. |
| DeployNativeEthStack | 25125714 | yes | ArtCoinsFactory[0xf051..793e] | setHook(address,bool) | ArtCoinsHookStaticFee[0xAAd6..A8Cc], true | 0xbd7d296b53.. |
| DeployNativeEthStack | 25125715 | yes | ArtCoinsFactory[0xf051..793e] | setLocker(address,address,bool) | ArtCoinsLpLocker[0xd914..97b2], ArtCoinsHookStaticFee[0xAAd6..A8Cc], true | 0x861f7eccf6.. |
| DeployNativeEthStack | 25125716 | yes | ArtCoinsFactory[0xf051..793e] | setTeamFeeRecipient(address) | BurnRouter[0x9304..F34d] | 0x3ba88bc578.. |
| DeployNativeEthStack | 25125717 | yes | ArtCoinsFactory[0xf051..793e] | setDeployFee(uint256) | 0 | 0x44832c7c28.. |
| DeployNativeEthStack | 25125718 | yes | ArtCoinsFactory[0xf051..793e] | setDeprecated(bool) | false | 0xe340760327.. |
| DeployNativeEthStack | 25125719 | yes | ArtCoinsFeeEscrow[0xdd1b..1c06] | addDepositor(address) | ArtCoinsLpLocker[0xd914..97b2] | 0xffb3824edd.. |
| DeployNativeEthStack | 25125720 | yes | ArtCoinsFeeEscrow[0xdd1b..1c06] | addDepositor(address) | ArtCoinsHookStaticFee[0xAAd6..A8Cc] | 0x5cc49c9583.. |
| DeployNativeEthStack | 25125721 | yes | BurnRouter[0x9304..f34d] | initialize(address,address,address,address,(address,address,uint24,int24,address)) | LAYER[0xb728..E6c9], WETH[0xC02a..6Cc2], UniversalRouter[0x66a9..A8Af], Permit2[0x0000..8BA3], (0xb7287e4A5b605aB92.. | 0x89023d0451.. |
| RedeployBurnRouter | 25126436 | yes | BurnRouter[0xe600..de43] | initialize(address,address,address,address,(address,address,uint24,int24,address),address,uint256) | LAYER[0xb728..E6c9], WETH[0xC02a..6Cc2], UniversalRouter[0x66a9..A8Af], Permit2[0x0000..8BA3], (0xb7287e4A5b605aB92.., PoolManager[0x0000..8A90], 1000 | 0xbe46114dfe.. |
| RedeployBurnRouter | 25126437 | yes | BurnRouter[0xe600..de43] | setMinLayerOutPerWeth(uint256) | 10353406001448087114251066 | 0x3bb0eb89a1.. |
| RedeployBurnRouter | 25126439 | yes | ArtCoinsFactory[0xf051..793e] | setTeamFeeRecipient(address) | BurnRouter[0xE600..De43] | 0xee7f4f7ea2.. |

chunk uploads: `createContent` x3 and `addChunkToContent` x7 against ScriptyStorage 0xbD11… produced the 7 `ScriptyContentChunk` contracts (the `additionalContracts` of those txs). test traffic: 17 `PoolSwapTest.swap`, WETH `deposit`/`approve`, token `approve` calls from `LiveSwapVerify`, `LiveSellVerify`, `LiveNoOpVerify` (on chain, 2026-05-09) and `TraceTestTokenFees` (fork).

### sepolia (not in the registry)

817 unique txs, 12 scripts that deploy, 38 distinct contract names. 14 factories were deployed (13 `ArtCoinsFactory` plus one `NewMaterialFactory`), i.e. every rehearsal redeployed the whole stack. none of them is the one hardcoded in the ui.

| utc date | factory | block |
|---|---|---|
| 2026-04-29 | 0x9534eb9ea68db7c2e47f278d3297ab9028413f6e (NewMaterialFactory) | 10757077 |
| 2026-04-30 | 0x8a28dadb889cd7f18992a27d6b428182d10ace5d | 10764648 |
| 2026-05-04 | 0xac2c38801485451317d9212d9631b1221a11ad6c (the stack shown in `ui/src/pages/FeeFlowPage.tsx`) | 10790129 |
| 2026-05-05 | 0xdb96aa51463ee05f0560404eb37e361fe06d32c4 | 10795866 |
| 2026-05-06 | 0x27dfe5ef…, 0x74d4adbe…, 0x376a9045…, 0x202088e2…, 0x38cf0ee1…, 0x6b5eb0de…, 0x6cb7051a…, 0x0da8bab2…, 0xf69e3908… (9 rehearsals) | 10798025 to 10803847 |
| 2026-05-07 | 0xe18d3bec526feef737a0fc05ec90a0c5a34c74b2 (latest; same contract set as the mainnet legacy stack, same CREATE2 `ArtCoinsDeployer` address 0xbb0f…) | 10804429 |

`ui/src/lib/config.ts` SEPOLIA factory `0x3c3aEfC8…` (block 10665708, 2026-04-15) matches none of these.

## address inventory of the repo

grep `0x[0-9a-fA-F]{40}` over tracked and untracked files outside `lib/`, `broadcast/`, `foundry-out/`, `cache/`, `deployments/`. infra addresses (PoolManager 0x0000…8A90, PositionManager 0xbD21…64ee9e, Permit2 0x0000…8BA3, WETH 0xC02a…6Cc2, universal router 0x66a9…BA8Af, create2 deployer 0x4e59…56C, StateView 0x7fFE…7227) are correct everywhere they appear and are left out. verdict values: correct, stale, wrong, n/a.

| file:line | address(es) | verdict | exact edit |
|---|---|---|---|
| `AGENTS.md:64` (`CLAUDE.md` is a symlink to it) | none, text says "factory deployed 2026-05-18; see README for the current addresses" | wrong | no factory was deployed 2026-05-18 (legacy 2026-05-07, open 2026-05-19, current 2026-06-06) and README holds no addresses. replace with: `**Mainnet live**: three factories, current is 0x49596c375c139E79bb937bcf826068a8F78D4e0e (2026-06-06). Source of truth: deployments/mainnet.json, checked by script-js/verify-registry.mjs.` |
| `README.md` (no addresses) | none | stale | add a "Deployments" section pointing at `deployments/mainnet.json` with the current stack table (factory, hook, locker, escrow, mev module, 111). line 86 `forge script script/Deploy.s.sol ... --broadcast --verify` deploys the legacy stack with the old token proxy flow; the current stack comes from `script/DeployV1Stack.s.sol` under `FOUNDRY_PROFILE=tune`. line 83 says the factory ships `deprecated = true` and the owner flips it, true for 0x4959 |
| `.env.example:29,32,35,38` | zero placeholders for FACTORY, HOOK, LOCKER, MEV_LINEAR | correct as placeholders, stale comments | comments at lines 31 and 34 name `NewMaterialHookStaticFeeV2` and `NewMaterialLpLockerMultiple`: rename to `ArtCoinsHookStaticFeeV2` and `ArtCoinsLpLockerMultiple`, or point to the registry for mainnet values |
| `.env.example:41-43` | WETH mainnet 0xC02a…, sepolia 0xfFf9… | correct | none |
| `ui/src/lib/config.ts:28-44` | factory, hook, locker, mevLinearFees, mevDescFees, mevTimeDelay, vault, airdrop, devBuy, stateView, quoter all `ZERO` for chain 1 | wrong | ui cannot work on mainnet. set from registry: factory 0x49596c375c139E79bb937bcf826068a8F78D4e0e, hook 0x636c050296B5Cc528D8785169Bf8923716FCa9cc, locker 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab, stateView 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227, mevLinearFees slot becomes the skim module 0xb038D597365FfD108D63C265Bb0621444a1D8B83; vault, airdrop, devBuy, mevDesc, mevTimeDelay have no current stack deployment (legacy 0x8473…, 0xF937…, 0xfCB6…, 0x7958…, 0xf080… exist only on the legacy factory). the ui must also list legacy factory 0xD1595A27… (LAYER) for coin discovery |
| `ui/src/lib/config.ts:78-80` | `1: 0n` factory deployment block | wrong | use 25260062 for the current factory (25040120 for legacy). genesis scans are slow and rate limited |
| `ui/src/lib/config.ts:71` | falls back to SEPOLIA for unknown chains | stale | return undefined or throw instead of silently pointing a mainnet user at sepolia contracts |
| `ui/src/lib/config.ts:47-63` | sepolia stack (2026-04-15) | stale | factory 0x3c3aEfC8… matches no sepolia broadcast record; latest sepolia factory is 0xe18d3bec526feef737a0fc05ec90a0c5a34c74b2. update or drop sepolia |
| `ui/public/config.json:3` | defaultReferrer 0x41c3BD8A…A6A4 | correct | none (registry entry `PassThroughWallet`) |
| `ui/src/pages/FeeFlowPage.tsx:62-70` and below | 22 sepolia rehearsal addresses (factory 0xac2c3880…) | n/a | labelled sepolia snapshot, correct for what it says. no mainnet content |
| `ui/public/allowlists/liquidity-layer.json` | wallet addresses and the owner eoa | n/a | not contracts |
| `script/DeployConversionLockerAndWire.s.sol:58-61` | FACTORY 0xF051…, HOOK 0xAAd6…, ESCROW 0xDD1b…, MEV_LINEAR_FEES 0xAe19… | wrong | wires a conversion locker into the superseded open stack, and `MEV_LINEAR_FEES` 0xAe19… belongs to the legacy stack. do not run. delete the script or repoint at the current stack via the registry |
| `script/DeployPCController.s.sol:36,41` | doc says LAYER burn router 0x2edbdf01… for mainnet | stale | the live PC controller 0xd8C6… uses burn router 0x0EB22955E8904b8C5a4EC6f1D476f5b0C93854ca. fix the comment (and the claim "reuses the EXISTING LAYER BurnRouter") |
| `script/FullDryRun.s.sol:55-67`, `script/SetUpLayerAutoForward.s.sol:59-65`, `script/TraceTestTokenFees.s.sol:41-44`, `script/LiveNoOpVerify.s.sol:26-30`, `LiveSellVerify.s.sol`, `LiveSwapVerify.s.sol` | LAYER 0xb7287e4A…, hook 0xA5eA…, locker 0x75BE…, fee locker 0x1143…, controller 0x5fDc…, router 0x2eDB…, extension 0x38d0… | correct | all equal the registry legacy stack. no edit |
| `script/MigrateLayerRenderer.s.sol:34-38` | LAYER, ScriptyBuilder 0xD758…, ScriptyStorage 0xbD11…, comment "live renderer 0x93bD…" | correct, stale comment | 0x93bD… is no longer live, LAYER now uses 0x0572C175…. comment only |
| `script/Deploy.s.sol:55-64`, `DeployLLOnchainRenderer.s.sol:38-39`, `PreflightLaunch.s.sol:46-49`, `LaunchLayer.s.sol:68-69`, `PrepareLayerLaunch.s.sol:105,111`, `LaunchArtTest.s.sol:33`, `script/SmokeTest*Sepolia.s.sol`, `SwapLiquidityLayerSepolia.s.sol`, `SmokeBurnLayerSepolia.s.sol` | sepolia infra, ScriptyStorage 0xbD11…, ScriptyBuilder 0xD758… | correct | none |
| `script/LaunchDynamicToken.s.sol:21-25` | sepolia stack 0x3c3aEfC8… | stale | same dead sepolia stack as the ui; update or delete |
| `script/DeployV1Stack.s.sol` | infra only | correct | its header claims it replaces 0xF051 because that factory hard checks a pre rename hook interface id: unverified here (no 0xf051 coin or hook swap was run), but 0xf051 `version()` "3" supports it |
| `script-js/sync-addresses.mjs` | none, reads `broadcast/*/run-latest.json` | wrong | cannot produce the current stack and targets a sibling repo path. replace with a reader of `deployments/mainnet.json` or delete |
| `script-js/scan-burns.mjs:5`, `scan-liquidity-layer.mjs:26`, `scan-token-burns.mjs:5`, `scan-token-zero-burns.mjs:5` | 0x6B19a430…, 0x5a34646B… | n/a | Base chain (LL on base), not this registry |
| `script-js/data/*.csv|json`, `ui/public/allowlists/*.json` | depositor wallets | n/a | data, not deployments |
| `test/AutoBurnOpenTabForkTest.t.sol:112-118` | LAYER, legacy hook, open factory 0xF051…, hook 0xAAd6…, escrow 0xDD1b… | correct | all in the registry (open stack and legacy). note it pins the superseded open stack |
| `test/FeeAutoSwapperLayerRetrofit.t.sol:40-45`, `test/LiquidityLayerAutoForwardExtensionForkTest.t.sol:81-90` | legacy stack | correct | none |
| `test/MainnetLaunchRehearsalForkTest.t.sol:98-101` | owner 0xCB43…, payout 0x41c3… | correct | none |
| `test/DeployV1StackForkTest.t.sol:38` | owner | correct | none |
| `test/v2/harness/ForkBase.sol:60-87`, `test/v2/KeeperV1_111.fork.t.sol:42-116`, `test/v2/review/**/Fork*.sol`, `LiveStack.t.sol`, `LiveForkReview.t.sol:42-50` | current, open, legacy stack addresses, 111, LAYER | correct | all match the registry; ForkBase.sol:77 uses allowlist 0xd6D5 (open stack, same one the current hook uses) |
| `test/FeeMathReconciliationForkTest.t.sol:50-60`, `test/HookProtocolFeeNumeratorZero.t.sol:36-40`, `test/Integration.t.sol:28-30` | sepolia stack 0xac2c3880…, sepolia infra | n/a | sepolia fork tests |
| `test/ArtCoinsTokenTax.t.sol:25,28`, `test/v2/review/factory-token/FactoryTokenReview.t.sol:31-34` | USDC 0xA0b8…, other mainnet third party tokens/pools | correct | none |
| `test/LaunchLayerScriptChecks.t.sol:199,224` | 0xC0FFEe…0001 | n/a | synthetic address |
| `foundry.toml` | no addresses | stale comments | lines 32-37: `tune` comment says the hook lands at about 24,547 bytes with 29 bytes headroom; current head is about 20.6 KB at runs 200 after `SkimFeeInitLib` was split out, and 24,578 (over the limit) at runs 20000. also add a note that the deployed stack carries ipfs metadata |
| `.github/workflows/test.yml` | none | correct | none; the new `registry.yml` is separate |

## ci

`.github/workflows/registry.yml` triggers: push, pull_request, workflow_dispatch, weekly (monday 06:17 utc).

| job | what | rpc |
|---|---|---|
| `shape` | `node script-js/verify-registry.mjs --shape` (exact key set, enums, address and hash formats, factory entries, unique addresses) | none |
| `chain` | foundry v1.5.0, two builds (default into `foundry-out`, `FOUNDRY_PROFILE=ci FOUNDRY_BYTECODE_HASH=ipfs FOUNDRY_CBOR_METADATA=true` into `out/ci` with its own cache), then `node script-js/verify-registry.mjs --require-artifacts` | `MAINNET_RPC_URL` secret, falls back to `https://mainnet.gateway.tenderly.co` when empty, so it never skips. exit 1 (drift) fails at once; exit 2 (rpc error after viem's own 6 retries) is retried 3 times then fails |

drift means: no code at an address, `owner()` differs, factory `deprecated()` or allowlist state differs from `state`, a wiring getter (`factory()`, `feeLocker()`, `feeEscrow()`, `hook()`, `burnRouter()`, `poolExtensionAllowlist()`) points outside the registry, a locker or hook is not an escrow depositor, a coin's name, symbol, pool hook, fee, tick spacing or paired token differs, a factory logged a coin the registry lacks (or the reverse), a launch tx or block differs, or `bytecodeMatch` differs from the recomputed value. missing artifacts print `UNCHECKED` and fail under `--require-artifacts`.

flags: `--fill` writes owner, state, bytecodeMatch, commit, chainVerified, coin pool fields, `repoCommit`, `generatedAt` back; `--update-blocks` re-derives `deployBlock`/`deployedAt`/`launchBlock` by bisecting `eth_getCode` (needs an archive rpc, tenderly public answers); `--artifacts a,b` sets artifact dirs (default `foundry-out,out/ci`); `--file` picks another registry.

### git ignore hygiene (needs a change outside my write scope)

| item | state | recommendation |
|---|---|---|
| `script-js/package-lock.json` | ignored by `.gitignore:35` | un-ignore and commit it, then switch both jobs to `npm ci` (the workflow comments say so). today it runs `npm install --ignore-scripts` so viem floats within `^2.57.3` |
| `script-js/package.json` | now has `viem ^2.57.3` next to `puppeteer` and `sharp`, which the verifier does not need | ci sets `PUPPETEER_SKIP_DOWNLOAD` and `--ignore-scripts`. a smaller `script-js/registry/package.json` would be cleaner |
| `out/` | already ignored; the ci artifacts live in `out/ci` | none |
| `broadcast/` | 124 files tracked, including 20 fork only mainnet runs | see next section |

## sensitive and hygiene items in `broadcast/`

| item | detail |
|---|---|
| secrets | none found: no private keys, mnemonics, rpc urls or api keys (grepped for key, secret, mnemonic, alchemy, infura, api, http in every mainnet record; the only urls are testnet token image links in sepolia calldata). no local paths |
| identity | the real deployer eoa and the anvil default account (`0xf39F…2266`, public test key, recorded as sender of mainnet chain id fork runs) appear. the anvil key must never hold funds on any real chain |
| misleading records | 20 fork only mainnet creates and 44 txs not on chain are indistinguishable from real ones except by the sender. consider moving the 2026-05-05 runs and `TraceTestTokenFees` out of `broadcast/1/` or deleting them |
| source provenance | `commit` fields point at commits that do not exist in this repo |
| size | 17 MB, 817 sepolia txs |
| calldata | the LAYER renderer and sketch assets (base64 js) are in `Deploy.s.sol` calldata; public data, no concern |
| not covered | the current stack was deployed from an environment that left no record here. if the keystore or checkout used for it is separate, its broadcast folder holds the missing records |

## verification run

`node script-js/verify-registry.mjs` against the tenderly public gateway (`MAINNET_RPC_URL` unset), with `foundry-out` built from the default profile and `out/ci` built with `FOUNDRY_PROFILE=ci FOUNDRY_BYTECODE_HASH=ipfs FOUNDRY_CBOR_METADATA=true`. exit code 0. the `--fill` run that wrote the registry used the same artifacts.

```
registry deployments/mainnet.json @ f9944225  rpc https://mainnet.gateway.tenderly.co  head 26130485  artifacts foundry-out,out/ci
contract                           address     stack    role       code  owner   state       bytecode    wiring
ArtCoinsDeployer                   0xbb0F4d97  legacy   other      ok    n/a     n/a         mismatch    ok    
ArtCoinsFeeLocker                  0x1143db09  legacy   escrow     ok    ok      n/a         verified    ok    
ArtCoinsFactory                    0xD1595A27  legacy   factory    ok    ok      deprecated  mismatch    ok    
ArtCoinsPoolExtensionAllowlist     0xDD06Ba83  legacy   allowlist  ok    ok      n/a         verified    ok    
ArtCoinsHookStaticFeeV2            0xA5eA9904  legacy   hook       ok    n/a     enabled     mismatch    ok    
ArtCoinsLpLockerMultiple           0x75BE7E95  legacy   locker     ok    ok      enabled     verified    ok    
ArtCoinsMevTimeDelay               0xf080D741  legacy   mevModule  ok    n/a     enabled     mismatch    ok    
ArtCoinsMevDescendingFees          0x7958DE7d  legacy   mevModule  ok    n/a     enabled     mismatch    ok    
ArtCoinsMevLinearFees              0xAe19E402  legacy   mevModule  ok    n/a     enabled     mismatch    ok    
ArtCoinsMevSniperSteppedFees       0x1AB013eb  legacy   mevModule  ok    n/a     enabled     mismatch    ok    
ArtCoinsVault                      0x84732a79  legacy   extension  ok    n/a     enabled     verified    ok    
ArtCoinsAirdropV2                  0xF937dFf1  legacy   extension  ok    n/a     enabled     verified    ok    
BurnExtension                      0x034d6bAb  legacy   extension  ok    n/a     enabled     verified    ok    
ArtCoinsUniv4EthDevBuy             0xfCB6a929  legacy   extension  ok    n/a     enabled     mismatch    ok    
DefaultMetadataRenderer            0x7dBfF015  legacy   renderer   ok    n/a     n/a         mismatch    ok    
LiquidityLayerCounterPoolExtension 0xc4a1E947  legacy   extension  ok    n/a     enabled     verified    ok    
ScriptyContentChunk                0x8d145548  legacy   other      ok    n/a     n/a         unverified  ok    
ScriptyContentChunk                0x049Ef213  legacy   other      ok    n/a     n/a         unverified  ok    
ScriptyContentChunk                0xb18D0c05  legacy   other      ok    n/a     n/a         unverified  ok    
ScriptyContentChunk                0x2F144CD5  legacy   other      ok    n/a     n/a         unverified  ok    
ScriptyContentChunk                0x10F4aBE4  legacy   other      ok    n/a     n/a         unverified  ok    
ScriptyContentChunk                0x2Ebd66Cc  legacy   other      ok    n/a     n/a         unverified  ok    
LiquidityLayerOnchainRenderer      0x93bDB246  legacy   renderer   ok    ok      n/a         mismatch    ok    
ScriptyContentChunk                0xD85dC362  legacy   other      ok    n/a     n/a         unverified  ok    
BurnRouter                         0x2eDBdF01  legacy   router     ok    ok      n/a         verified    ok    
ProtocolFeeController              0x5fDc3975  legacy   controller ok    ok      n/a         verified    ok    
ArtCoinsToken                      0xb7287e4A  legacy   token      ok    n/a     n/a         mismatch    ok    
LiquidityLayerAutoForwardExtension 0x38d03af5  legacy   extension  ok    ok      enabled     verified    ok    
LiquidityLayerOnchainRenderer      0x0572C175  legacy   renderer   ok    ok      n/a         mismatch    ok    
PoolSwapTest                       0x3C78371f  legacy   other      ok    n/a     n/a         unverified  ok    
PoolSwapTest                       0x2C0A19db  legacy   other      ok    n/a     n/a         unverified  ok    
PoolSwapTest                       0x87cfCe91  legacy   other      ok    n/a     n/a         unverified  ok    
ArtCoinsFactory                    0xF051cd4C  open     factory    ok    ok      enabled     mismatch    ok    
ArtCoinsPoolExtensionAllowlist     0xd6D5fb5C  open     allowlist  ok    ok      n/a         verified    ok    
ArtCoinsFeeEscrow                  0xDD1b8C9C  open     escrow     ok    ok      n/a         verified    ok    
ArtCoinsLpLocker                   0xd914c864  open     locker     ok    ok      enabled     mismatch    ok    
BurnRouter                         0x9304a819  open     router     ok    ok      n/a         mismatch    ok    
ArtCoinsHookStaticFee              0xAAd673ea  open     hook       ok    n/a     enabled     mismatch    ok    
BurnRouter                         0xE60046ee  open     router     ok    ok      n/a         mismatch    ok    
PassThroughWallet                  0x41c3BD8A  current  other      ok    ok      n/a         unverified  ok    
ArtCoinsDeployer                   0x92584B32  current  other      ok    n/a     n/a         verified    ok    
SkimFeeInitLib                     0x115510a7  current  other      ok    n/a     n/a         verified    ok    
ArtCoinsFactory                    0x49596c37  current  factory    ok    ok      deprecated  verified    ok    
ArtCoinsFeeEscrow                  0x75596897  current  escrow     ok    ok      n/a         verified    ok    
ArtCoinsHookSkimFee                0x636c0502  current  hook       ok    n/a     enabled     verified    ok    
ArtCoinsMevLinearSkim              0xb038D597  current  mevModule  ok    n/a     enabled     verified    ok    
ProtocolFeeController              0xd8C63401  current  controller ok    ok      n/a         verified    ok    
ArtCoinsLpLocker                   0x866ea3Dc  current  locker     ok    ok      enabled     verified    ok    
LiveBidAdapter                     0x8C72FBc2  current  other      ok    n/a     n/a         unverified  ok    
ProtocolFeePhaseAdapter            0xed3E9D3B  current  other      ok    n/a     n/a         unverified  ok    
UnverifiedPcRenderer               0x760421B7  current  renderer   ok    n/a     n/a         unverified  ok    
TokenAdminPoker                    0xA96a1125  current  other      ok    ok      n/a         unverified  ok    
UnverifiedPcContract               0xB03Cbd86  current  other      ok    n/a     n/a         unverified  ok    
FeeAutoSwapper                     0xeBD9B74A  current  swapper    ok    n/a     n/a         mismatch    ok    
ArtCoinsToken                      0x61C9d89f  current  token      ok    n/a     n/a         verified    ok    
BurnRouter                         0x0EB22955  current  router     ok    ok      n/a         verified    ok    

coin     address     stack    name/symbol/pool  launched on chain by stack factory
LAYER    0xb7287e4A  legacy   ok                1 coin(s) in legacy factory logs
111      0x61C9d89f  current  ok                1 coin(s) in current factory logs
stack coin counts: legacy=1 open=0 current=1

ok: 56 contracts, 2 coins, 0 drift, 0 warning(s)
```

negative tests run against edited copies: a flipped factory `state`, a wrong locker `owner`, a wrong `bytecodeMatch`, a wrong coin symbol and a coin missing from the registry each exited 1 with the row listed. an unreachable rpc exits 2. `--artifacts /nonexistent --require-artifacts` lists every contract as UNCHECKED and fails.

## limits

| limit | detail |
|---|---|
| etherscan | not queried successfully (no key); `etherscanVerified` is `unknown`. blockscout flags are in notes. run `--fill` after wiring a key if the field should flip |
| source provenance | `bytecodeMatch` proves head source equals deployed code, not that the deploy came from this commit. metadata hashes differ so a source text difference limited to comments cannot be excluded |
| unverified source | permanent-collection contracts, scripty chunks and `PoolSwapTest` helpers have `repoPath` null so they are `unverified` by design |
| escrow and router state | `state` is `unknown` for roles with no on-chain enabled flag |
| call budget | batched json rpc over the tenderly gateway (no 429 left unhandled), about 85 blockscout calls (address pages plus 17 pages of the owner's tx history), 2 etherscan calls, both refused |

## profile aware bytecode compare (verify-registry.mjs, added after the 13 mismatch report)

cause of the report: the local `foundry-out` had been built at the `ci` profile (runs 200) while the legacy and open stacks were deployed at the default profile (runs 20,000), and the current stack only matches at `ci` with ipfs metadata. one artifact set cannot serve both, so the verifier now keeps one out dir per build variant and every registry contract records which variant it was deployed with.

| item | detail |
|---|---|
| registry fields | `source.profile` (`default` or `ci`) and `source.metadata` (`none` or `ipfs`), both null for `unverified` sources and for a mismatch whose variant is unknown. a `verified` entry must have both. `deployments/v2.template.json` (planned stacks) may omit them |
| out dirs | `foundry-out-default` (runs 20000, no metadata), `foundry-out-ci` (runs 200, no metadata), `foundry-out-ci-ipfs` (ci plus `FOUNDRY_BYTECODE_HASH=ipfs FOUNDRY_CBOR_METADATA=true`), `foundry-out-default-ipfs` (only tried under `--discover`, matches nothing today) |
| build | `FOUNDRY_PROFILE=<p> forge build --skip "test/**" --skip script -o foundry-out-<tag> --cache-path cache/<tag>`. no `--extra-output-files` needed: forge artifacts already carry `metadata.settings`, which the verifier reads. env `FORGE` overrides the binary (here `/tmp/claude-0/forge.sh`) |
| flags | `--build` runs the builds for the variants the registry needs, `--no-build` (default) uses the dirs as they are, `--discover` ignores the recorded variant and tries all, `--fill-source` writes only `source.{commit,bytecodeMatch,profile,metadata}` (it implies discover). `--fill` does the same plus the old fields |
| compare | exact bytes modulo immutables, library link slots and metadata hashes. a recorded variant is the only one that counts; the others are tried for a hint (`matches X instead of the recorded Y`). chain code that carries an ipfs hash prefers the ipfs variants, so the current stack records `ci/ipfs`; an artifact built without metadata is compared against chain code with its cbor trailer stripped (as before) |
| guard | a dir built with other settings than its name says (wrong runs or bytecodeHash) is rejected with a warning and its contracts are UNCHECKED, so a stale `foundry-out` can no longer produce silent mismatches. `--require-artifacts` fails on UNCHECKED |
| report | new `profile` column, `bytecode by profile: ...` totals and one `MISMATCH` line per mismatch with the first differing offset |
| ci | `.github/workflows/registry.yml` builds default, ci and ci-ipfs (all with the skips above) and runs `verify-registry.mjs --no-build --require-artifacts`. `script-js` has `npm run verify:registry` and `verify:registry:build` |

run: `source /tmp/claude-0/env.sh; NODE_USE_ENV_PROXY=1 FORGE=/tmp/claude-0/forge.sh node script-js/verify-registry.mjs --build --require-artifacts` (first run builds three variants, about 1.5 minutes each cold, seconds warm). exit 0, `ok: 56 contracts, 2 coins, 0 drift, 0 warning(s)`, `bytecode by profile: mismatch=18 default/none=13 ci/ipfs=9`.

### result

the registry statuses did not change: the same 22 verified, 18 mismatch and 16 unverified entries as before. the profile was never the whole story. the 13 legacy and open mismatches stay mismatches under the right profile (default), because head source differs from what was deployed. what changed is that each verified contract now names its variant and each mismatch is classified below. 0 mismatches was not reachable: the repo history starts on 2026-06-13, after all three stacks were deployed (2026-05-07, 2026-05-19, 2026-06-06), so the deployed source of the older contracts cannot be rebuilt from git.

| stack | contract | address | result | first diff (offset, chain bytes vs nearest artifact) |
|---|---|---|---|---|
| legacy | ArtCoinsDeployer | 0xbb0F4d97 | mismatch | @2 chain 12530 vs default/none 16811 |
| legacy | ArtCoinsFeeLocker | 0x1143db09 | verified default/none | - |
| legacy | ArtCoinsFactory | 0xD1595A27 | mismatch | @1252 chain 13804 vs default/none 13804 |
| legacy | ArtCoinsPoolExtensionAllowlist | 0xDD06Ba83 | verified default/none | - |
| legacy | ArtCoinsHookStaticFeeV2 | 0xA5eA9904 | mismatch | @33 chain 21202 vs default/none 21162 |
| legacy | ArtCoinsLpLockerMultiple | 0x75BE7E95 | verified default/none | - |
| legacy | ArtCoinsMevTimeDelay | 0xf080D741 | mismatch | @358 chain 1208 vs default/none 1262 |
| legacy | ArtCoinsMevDescendingFees | 0x7958DE7d | mismatch | @163 chain 3677 vs default/none 3731 |
| legacy | ArtCoinsMevLinearFees | 0xAe19E402 | mismatch | @218 chain 2831 vs default/none 2880 |
| legacy | ArtCoinsMevSniperSteppedFees | 0x1AB013eb | mismatch | @194 chain 3988 vs default/none 4037 |
| legacy | ArtCoinsVault | 0x84732a79 | verified default/none | - |
| legacy | ArtCoinsAirdropV2 | 0xF937dFf1 | verified default/none | - |
| legacy | BurnExtension | 0x034d6bAb | verified default/none | - |
| legacy | ArtCoinsUniv4EthDevBuy | 0xfCB6a929 | mismatch | @36 chain 6904 vs default/none 6934 |
| legacy | DefaultMetadataRenderer | 0x7dBfF015 | mismatch | @180 chain 2429 vs default/none 1952 |
| legacy | LiquidityLayerCounterPoolExtension | 0xc4a1E947 | verified default/none | - |
| legacy | LiquidityLayerOnchainRenderer | 0x93bDB246 | mismatch | @945 chain 14193 vs default/none 13930 |
| legacy | BurnRouter | 0x2eDBdF01 | verified default/none | - |
| legacy | ProtocolFeeController | 0x5fDc3975 | verified default/none | - |
| legacy | ArtCoinsToken | 0xb7287e4A | mismatch | @34 chain 9147 vs ci/none 8283 |
| legacy | LiquidityLayerAutoForwardExtension | 0x38d03af5 | verified default/none | - |
| legacy | LiquidityLayerOnchainRenderer | 0x0572C175 | mismatch | @945 chain 14193 vs default/none 13930 |
| open | ArtCoinsFactory | 0xF051cd4C | mismatch | @44 chain 13926 vs ci/none 12608 |
| open | ArtCoinsPoolExtensionAllowlist | 0xd6D5fb5C | verified default/none | - |
| open | ArtCoinsFeeEscrow | 0xDD1b8C9C | verified default/none | - |
| open | ArtCoinsLpLocker | 0xd914c864 | mismatch | @1972 chain 18504 vs default/none 18504 |
| open | BurnRouter | 0x9304a819 | mismatch | @2 chain 9247 vs default/none 10374 |
| open | ArtCoinsHookStaticFee | 0xAAd673ea | mismatch | @41 chain 21302 vs default/none 18959 |
| open | BurnRouter | 0xE60046ee | mismatch | @2 chain 11038 vs default/none 10374 |
| current | ArtCoinsDeployer | 0x92584B32 | verified ci/ipfs | - |
| current | SkimFeeInitLib | 0x115510a7 | verified ci/ipfs | - |
| current | ArtCoinsFactory | 0x49596c37 | verified ci/ipfs | - |
| current | ArtCoinsFeeEscrow | 0x75596897 | verified ci/ipfs | - |
| current | ArtCoinsHookSkimFee | 0x636c0502 | verified ci/ipfs | - |
| current | ArtCoinsMevLinearSkim | 0xb038D597 | verified ci/ipfs | - |
| current | ProtocolFeeController | 0xd8C63401 | verified ci/ipfs | - |
| current | ArtCoinsLpLocker | 0x866ea3Dc | verified ci/ipfs | - |
| current | FeeAutoSwapper | 0xeBD9B74A | mismatch | @45 chain 11086 vs ci/ipfs 7990 |
| current | ArtCoinsToken | 0x61C9d89f | verified ci/ipfs | - |
| current | BurnRouter | 0x0EB22955 | verified default/none | - |

`unverified` entries (16: scriptyChunks, PoolSwapTest helpers, permanent-collection contracts, PassThroughWallet and others with no `repoPath`) are not compared and have null profile fields.

### the 18 mismatches, explained

| class | contracts | evidence |
|---|---|---|
| default profile proven, source drift identified | open ArtCoinsLpLocker 0xd914c864 | 2 differing bytes at 1972 and 11648 (`0x0c` vs `0x0e`). deployed `MAX_LP_POSITIONS` was 12, head has 14. a scratch copy of `src` with the constant set to 12, built at default/none, matches the chain code with 0 differing bytes. recorded `profile default, metadata none` with `mismatch` (the verifier keeps a hand recorded profile on a mismatch) |
| default profile, small source drift | legacy ArtCoinsFactory (same length 13804, 28 bytes in 3 ranges), legacy ArtCoinsHookStaticFeeV2 (21202 vs 21162), legacy MEV modules x4 (within about 50 bytes), legacy ArtCoinsUniv4EthDevBuy (6904 vs 6934), legacy LiquidityLayerOnchainRenderer x2 (14193 vs 13930) | default/none is the closest variant by a wide margin (ci/none is 2,000 to 11,000 bytes off), so the deploy was at default, but head source has moved since. profile not recorded because it is not proven |
| source differs a lot, neither profile fits | legacy ArtCoinsDeployer (12530 vs 16811), legacy DefaultMetadataRenderer (2429 vs 1952), legacy ArtCoinsToken LAYER (9147 vs 10177 default, 8283 ci), open ArtCoinsFactory (13926 vs 15029 default, 12608 ci), open BurnRouter x2 (9247 and 11038 vs 10374, the two differ from each other), open ArtCoinsHookStaticFee (21302 vs 18959), current FeeAutoSwapper (chain 11086 with an ipfs hash vs 10072 default, 7990 ci/ipfs) | different source versions, not a settings difference. two BurnRouters on chain with different sizes against one head source shows head moved past both |

how to close the rest: recover the sources as deployed (any pre 2026-06-13 history, or the deploy machine) into a scratch dir and rebuild per variant. to record a variant by hand after proving it, set `source.profile` and `source.metadata` on the entry; `--fill-source` keeps them on a mismatch.

verification of the new logic (scratch registries): a recorded `ci/none` on a contract deployed at `ci/ipfs` still passes (the none build is compared with the cbor trailer stripped); a wrong recorded variant exits 1 with `matches X instead of the recorded Y`; a missing out dir is UNCHECKED and fails under `--require-artifacts`; a `foundry-out-ci-ipfs` that is really a no-metadata build is rejected with `WARN bad artifact dir`.

open item for the director: `.gitignore` ignores `foundry-out/` but not the new `foundry-out-*` dirs, so they show as untracked. add `foundry-out-*/` (outside this write scope).
