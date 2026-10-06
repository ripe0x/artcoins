# artcoins ops runbook

> disclosure: part 1 describes LF-01 (critical, live, immutable lockers) and other findings on deployed contracts. keep this file off the public mirror until the owner has run actions 1, 2 and 4 (collects and the open factory) and 5 (router floors). nothing here needs a code change. every address was read on chain at block 26130514 (2026-10-06) and every selector was checked against the deployed bytecode or the v1 source. the owner calls in actions 1, 2, 4, 5, 6 (scripty freeze, lockPoolExtension), 7 and 8 were simulated with `cast call --from $OWNER` and succeed today. nothing was broadcast.

## setup, used by every command

```
export MAINNET_RPC_URL=${MAINNET_RPC_URL:-https://mainnet.gateway.tenderly.co}
export OWNER=0xCB43078C32423F5348Cab5885911C3B5faE217F9        # single eoa, owner of nearly everything
export OWNER_KEY=<set in your shell from a keystore, never paste or commit>  # or use --account <keystore> instead of --private-key
export F_CUR=0x49596c375c139E79bb937bcf826068a8F78D4e0e F_OPEN=0xF051cd4C4F3F36F9f24d8a19d60Ee8F84FC6793e F_LEGACY=0xD1595A2742C392d1c109b616b4F08918D02292f9
export L111=0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab C111=0x61C9d89fe1212F6b55fF888816A151463287B8ae SWAPPER=0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961 ESCROW=0x7559689765aE86cBB38e68CD1294830CccB125F2
export LAYER=0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9 LLOCKER=0x75BE7E95745915fD0C1761B74F3f9650ad2d1118 LFEELOCKER=0x1143db0913Ca5eCe8A42FC01b625fD81F9386b05 LHOOK=0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc
export R_LAYER=0x2eDBdF011768d8cd4Ef537658b41440900C52000 R_OPEN=0xE60046ee745B235109C10d322A1cbDB3c029De43 RENDERER=0x0572C1754378c2f9Aef51b57b2830D343ee9d186 SCRIPTY=0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699
export WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 PM=0x000000000004444c5dc75cB358380D2e3dE08A90
```

rules for every send: (1) simulate first by swapping `cast send` for `cast call --from $OWNER` with the same arguments; (2) one tx at a time, check the verify line; (3) the owner key stays in a keystore or the shell, never in a file or argument list, and the keeper uses its own separate hot key; (4) every owner call is a plain eoa tx, none needs a multisig or a delay.

## order of play

| action | what | why now | cost |
|---|---|---|---|
| 1 | collect 111 fees, then keep collecting | LF-01 critical | gas only |
| 4 | deprecate open factory 0xf051 | public, zero fee, hijackable | one tx |
| 5 | set LAYER burn router floors | LF-09 | two txs |
| 3 | deploy and schedule the 111 collect and flush keeper | LF-01 and LF-02 mitigation | one deploy, cron |
| 2 | collect LAYER once | LF-01 on the legacy locker | gas |
| 8 | claim owner LAYER fee locker balance | 3.3M LAYER and 0.48 weth sit unclaimed | two txs |
| 6 | decide the LAYER freezes (scripty, renderer, extension) | irreversible, owner choice, do last | see 6 |
| 7, 9, 10 | keep 0x4959 deprecated, stranding limits, leave alone list | context | none |

## part 1: today, without redeploying

### 1. collect 111 lp fees now and keep collecting (LF-01, LF-02 window)

| field | value |
|---|---|
| finding | LF-01 critical: `collectRewardsWithoutUnlock` is permissionless and `TAKE_PAIR` takes the net position manager credit, so anyone can divert the fees still sitting in the lp positions. no switch exists on the locker (immutable, no pause). exposure is exactly what accrued since the last collect |
| contract | locker `0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab` |
| call | `collectRewards(address token)` selector 0x5763dbd0, arg = 111 `0x61C9d89fe1212F6b55fF888816A151463287B8ae` |
| caller | anyone. locker pays the caller `keeperRewardBps` of the eth side (live 0, so nothing) |
| send | `cast send $L111 "collectRewards(address)" $C111 --gas-limit 900000 --rpc-url $MAINNET_RPC_URL --private-key $OWNER_KEY` |
| read now | pending is 13,404 coin and 0 eth (simulated, 658k gas). the swapper then holds the coin, the eth side would sit at the escrow under the swapper slot |
| verify | `cast call $C111 "balanceOf(address)(uint256)" $SWAPPER --rpc-url $MAINNET_RPC_URL` rises by about the pending coin. `cast call $ESCROW "feesToClaim(address,address)(uint256)" $SWAPPER 0x0000000000000000000000000000000000000000 --rpc-url $MAINNET_RPC_URL` (eth credit, 0 expected now) |
| risk | gas (~665k, about 0.003 eth at 5 gwei) exceeds the 0.0007 eth value pending today: this resets the exposure, it does not earn. if an eth credit appears at the escrow, flush in the same minute (`cast send $SWAPPER "flushPaired()" --gas-limit 200000 ...`, 72k gas) because anyone can `escrow.claim(swapper, 0)` and strand it (LF-02, nothing recovers it). coin side: leave it in the swapper until a keeper run converts it with a real minOut, `convert(0)` invites a sandwich bounded only by the swapper's 80% of spot floor |
| keep collecting | action 3 keeper, hourly check, collect when `preview()` shows more than 0.02 eth or 10,000 coin uncollected, or weekly regardless. it shrinks exposure and cannot close the hole. v2 removes the function |

### 2. collect LAYER on the legacy locker (LF-01, legacy)

| field | value |
|---|---|
| finding | LF-01 on `ArtCoinsLpLockerMultiple`, same code path. smaller exposure: the legacy hook collects on swaps, ~403 LAYER (about 0.00002 eth) pending, 0 weth |
| contract | locker `0x75BE7E95745915fD0C1761B74F3f9650ad2d1118`, token LAYER `0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9` |
| call | `collectRewards(address token)` selector 0x5763dbd0 (checked in bytecode, simulation succeeds, 597k gas) |
| caller | anyone |
| send | `cast send $LLOCKER "collectRewards(address)" $LAYER --gas-limit 900000 --rpc-url $MAINNET_RPC_URL --private-key $OWNER_KEY` |
| split | slots read on chain: 3800 bps owner `0xCB43…` (credited to fee locker 0x1143), 4200 bps burn router 0x2eDB, 2000 bps protocol fee controller 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60. slot admins: owner for slots 0 and 1, factory 0xd159 for slot 2 |
| verify | `cast call $LFEELOCKER "availableFees(address,address)(uint256)" $OWNER $LAYER --rpc-url $MAINNET_RPC_URL` rises. `cast call $R_LAYER "status()(uint256,uint256,bool)" --rpc-url $MAINNET_RPC_URL` shows router balances |
| risk | gas only. do it once now and when LAYER trading volume is high. not worth a cron at current size |

### 3. deploy and run the 111 collect and flush keeper

| field | value |
|---|---|
| finding | LF-01 (reduces pending), LF-02 / K-01 (collect, flush and convert in one tx), K-04 (no third party earns enough to run it) |
| contract | `src/v2/keepers/CollectFlushKeeperV1.sol`, ctor `(locker, token, swapper, escrow)` pinned to `$L111 $C111 $SWAPPER $ESCROW`. no owner, holds nothing, any wallet can deploy and run it. use a dedicated hot key, not the owner key |
| deploy dry run | `forge script script/v2/RunKeeper111.s.sol:DeployKeeper111 --rpc-url $MAINNET_RPC_URL` |
| deploy | `forge script script/v2/RunKeeper111.s.sol:DeployKeeper111 --rpc-url $MAINNET_RPC_URL --broadcast --account <keystore>` then `export KEEPER_111=<printed address>`. record it in `deployments/mainnet.json` |
| check | `cast call $KEEPER_111 "preview()(uint256,uint256,uint256,uint256,uint256)" --rpc-url $MAINNET_RPC_URL` returns uncollectedEth, uncollectedCoin, escrowedEth, swapperEth, swapperCoin. `swapperEth > 0` means a third party already stranded eth |
| run dry | `forge script script/v2/RunKeeper111.s.sol:RunKeeper111 --rpc-url $MAINNET_RPC_URL` (prints preview and a quoted minOut, `KEEPER_SLIPPAGE_BPS` default 100) |
| run | `forge script script/v2/RunKeeper111.s.sol:RunKeeper111 --rpc-url $MAINNET_RPC_URL --broadcast --account <keystore> --gas-limit 1200000` (`run(bool doConvert, uint256 minOut)`, measured 799k gas, reverts below the per step gas floors instead of skipping) |
| cadence | cron hourly: read `preview()`, run when uncollectedEth > 0.02 eth, uncollectedCoin > 10,000e18, escrowedEth > 0.05 eth (flush overdue), or the weekly timer is due. skip if pending is worth less than the gas, unless the timer is due. convert has its own 50 block pacing, extra attempts are swallowed no ops. monitor `lastConvertBlock` age and `swapperEth` |
| verify | `cast call $SWAPPER "lastConvertBlock()(uint256)" --rpc-url $MAINNET_RPC_URL` moves after a convert. `cast balance $KEEPER_111` is 0 after every run |
| risk | cannot stop a griefer who calls `collectRewards` then `escrow.claim(swapper,0)` himself in one tx, cannot recover eth already stranded. send runs through a private relay. the key only pays gas, keep under 0.05 eth. proof tests: `test/v2/KeeperV1_111.fork.t.sol` (7) |

### 4. deprecate the open factory 0xf051 (FT-02, FT-03, S-03)

| field | value |
|---|---|
| finding | FT-02 launch hijack, FT-03 protocol bps zeroed by any caller, S-03 open by default. live: deprecated false, deployFee 0, version "3", owner 0xCB43, hook 0xAAd6 and locker 0xd914 enabled |
| confirm first | `cast call $F_OPEN "deprecated()(bool)" --rpc-url $MAINNET_RPC_URL` returns false. zero coins: `cast logs --address $F_OPEN --from-block 25125700 --to-block latest "TokenCreated(address,address,address,string,string,string,string,string,int24,address,bytes32,address,address,address,uint256,address[])" --rpc-url $MAINNET_RPC_URL` returns nothing (positive control: the same query on $F_CUR from block 25260000 returns the 111 launch) |
| contract and call | `$F_OPEN` `setDeprecated(bool)` selector 0xd848dee7, arg `true`. onlyOwner (also present on 0x4959 and 0xd159) |
| send | `cast send $F_OPEN "setDeprecated(bool)" true --rpc-url $MAINNET_RPC_URL --private-key $OWNER_KEY` |
| verify | `cast call $F_OPEN "deprecated()(bool)" --rpc-url $MAINNET_RPC_URL` returns true |
| risk | none for coins (zero launched). reversible by `setDeprecated(false)`. the allowlist 0xd6D5fb5CfE386d0eB73a09cba5d190beb802e6E8 is shared with the live hook 0x636c, do not touch it. no other action on 0xf051 is needed once deprecated (owner can still launch there) |

### 5. LAYER burn router floors (LF-09)

| field | value |
|---|---|
| finding | LF-09 high: the live routers burn the whole weth balance per call, the only guard is the owner floor `minLayerOutPerWeth` (LAYER out per 1e18 weth, 1e18 scaled), now 30.8% and 63.9% of spot. a floor above spot blocks burns until updated (safe), floor 0 pauses `processBurnWeth` with `SlippageFloorNotSet` |
| contracts | LAYER router `0x2eDBdF011768d8cd4Ef537658b41440900C52000` (floor 5.0e24, owner 0xCB43, threshold 0.01 weth, holds 0.000186 weth). open stack router `0xE60046ee745B235109C10d322A1cbDB3c029De43` (floor 1.0353e25, owner 0xCB43, holds 0). both bound to the LAYER pool, source `src/protocol-fee/legacy/BurnRouter.sol`. `processBurnWethOpenTab` does not exist on either |
| call | `setMinLayerOutPerWeth(uint256 newFloor)` selector 0xe12eb8ba, owner only, emits `MinLayerOutPerWethUpdated` |
| compute | spot from the pool (id 0x85c15a70d86374f345b25c9e97a1f06b2a39765ac48269445ce0514037f31e50, LAYER is currency0, lp fee 1%, hook 0xA5eA): `SLOT=$(cast keccak $(cast abi-encode "f(bytes32,uint256)" $PID 6))`, `V=$(cast call $PM "extsload(bytes32)(bytes32)" $SLOT --rpc-url $MAINNET_RPC_URL)`, `SQRT=$(python3 -c "import sys;print(int(sys.argv[1],16)&((1<<160)-1))" $V)`, `SPOT=$(python3 -c "import sys;s=int(sys.argv[1]);print(10**18*2**192//(s*s))" $SQRT)`, `FLOOR=$(python3 -c "import sys;print(int(sys.argv[1])*95//100)" $SPOT)`. at block 26130514 spot = 1.6213e25 LAYER per weth, 95% = 1.5402e25 |
| recommended | 95% of spot (1% pool fee plus about 4% for impact on a sub weth balance). raise the margin to 90% if the router balance is above 1 weth or the pool is thin. refresh at least daily and before any manual burn, because a stale low floor is the exposure and a stale high floor only blocks. keep router balances small |
| send | `cast send $R_LAYER "setMinLayerOutPerWeth(uint256)" $FLOOR --rpc-url $MAINNET_RPC_URL --private-key $OWNER_KEY` and the same on `$R_OPEN` |
| verify | `cast call $R_LAYER "minLayerOutPerWeth()(uint256)" --rpc-url $MAINNET_RPC_URL`. enforced minimum is `requiredMinLayerOutForWethAmount(1e18)`. LF-12: on 0xE600 the view reads about 0.5% under the stored floor, so keepers should pass `minLayerOut` from the setter value, not the view |
| risk | the setter is the whole control. a floor set in a public mempool right before a burn is front runnable only in the harmless direction. not a fix: LF-03 (clamp loops) is in the src router, v2 replaces both. burning is permissionless (`processBurnWeth(uint256 minLayerOut)`, ready at 0.01 weth), so also call `status()` before changing floors |
| other routers | `0x0EB22955E8904b8C5a4EC6f1D476f5b0C93854ca` (behind permanent collection controller 0xd8C6…, owner 0xCB43) has no floor setter, nothing to set, flagged LF-03 and LF-04. `0x9304a81965Ef3F7A092bd9eFd8c2fFc411E5F34d` (superseded) has floor 0 so it is paused, holds 0 |

### 6. freeze LAYER assets (R4, renderer and extension mutability)

what is mutable today, all owned by the owner eoa (token admin, renderer owner, scripty content owner, hook token admin gate):

| asset | state read | freeze call | what it means |
|---|---|---|---|
| scripty content, sketch js | `ll/sketch.b64.1778120217836`, 22,996 bytes, frozen false, owner 0xCB43 | `cast send $SCRIPTY "freezeContent(string)" "ll/sketch.b64.1778120217836" --rpc-url $MAINNET_RPC_URL --private-key $OWNER_KEY` (selector 0x7a2c5701, on `ScriptyStorageV2` 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699, third party contract, source not in repo) | the bytes under that name can never change again. one way. without it the owner can append chunks and rewrite the animation script |
| scripty content, history | `ll/history.b64.1778120217836`, 3,632 bytes, frozen false | same call with that name | seeded trade history fixed |
| scripty content, mona image | `ll/mona.1778120217836`, 78,065 bytes, frozen false | same call with that name | backdrop image fixed |

verify each freeze: `cast call $SCRIPTY "contents(string)(bool,address,uint256,bytes)" "<name>" --rpc-url $MAINNET_RPC_URL` first value true. freezing storage alone does not freeze the animation: the renderer still lets the owner point at other content names. all of these are one way, so do them last and only after the v2 plan is final:

| lever | call | effect | recommendation |
|---|---|---|---|
| renderer `0x0572C1754378c2f9Aef51b57b2830D343ee9d186` owner | `transferOwnership(address)` selector 0xf2fde38b to `0x000000000000000000000000000000000000dEaD` (no zero check, no freeze function exists) | locks `setSketchScriptName`, `setHistoryAsset`, `setMonaAsset`, `setImageOverrideUri`, name, symbol, supply, description strings. `counter` (0x38d0), builder and storage are immutable already | do after the three scripty freezes. also pins the ipfs `imageOverrideUri` pointer |
| LAYER token admin (owner) | `renounceAdmin()` selector 0x8bad0c0a on `$LAYER` | no more `updateImage`, `updateMetadata`, `setMetadataRenderer`, `updateAdmin`. renderer swap becomes impossible | last. renderer gas is 32M and grows with trades (G2), a future renderer migration needs this power |
| hook pool extension | `lockPoolExtension((address,address,uint24,int24,address))` on `$LHOOK`, arg `(0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9,0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,8388608,200,0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc)`, caller token admin (owner). now unlocked, extension 0x38d03af54ba9F80c3476B3D3B3a6415A399303f7 | the counter extension can never be swapped or cleared | do not lock while LL1, LL2 or the autoforward thresholds may need a migration. the sniper recipient is already locked |
| autoforward extension | owner 0xCB43, `setThresholds(uint256,uint256,uint256,uint256)`, `seedCounters`, `seedHistory`. thresholds now 0.01 weth and 100,000 LAYER | tuning only, nothing to freeze | `transferOwnership` to dead only if thresholds are final |
| LAYER slot admins (LF-05) | `updateRewardAdmin(address,uint256,address)` on `$LLOCKER`, slots 0 and 1 are owner admin | would freeze recipients | do not freeze slot 1: the burn router recipient 0x2eDB must be repointable when v2 replaces it |
| legacy hook `protocolFeeNumerator` | stays 0, `setProtocolFeeNumerator(uint256)` selector 0x45b11434 by the 0xd159 owner, max 500000 (50% of lp fee, taken to the factory) | the one live fee lever on LAYER | leave at 0 (D21). if the owner key is a concern, no on chain lock exists |

### 7. keep current factory 0x4959 deprecated, retire hook 0x636c later (DESIGN 2.1)

| field | value |
|---|---|
| finding | superseded stack, only owner can launch (deprecated true, deployFee 0.069 eth, owner 0xCB43) |
| now | nothing to send. confirm: `cast call $F_CUR "deprecated()(bool)" --rpc-url $MAINNET_RPC_URL` returns true. never call `setDeprecated(false)` on it |
| later, when v2 is live and the credits coin launched | `cast send $F_CUR "setHook(address,bool)" 0x636c050296B5Cc528D8785169Bf8923716FCa9cc false --rpc-url $MAINNET_RPC_URL --private-key $OWNER_KEY` (`setHook(address,bool)` selector 0x833e8db1, onlyOwnerOrAdmin, checked in the 0x4959 bytecode) |
| verify | `cast call $F_CUR "enabledHooks(address)(bool)" 0x636c050296B5Cc528D8785169Bf8923716FCa9cc --rpc-url $MAINNET_RPC_URL` returns false |
| risk | affects future launches on 0x4959 only. coin 111, its hook, locker and pool are untouched. reversible by `setHook(..., true)`. the hook has no owner and no off switch, `setHook` is the only lever |

### 8. claim the owner's unclaimed LAYER fees (legacy fee locker)

| field | value |
|---|---|
| finding | the owner is slot 0 recipient (3800 bps) of the LAYER locker, credited at the fee locker, never claimed: 3,315,375.59 LAYER and 0.4796 weth (read: `availableFees`) |
| contract | fee locker `0x1143db0913Ca5eCe8A42FC01b625fD81F9386b05`, owner 0xCB43, allowed depositor: the LAYER locker |
| call | `claim(address feeOwner, address token)` selector 0x21c0b342. permissionless but pays only `feeOwner`, so anyone can trigger it and it can only pay the owner. reverts `NoFeesToClaim` at zero |
| send | `cast send $LFEELOCKER "claim(address,address)" $OWNER $LAYER --rpc-url $MAINNET_RPC_URL --private-key $OWNER_KEY` and again with `$WETH` |
| verify | `cast call $LFEELOCKER "availableFees(address,address)(uint256)" $OWNER $LAYER --rpc-url $MAINNET_RPC_URL` returns 0, `cast call $LAYER "balanceOf(address)(uint256)" $OWNER --rpc-url $MAINNET_RPC_URL` rose |
| risk | none in the claim. selling 3.3M LAYER (about 0.2 eth at spot) moves a thin pool and the burn router floors. no deadline. same pattern for the protocol slot: 4,849 LAYER and 0.000489 weth at `0x5fDc…0A60` (below autoforward thresholds forever): `claim(0x5fDc39756A64A84518ef00CB6a0ED46971e00A60, token)` on the fee locker then `processFees(address)` on the controller, both permissionless |

### 9. 111 swapper stranding (LF-02, K-01): what the owner can and cannot do

| item | answer |
|---|---|
| mechanism | `escrow.claim(swapper, 0x0)` is permissionless and pushes the swapper's eth credit into its `receive()`. `flushPaired` sizes from the escrow ledger, so it then reverts `NothingToFlush`. the swapper has no owner, no sweep, `convert` forwards only swap output |
| recover stranded eth | nothing on chain can. swapper `0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961` has no owner, the 111 slot admin is 0xdEaD, the escrow owner cannot touch credited balances. current stranded balance: 0 (`cast balance $SWAPPER`) |
| prevent | keeper only (action 3): collect then flush in one tx. cannot stop a same tx griefer. reduces exposure only |
| owner levers that do not help | locker `setKeeperRewardBps`, escrow `addDepositor`, factory setters. none touch the swapper |
| residual | accept. v2 `FeeAutoSwapperV2` pays from balance and opts into `selfClaimOnly` |

### 10. other owner actionable items and things to leave alone

| item | contract and call | recommendation |
|---|---|---|
| locker keeper reward | `$L111` `setKeeperRewardBps(uint256)` selector 0x4a1e2ec0 (max 200 bps), `setKeeperRewardCap(uint256)` 0x2678c7dc (0.001 to 0.05 eth). live bps 0, cap 0.01 eth | keep 0. it taxes the swapper's own recipient and the keeper (action 3) is the plan. a nonzero bps would pay any caller of `collectRewards` from 111 fees |
| escrow depositors | `$ESCROW` `addDepositor(address)` selector 0xfc8acba2, no remove, no pause. depositors now: locker 0x866e, hook 0x636c | do not add any. a bad depositor can credit junk and cannot be removed. the same function exists on the open escrow 0xDD1b8C9C99Be3C717B9A5eb3C84297C5bfca1C06 and fee locker 0x1143 |
| locker `withdrawETH(address)` 0x690d8320, `withdrawERC20(address,address)` 0x9456fbcc | `$L111`, `$LLOCKER` | stray balances only (3,312 wei of coin at 0x866e). `withdrawETH` uses `transfer` (LF-11), pass an eoa. position nfts cannot be withdrawn |
| LAYER `protocolFeeNumerator` | hook `$LHOOK`, read 0, `protocolFeeNumerator()` | stays 0 |
| factory 0xd159 (LAYER) | deprecated true, owner 0xCB43 | keep deprecated |
| coin 111 tax rate and exemption (FT-01, H14) | token admin is `0xA96a11257890ED1C43C16c098E286e18e45E6258` (permanent collection poker), not the owner. `setTaxBps(uint16)` exists on the token. the hook `0x636c` has no owner | not owner actionable here. any change is a permanent collection call. v2 fixes the exemption mint |
| 111 `contractURI` gas (G1, 177M gas) | renderer 0x7604… and 0x9438…, outside this repo | permanent collection side |
| burn router and controller owners | `$R_LAYER`, `$R_OPEN`, controllers 0x5fDc… and 0xd8C6… all owned by 0xCB43, two step transfer absent (plain Ownable) | do not transfer ownership without a read back of `owner()` on a fork first |

## part 2: v2 rollout order

source of truth for the stack is `script/v2/DeployV2Stack.s.sol` (being written) and DESIGN d7. this is the order the script must follow and the owner must check, not a replacement for it.

### 2a. deploy, one broadcast, owner key as deployer and owner

| step | what | wiring and checks |
|---|---|---|
| 0 | fork rehearsal, no key | `forge script script/v2/DeployV2Stack.s.sol --rpc-url $MAINNET_RPC_URL` (no `--broadcast`), then `FOUNDRY_PROFILE=ci forge test --match-path "test/v2/DeployV2Stack.fork.t.sol" --fork-url $MAINNET_RPC_URL -vv` (`test_deployV2Stack_wiringComplete`, `test_deployV2Stack_runtimeMatchesBuild`). pin a block, record it |
| 1 | `ArtCoinsFeeEscrowV2` | owner is the deployer, Ownable2Step. depositors are added in step 7 |
| 2 | extension allowlist | new instance. do not reuse 0xd6D5…, it is bound to the live hook 0x636c |
| 3 | hook, salt mined with `HookMiner` against the CREATE2 deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C | low 14 bits 0x2DCC. constructor args per the script, pool manager is `$PM`. check `address(hook) & 0x3FFF == 0x2DCC` and runtime size under 24,576 at the ci profile |
| 4 | locker V2 | constructor args per the script. keeper reward bps stays 0 |
| 5 | `ArtCoinsMevLinearSkimV2` | one module |
| 6 | `ArtCoinsFactoryV2` | ctor `(owner, poolManager, protocolBps, deployFee)`, starts `deprecated = true`. it creates its token deployer |
| 7 | wire, all owner txs | escrow: `addDepositor(hook, true)`, `addDepositor(locker, true)`, controller as non core. hook: `setLauncher(factory, true)`, `setFeeEscrow`, `setExtensionAllowlist`. locker: `setLauncher(factory, true)`, `setFeeEscrow`. factory: `setHook`, `setLocker`, `setMevModule`, `setEscrow`, `setMinProtocolSkimShareBps`, `setProtocolRecipient`, `setReferralPayout`, `setTeamFeeRecipient`, `setDeployFee`. leave `deprecated` true |
| 8 | `ProtocolFeeControllerV2` and `BurnRouterV2` | controller ctor `(owner, escrow, treasury, burnRouter, treasuryBps)`, treasury per the owner decision (permanent collection uses 0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4). the router can only `initialize(coin, key)` once the coin pool exists, so initialize it right after the first launch, then rehearse `processFees` on a fork |
| 9 | keepers | `ArtCoinsKeeperV2(factory)`, stateless. `CollectFlushKeeperV1` stays for 111 |
| 10 | verify on etherscan | `script/v2/verify-v2.sh` (`forge verify-contract`, profile `tune`) for every address, with the library links. then a fork check that on chain runtime equals the local build. etherscan has no key in ci, use blockscout as the fallback |
| 11 | registry | add every address to `deployments/mainnet.json` with `stack`, `status: active`, mark the old stacks `superseded` or `deprecated`, deploy block and tx. `node script-js/verify-registry.mjs --fill --update-blocks` then `node script-js/verify-registry.mjs --require-artifacts` must exit 0. commit the broadcast record this time (H4) |

### 2b. launch the first coin (credits engine coin) while the factory is owner only

| step | what | check |
|---|---|---|
| 1 | build the `DeploymentConfigV2` for the treasury recipient (credits engine): native eth pool, tax mode and sink per DESIGN section 6 and 7, extensions none or allowlisted, lp split | `factory.predictToken(owner, config)` equals the address in the config file, `factory.configHash(config)` recorded |
| 2 | simulate on a fork, then send `deployTokenAsOwner(config, protocolBps)` (onlyOwner, the one path that sets the protocol slot bps) with `--value` at least `deployFee()` plus extension msgValues, excess is refunded | `factory.isArtCoin(token)`, `hook.poolInfo(poolId).version == 2`, `token.launcherVersion() == 2`, the launch event echoes the config |
| 3 | `BurnRouterV2.initialize(token, key)` if the coin uses the burn leg | `router.coin() == token` |
| 4 | trade a small buy and sell, collect, deliver to the treasury, run `ArtCoinsKeeperV2.collectAndForward(token, true, minOut)` | fees land at the treasury by push, escrow stays empty, treasury `receive` works under `pushGas` (50k default) |
| 5 | add the coin to the keeper cron and the registry `coins` list | `verify-registry` passes |

### 2c. open to the public, `setDeprecated(false)` last

before the call: the checklist below is all true, the first coin ran at least one full fee cycle, and `cast call $F_V2 "deprecated()(bool)"` returns true. then `cast send $F_V2 "setDeprecated(bool)" false --rpc-url $MAINNET_RPC_URL --private-key $OWNER_KEY`. to close again: `setDeprecated(true)`. no other owner tx is needed at opening.

### must be true before public

| # | gate | how to check |
|---|---|---|
| 1 | ci green, including fork tests that actually ran | `FOUNDRY_PROFILE=ci forge test --fork-url $MAINNET_RPC_URL`, no vacuous passes (H5), pinned `FORK_BLOCK` job green |
| 2 | registry verify passes against the chain and the build | `node script-js/verify-registry.mjs --require-artifacts` exit 0, weekly workflow green |
| 3 | size gate | `FOUNDRY_PROFILE=ci forge build --sizes`, hook and locker at least 1,024 bytes under 24,576 (DECISIONS D14) |
| 4 | external review of the hook | written report, every high fixed or accepted in writing, regression tests named in DESIGN section 3 pass |
| 5 | ui points at the v2 factory and gates on `deprecated` | ui reads `factory.deprecated()` and `deployFee()`, shows the fee, blocks on unknown chain, encodes the v2 config, simulates before send (UI-01 to UI-09) |
| 6 | keeper cron running | `ArtCoinsKeeperV2` deployed, hourly job live, key under 0.05 eth, alert on `swapperEth`, `lastConvertBlock` age and escrow slots |
| 7 | old factories deprecated | `deprecated()` true on `$F_OPEN`, `$F_CUR`, `$F_LEGACY`. `setHook(0x636c…, false)` on `$F_CUR` after the first v2 coin trades |
| 8 | actions 1, 2 and 5 done, router floors fresh | collect timestamps, `minLayerOutPerWeth()` within 5% of 95% of spot |
| 9 | public repo hygiene | mirror tag filter fixed (H1), curated merge of docs/v2 and review tests (H2), origin confirmed (H3) |
| 10 | owner key custody | hardware or keystore, ownership of v2 contracts is Ownable2Step so `acceptOwnership` is exercised on a fork once |
