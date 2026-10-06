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
| 2b | deploy and schedule the LAYER collect, claim and burn keeper | weth burns have no other caller | one deploy, cron |
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
| keep collecting | action 3 keeper, hourly check, collect when `preview()` shows more than 0.02 eth or 10,000 coin uncollected, or weekly regardless. it shrinks exposure and cannot close the hole |
| v2 class note | the LF-01 class does not exist on v2 coins. `ArtCoinsLpLockerV2` has only `collectRewards(address)` (0x5763dbd0): it opens the position manager's own unlock, takes exact balance deltas, pays the frozen split, and reverts `PoolManagerUnlocked()` (0x0e1475a4) if the pool manager is already unlocked. there is no `collectRewardsWithoutUnlock(address)` (0x86b0c83f, v1 only), no open tab collect and no hook collect path. an extension that needs to collect inside a swap would need a new locker, not a setting. so the hourly collect rule above is a v1 111 rule, v2 keepers run on the part 2 cadence |

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

### 2b. deploy and run the LAYER keeper (collect, claim, split, burn)

| field | value |
|---|---|
| finding | nothing calls `processBurnWeth` on the LAYER routers: the autoforward extension 0x38d0 deliberately skips it (no nested unlock), and its claim and split stages only fire above 0.01 weth or 100,000 LAYER, so small slots sit forever (scripts-and-keepers gap list). LF-01 exposure on LAYER is one swap's fee, because the hook collects on every swap |
| contract | `src/v2/keepers/CollectFlushKeeperLayer.sol`, ctor `(locker, LAYER, weth, feeLocker, controller, [router0, router1, router2])` = `$LLOCKER $LAYER $WETH $LFEELOCKER 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60 [$R_LAYER, $R_OPEN, 0x0EB22955E8904b8C5a4EC6f1D476f5b0C93854ca]`, taken from `script/Addresses.sol` by the script. no owner, holds nothing, any wallet deploys and runs it. use the keeper hot key, not the owner key |
| path | collect to the fee locker (38% owner, 42% router 0x2eDB, 20% controller 0x5fDc), `claim` (0x21c0b342) the controller and router slots (never the owner slot), `processFees(address)` (0x61582eaa: 60% treasury 0x41c3, 40% router), `processBurnLayer()` (0x811be55f), `processBurnWeth(uint256)` (0x2cb58c11) on every router at or above 0.01 weth. no LF-02 stranding shape: router and controller book by balance (`test_layerKeeper_thirdPartyClaim_doesNotStrand`) |
| deploy dry run | `ALLOW_SUPERSEDED=1 forge script script/v2/RunKeeperLayer.s.sol:DeployKeeperLayer --rpc-url $MAINNET_RPC_URL` (the scripts refuse mainnet without `ALLOW_SUPERSEDED=1`, the legacy stack is superseded in the registry) |
| deploy | `ALLOW_SUPERSEDED=1 forge script script/v2/RunKeeperLayer.s.sol:DeployKeeperLayer --rpc-url $MAINNET_RPC_URL --broadcast --account <keystore>` then `export KEEPER_LAYER=<printed address>`. record it in `deployments/mainnet.json` |
| check | `cast call $KEEPER_LAYER "preview()(uint256,uint256,uint256[4],uint256[3],uint256[3])" --rpc-url $MAINNET_RPC_URL` (0xefae2305): uncollected LAYER, uncollected weth, claimable [controller LAYER, controller weth, router LAYER, router weth], weth plus eth at [0x2eDB, 0xE600, 0x0EB2], their thresholds |
| run dry | `ALLOW_SUPERSEDED=1 forge script script/v2/RunKeeperLayer.s.sol:RunKeeperLayer --rpc-url $MAINNET_RPC_URL` (prints preview, simulates with rate 0, quotes the realized LAYER per weth minus `KEEPER_SLIPPAGE_BPS`, default 200) |
| run | `ALLOW_SUPERSEDED=1 forge script script/v2/RunKeeperLayer.s.sol:RunKeeperLayer --rpc-url $MAINNET_RPC_URL --broadcast --account <keystore> --gas-limit 3500000`. by hand: `cast send $KEEPER_LAYER "run(bool,uint256,bool)" true $RATE true --gas-limit 3500000 --rpc-url $MAINNET_RPC_URL --account <keystore>` (selector 0xc2e8c918, `$RATE` LAYER per 1e18 weth, 0 means each router's own floor; simulate first with `cast call --from <keeper key address>` and the same arguments) |
| gas floors (D49) | floors, not caps: collect 640k, claim 60k, processFees 80k, processBurnLayer 60k, processBurnWeth 900k (each burn is a swap and pays the hook's collect), each plus 50k margin, the 1/63 reserve and 20k. a shortfall reverts `InsufficientGas(step)` (0x969aeb08, 1 collect to 5 weth burn), a collect revert bubbles, other reverts are logged as `StepSkipped(uint8,address,bytes)` (topic 0x0ec30982ffee6bdc8b4f21abd0cf9b3d5a7f4f836a0c96799c3efc0118d66235) and the run completes. measured: full path with one burn 853k, two reward router burns 1.84M, smallest completing limit with one burn 1.5M. set 3,500,000 |
| floors and rate | routers with an owner floor (0x2eDB 5e24, 0xE600 1.0353e25) get `max(rate, floor) * balance / 1e18`. floor 0 means paused, the router reverts `SlippageFloorNotSet` (0xc2358797), reported. 0x0EB2 has no floor setter and gets 0 (its 1% impact clamp and 80% spot floor on the consumed amount apply) |
| cadence | daily cron: run when any `routerWeth[i] >= routerThreshold[i]` or `routerWeth[0] + claimable[3] + 0.4 * (claimable[1] + controller weth) >= 0.01 weth`; weekly regardless. an idle run is about 0.65M gas for nothing, skip it. refresh the router floors first (action 5) |
| verify | `cast call $R_LAYER "status()(uint256,uint256,bool)" --rpc-url $MAINNET_RPC_URL` shows weth under 0.01 after a burn. `cast call $LFEELOCKER "availableFees(address,address)(uint256)" 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60 $WETH --rpc-url $MAINNET_RPC_URL` is 0. `cast balance $KEEPER_LAYER --rpc-url $MAINNET_RPC_URL` is 0 |
| risk | rewards: 0x2eDB pays none, 0xE600 and 0x0EB2 pay 0.5% (cap 0.01 eth) to the caller, so the run is owner funded at current volume. a stale low owner floor is still callable by anyone directly (LF-09). key under 0.05 eth. proof tests: `test/v2/KeeperLayer.fork.t.sol` (11), detail in `docs/v2/review/keeper-111.md` (LAYER keeper) |

### 3. deploy and run the 111 collect and flush keeper

| field | value |
|---|---|
| finding | LF-01 (reduces pending), LF-02 / K-01 (collect, flush and convert in one tx), K-04 (no third party earns enough to run it) |
| contract | `src/v2/keepers/CollectFlushKeeperV1.sol`, ctor `(locker, token, swapper, escrow)` pinned to `$L111 $C111 $SWAPPER $ESCROW`. no owner, holds nothing, any wallet can deploy and run it. use a dedicated hot key, not the owner key |
| deploy dry run | `forge script script/v2/RunKeeper111.s.sol:DeployKeeper111 --rpc-url $MAINNET_RPC_URL` |
| deploy | `forge script script/v2/RunKeeper111.s.sol:DeployKeeper111 --rpc-url $MAINNET_RPC_URL --broadcast --account <keystore>` then `export KEEPER_111=<printed address>`. record it in `deployments/mainnet.json` |
| check | `cast call $KEEPER_111 "preview()(uint256,uint256,uint256,uint256,uint256)" --rpc-url $MAINNET_RPC_URL` returns uncollectedEth, uncollectedCoin, escrowedEth, swapperEth, swapperCoin. `swapperEth > 0` means a third party already stranded eth |
| run dry | `forge script script/v2/RunKeeper111.s.sol:RunKeeper111 --rpc-url $MAINNET_RPC_URL` (prints preview and a quoted minOut, `KEEPER_SLIPPAGE_BPS` default 100) |
| run | `forge script script/v2/RunKeeper111.s.sol:RunKeeper111 --rpc-url $MAINNET_RPC_URL --broadcast --account <keystore> --gas-limit 1200000` (`run(bool,uint256)` selector 0x02143aa9, measured 799k gas) |
| gas floors (D49) | the gas limit is part of the call, set it by hand and never take a limit from an `estimateGas` search. the floors are not caps: each step runs with all remaining gas but only starts if `gasleft()` clears floor plus 50k margin plus the 1/63 reserve plus 20k. collect floor 658k (needs 739k left to start), flush 72k (needs 144k left), convert 299k (needs 375k left). the smallest limit that completes is about 1.1M, use 1.2M. below that the run reverts `InsufficientGas(step)` (selector 0x969aeb08, step 1 collect, 2 flush, 3 convert), it never skips a step silently: the sweep from 1.3M to 0.3M gave 8 completed, 33 reverted, 0 skipped. a collect revert bubbles, a flush or convert revert is reported as `FlushSkipped` or `ConvertSkipped` and the run completes |
| cadence | cron hourly: read `preview()`, run when uncollectedEth > 0.02 eth, uncollectedCoin > 10,000e18, escrowedEth > 0.05 eth (flush overdue), or the weekly timer is due. skip if pending is worth less than the gas, unless the timer is due. convert has its own 50 block pacing, extra attempts are swallowed no ops. monitor `lastConvertBlock` age and `swapperEth` |
| verify | `cast call $SWAPPER "lastConvertBlock()(uint256)" --rpc-url $MAINNET_RPC_URL` moves after a convert. `cast balance $KEEPER_111` is 0 after every run |
| risk | cannot stop a griefer who calls `collectRewards` then `escrow.claim(swapper,0)` himself in one tx, cannot recover eth already stranded. send runs through a private relay. the key only pays gas, keep under 0.05 eth. proof tests: `test/v2/KeeperV1_111.fork.t.sol` (8), detail in `docs/v2/review/keeper-111.md` |

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

sources of truth, in this order: `script/v2/DeployV2Lib.sol` (the routine), `script/v2/DeployV2Stack.s.sol`, `script/v2/README.md`, `docs/v2/DECISIONS.md` D28 to D57, `docs/v2/CREDITS-ENGINE-INTERFACE.md`. the same routine runs in the script and in the fork harness (`ForkStack.deployV2Stack`), so the tests exercise the exact broadcast. if this file and the lib differ, the lib wins and this file is wrong. always `FOUNDRY_PROFILE=ci` (D45): at the default profile `ArtCoinsDeployerV2` is 24,806 bytes, over EIP-170, and the post deploy asserts refuse it.

### 2a. deploy, one broadcast

| env (all optional) | default | note |
|---|---|---|
| OWNER | `Addresses.OWNER` (0xCB43…) | owner of every owned contract and team fee recipient |
| TREASURY, TREASURY_BPS | OWNER, 9000 | controller treasury and its share (Constants allow 4000 to 9000, the rest burns) |
| REFERRAL_PAYOUT | 0 = the new escrow | D57. must have code. the live 0xB03C… answers `Unauthorized()` to everyone but the v1 hook and the owner eoa has no code, so neither is used |
| DEPLOY_FEE, PROTOCOL_BPS | 0.069 eth, 2000 | factory deploy fee and default protocol slot |
| MIN_PROTOCOL_SKIM_SHARE_BPS, MIN_LP_FEE | 1000, 3000 | D52 and D53 |

about 29.5m gas over 30 txs (0.011 eth at 0.38 gwei, measured on a fork at block 26131304). the hook address depends on the broadcaster, so a dry run with `--sender $OWNER` shows the real one.

| step | rehearsal, no key | command |
|---|---|---|
| 0a | dry run on a fork | `FOUNDRY_PROFILE=ci forge script script/v2/DeployV2Stack.s.sol --rpc-url $MAINNET_RPC_URL --sender $OWNER` (no `--broadcast`) |
| 0b | harness rehearsal, broadcaster differs from OWNER, then accept | `FOUNDRY_PROFILE=ci forge test --match-path "test/v2/DeployV2Stack.fork.t.sol" --fork-url $MAINNET_RPC_URL -vv`. record the block |
| 0c | broadcast | `FOUNDRY_PROFILE=ci forge script script/v2/DeployV2Stack.s.sol --rpc-url $MAINNET_RPC_URL --ledger --sender $OWNER --broadcast --slow` (or `--account <keystore>`) |

contracts, in the order `DeployV2Lib.deploy` creates them (D38, D36):

| # | contract | constructor args as deployed | note |
|---|---|---|---|
| 1 | `ArtCoinsFeeEscrowV2` | `(broadcaster)` | owner is the broadcaster until step 12 |
| 2 | `ArtCoinsPoolExtensionAllowlist` (v1 source, new instance) | `(OWNER)` | do not reuse 0xd6D5, it serves the v1 hook |
| 3 | `ArtCoinsHookV2`, CREATE2 via 0x4e59b44847b379578588920cA78FbF26c0B4956C | `(PoolManager $PM, broadcaster, escrow, allowlist)` | salt mined in the script for low 14 bits 0x2DCC, max 400,000 tries, in the output json |
| 4 | `ArtCoinsLpLockerV2` | `(broadcaster, PositionManager 0xbD21…ee9e, Permit2 0x0000…8BA3, escrow)` | |
| 5 | `ArtCoinsMevLinearSkimV2` | `(hook)` | ownerless |
| 6 | `ArtCoinsFactoryV2` | `(broadcaster, $PM, protocolBps 2000, deployFee 0.069 eth)` | ships `deprecated = true` |
| 7 | `ArtCoinsDeployerV2` | `(factory)` | then `factory.setTokenDeployer(deployer)` (0x880183e9, owner only). D55: the deployer is an owner trust surface, the registry records its runtime code |
| 8 | `BurnRouterV2` | `(OWNER, $PM, escrow)` | `initialize(coin, key)` after the first launch |
| 9 | `ProtocolFeeControllerV2` | `(OWNER, escrow, treasury, burnRouter, treasuryBps 9000)` | after the router, its constructor needs it |
| 10 | `ArtCoinsKeeperV2` | `(factory)` | stateless, ownerless. record it as `KEEPER_V2` |

wiring, in the order `_wire` sends it (D36: the escrow knows the hook and locker before either `setFeeEscrow`):

| # | contract | call | why |
|---|---|---|---|
| 1 to 3 | escrow | `addDepositor(hook, true)`, `addDepositor(locker, true)`, `addDepositor(controller, false)` (`addDepositor(address,bool)` 0x26a760ad, the v1 escrow's one arg 0xfc8acba2 does not exist here) | core depositors cannot be removed (D23). the controller needs it for its push fallback (D33) |
| 4 to 6 | hook | `setFeeEscrow(escrow)`, `setExtensionAllowlist(allowlist)`, `setLauncher(factory, true)` | |
| 7 to 9 | locker | `setFeeEscrow(escrow)`, `setLauncher(factory, true)`, `setKeeperRewardBps(0)` (0x4a1e2ec0) | D28: the keeper reward starts at 0, max 2% later |
| 10 to 13 | factory | `setHook(hook, true)`, `setLocker(locker, true)`, `setMevModule(mev, true)`, `setEscrow(escrow, true)` | enable the stack |
| 14 to 16 | factory | `setProtocolRecipient(controller)`, `setReferralPayout(escrow or REFERRAL_PAYOUT)`, `setTeamFeeRecipient(OWNER)` | D57. referral legs are credited to the referrer in the escrow (D16), claimed with `escrow.claim(referrer, 0x0)` (0x21c0b342) |
| 17, 18 | factory | `setDeployFee(0.069 eth)`, `setDefaultProtocolFeeBps(2000)` | |
| 19 | factory | `setMinProtocolSkimShareBps(1000)` (0x76ed5aeb) | D52: the protocol keeps at least 10% of every skim. caps `bountyBps` at 9000 and the referral cap |
| 20 | factory | `setMinLpFee(3000)` (0x8fadcf37) | D53: launch lp fee floor, 0.3% |
| none | factory | `deprecated` stays true | opening is the last owner tx, 2c |

| step | what | detail |
|---|---|---|
| 11 | wiring | the table above, 20 calls after step 10. not wired at deploy: per coin tax exempt entries, a coin's fee swapper as depositor, the burn router `initialize`. those are per coin owner calls in 2b (D33, D47) |
| 12 | ownership, Ownable2Step (D20) | broadcaster == OWNER: nothing to do. otherwise escrow, hook, locker and factory end with `pendingOwner() == OWNER` (0xe30c3978) and the broadcaster still owns them. the allowlist, router and controller are constructed with OWNER, nothing to accept |
| 13 | post deploy asserts, in the script | `constantsHash()` of escrow, hook, locker, mev, factory, deployer, router, controller. hook low bits 0x2DCC, permissions equal the address flags, hook PoolManager, globals escrow and allowlist, factory is a launcher. escrow depositors and core flags. locker escrow, launcher, reward bps 0. every factory getter above, deployer binding, `deprecated`, `STACK_VERSION`. mev hook, keeper factory, controller and router links, router `coin() == 0`. owners or pending owners. runtime size of all 10 under 24,576. prints `post deploy asserts: ok`, the registry json, writes `tmp/v2-deploy-1.json` |

step 12 for a broadcaster that is not OWNER, one tx at a time, before anything else (until all four are accepted the broadcaster holds the owner powers). `acceptOwnership()` is 0x79ba5097:

```
J=tmp/v2-deploy-1.json
for k in escrow hook locker factory; do
  a=$(jq -r ".addresses.$k" $J)
  cast call --from $OWNER $a "acceptOwnership()" --rpc-url $MAINNET_RPC_URL            # simulate
  cast send $a "acceptOwnership()" --rpc-url $MAINNET_RPC_URL --ledger                  # send
  cast call $a "owner()(address)" --rpc-url $MAINNET_RPC_URL                             # == OWNER
  cast call $a "pendingOwner()(address)" --rpc-url $MAINNET_RPC_URL                      # == 0x0
done
```

| step | what | command and check |
|---|---|---|
| 14 | verify | `script/v2/verify-v2.sh` (profile ci, run it after the accepts): `forge verify-contract` per contract with the json's constructor args (etherscan with `ETHERSCAN_API_KEY`, else blockscout), then the chain check through `script-js/verify-registry.mjs` on a one stack registry: runtime vs the local ci build with immutables masked, owners equal OWNER, escrow depositors, factory still deprecated. `--dry-run` prints the verify commands, `--skip-source` is chain only. the hook is verified as `src/v2/hooks/ArtCoinsHookV2.sol:ArtCoinsHookV2` (v1 has the same contract name). exit 0 |
| 15 | registry | start from `deployments/v2.template.json` (stack `v2`, status `planned`, null addresses). copy `.stack` and `.contracts` from `tmp/v2-deploy-1.json` into `deployments/mainnet.json`, set the stack status, mark the old stacks superseded per DESIGN d7, then `node script-js/verify-registry.mjs --fill --update-blocks` and `node script-js/verify-registry.mjs --require-artifacts`, exit 0. `gen-addresses.mjs` expects exactly one stack with status `current` and id `current`, so v2 constants need that decision first, then `cd script-js && npm run gen:addresses`. commit the broadcast record (H4) |

### 2b. launch the first coin (credits engine coin), factory still owner only

the first coin is `deployTokenAsOwner` (the one path that sets the protocol slot bps), which works while the factory is deprecated.

| step | what | detail and check |
|---|---|---|
| 1 | owner calls before launch | `factory.setExemptAllowed(treasury, true)` (0xa492f064, D47) only if the treasury must be in `tax.exempt` (VENUE mode only, needs code at launch). `escrow.addDepositor(feeSwapper, false)` (0x26a760ad, D33) if a per coin `FeeAutoSwapperV2` is a locker reward recipient: deploy the swapper first, its address goes into `rewardRecipients`. a plain treasury recipient needs neither. referral payout is the escrow (D57), no call |
| 2 | config | `cp script/v2/launch-configs/example.json my-coin.json`, set treasury, names, ticks, `"example": false`. limits: `bountyBps` at most 9000, `lpFee` at least 3000 pips, referral cap under the D52 floor, project `rewardBps` plus protocolBps equal 10000, native eth only, tax sink is DEAD or the bounty recipient. the json cannot carry launch extensions, a pool extension or tax venues |
| 3 | dry run | `forge script script/v2/LaunchV2Coin.s.sol --sig "run(string)" "$(cat my-coin.json)" --rpc-url $MAINNET_RPC_URL --sender $OWNER`. preflight on the wiring, `predictToken`, a snapshot dry run, then it stops before the tx. record the predicted token, `configHash`, value (the deploy fee) and pool id |
| 4 | broadcast | the same command plus `--ledger --broadcast` (or `--account <keystore>`). excess value above `deployFee()` plus extension msgValues is refunded |
| 5 | checks | `factory.isArtCoin(token)`, token equals the predicted address, `hook.poolInfo(poolId).version == 2`, `token.launcherVersion() == 2`, the `TokenCreatedV2` event echoes the config and its `configHash` equals the dry run |
| 6 | post launch owner calls | `escrow.isDepositor(feeSwapper)` (0x2f70d1ba) is true, add it if step 1 was skipped. the swapper's deployer calls `swapper.setup(coin)` (0x66d38203). `BurnRouterV2.initialize(token, key)` if the coin uses the burn leg, then `router.coin() == token` |
| 7 | run the keeper once | see the next table. then a small buy and sell and check the fee legs: the bounty is pushed with the 2,300 gas stipend (D41), anything that fails sits in the escrow under the recipient, claim it |
| 8 | registry and cron | add the coin to the registry `coins` list (`verify-registry` passes) and to the keeper cron |

keeper for a v2 coin: `ArtCoinsKeeperV2.collectAndForward(address token, bool doConvert, uint256 minOut)` selector 0x4f4b6733, permissionless, holds nothing, forwards what it receives to the caller. there is no forge script for it yet, use cast:

| item | value |
|---|---|
| dry run | `cast call --from $KEEPER_ADDR $KEEPER_V2 "collectAndForward(address,bool,uint256)" $TOKEN true 0 --gas-limit 2000000 --rpc-url $MAINNET_RPC_URL` |
| send | `cast send $KEEPER_V2 "collectAndForward(address,bool,uint256)" $TOKEN true $MINOUT --gas-limit 2000000 --rpc-url $MAINNET_RPC_URL --account <keystore>`. `$MINOUT` is the simulated convert output at `minOut` 0 minus 100 bps, never spot. `0` only for the first dry run |
| gas floors (D49) | collect 900k, flush 150k, convert 400k, erc165 probe 30k, each plus 50k margin and the 1/63 reserve. floors, not caps. below them the call reverts `InsufficientGas(step)` (0x969aeb08, 1 collect, 2 flush, 3 convert, 4 probe). set the limit by hand, 2,000,000 is safe. the figures are v1 measurements with room, re measure on the live v2 coin and tighten |
| failed step | collect bubbles its revert. flush and convert reverts are logged (`FlushSkipped`, `ConvertSkipped`) and the run completes. a reward recipient that is not a swapper (a plain treasury) is skipped, the locker pushes its share itself |
| cadence | the locker has no LF-01 hole, so there is no hourly rule. hourly cron reads `preview(token)` (0x13a69df9: swappers, accruedPaired, accruedArtCoin, nextConvertibleBlock) and runs when the accrued amounts are worth more than the gas, and at least weekly regardless (uncollected lp fees are not readable through the locker interface). convert is paced per swapper, extra attempts are logged no ops |
| monitor | key balance under 0.05 eth, `FlushSkipped` and `ConvertSkipped` reasons, escrow credit under the swapper and treasury, `nextConvertibleBlock` age |

### 2c. open to the public, `setDeprecated(false)` last

before the call: every gate below is true, the first coin ran at least one full fee cycle, and `cast call $F_V2 "deprecated()(bool)" --rpc-url $MAINNET_RPC_URL` returns true. then `cast send $F_V2 "setDeprecated(bool)" false --rpc-url $MAINNET_RPC_URL --private-key $OWNER_KEY` (0xd848dee7). to close again: `setDeprecated(true)`. no other owner tx is needed at opening.

### must be true before public

| # | gate | how to check |
|---|---|---|
| 1 | ci green on the release commit, fork tests that actually ran | jobs `Foundry project (no network)` (fmt, build sizes, hook size gate, tests), `Foundry fork tests (pinned mainnet block)`, `Registry schema`, `Registry vs chain and bytecode`. read the skip count: a fork job that skipped is not green (H5). the four known red v1 `BurnRouter` floor fork tests in `hygiene-fixes.md` are fixed or accepted in writing. `ui build and lint` is `continue-on-error` today, make it blocking and green (UI-03). `review-proofs` stays informational |
| 2 | `script/v2/verify-v2.sh` clean | exit 0 after the `acceptOwnership` calls, source verified on the explorer, runtime equals the ci build, wiring and owners match |
| 3 | registry verifies against chain and build | `node script-js/verify-registry.mjs --require-artifacts` exit 0, weekly workflow green, v2 stack present with deploy blocks |
| 4 | sizes under the ci profile | `FOUNDRY_PROFILE=ci forge build --sizes`: all 10 contracts under 24,576, hook and locker at least 1,024 bytes of headroom (D14, D45) |
| 5 | external review of the hook swap path | written report covering beforeSwap, afterSwap return delta, the skim refund (D42, D51), stipend fee pushes (D41), `FeeDelivery`, the factory and locker interplay. every high fixed or accepted in writing. internal reviews did not verify: V2H-01 end to end (no hostile recipient built), a nested swap from a recipient, partial fill refunds through a live universal router, the HARD `donate` path, sizes at ci, the locker with the real hook and a taxed coin end to end |
| 6 | external review of the HARD mode token | D24, D34 netting, D43, D46. not verified internally: D34 netting with several canonical flows in one tx, routers that settle a gross amount after an opposite flow netted the grant down, erc6909 claims on side pools (accepted residual, D24), V2B-05 burn router sandwich profit (estimate only) |
| 7 | fork rehearsal of the first coin | the 2b steps 3 to 7 against a fork of the deployed stack: launch, buy, sell, collect, keeper run, claim, with the real config. covers what reviews left open: gas at the ci profile, airdrop as a launch extension, dev buy partial fill refund, keeper gas on the real v2 stack, the mainnet gas limit and the 16.7m tx cap (D54: a config with every cap at its limit costs about 19.6m gas, accepted, the ui keeps configs far below) |
| 8 | ui points at the v2 factory | `VITE_V2_FACTORY`, `VITE_V2_HOOK`, `VITE_V2_LOCKER` set together (optional `VITE_V2_ESCROW`, `VITE_V2_MEV_MODULE`, `VITE_V2_DEPLOY_BLOCK`, extension vars) or the generator emits a v2 stack into `ui/src/lib/deployments.generated.ts`. it reads `deprecated()` and `deployFee()`, shows the fee, blocks on an unknown chain, simulates before send (UI-01 to UI-09). check the coin renders in a real marketplace (not verified) |
| 9 | keeper cron running | `CollectFlushKeeperV1` for 111 (part 1 action 3, 1.2M gas limit) and `ArtCoinsKeeperV2` for the first v2 coin (2b), hot key under 0.05 eth, alerts set |
| 9b | LAYER keeper cron running | `CollectFlushKeeperLayer` (part 1 action 2b, 3.5M gas limit, `ALLOW_SUPERSEDED=1` for the scripts), daily `preview()` check, weekly run regardless. alert when a router stays at or above 0.01 weth for more than a day, or a run logs `StepSkipped` step 5 |
| 10 | old factories deprecated | `deprecated()` true on `$F_OPEN`, `$F_CUR`, `$F_LEGACY`. `setHook(0x636c…, false)` on `$F_CUR` after the first v2 coin trades (part 1 action 7) |
| 11 | part 1 actions 1, 2, 4 and 5 done, router floors fresh | collect timestamps, `minLayerOutPerWeth()` within 5% of 95% of spot |
| 12 | stack defaults read back | `minProtocolSkimShareBps` 1000, `minLpFee` 3000, locker `keeperRewardBps` 0, referral payout is the escrow or a deliberate v2 aware payout, `deprecated` true until the last tx |
| 13 | public repo decision D26 reviewed | `origin` is the public ripe0x/artcoins (H3), branch `v2` and the review docs with findings on live contracts are already public (D26): keep or delete the remote branch on purpose. curated merge of `docs/v2` and `test/v2/review` (H2), mirror tag filter fixed (H1). part 1 of this file stays off the mirror until actions 1, 2, 4 and 5 are done |
| 14 | owner key custody | hardware or keystore. `acceptOwnership` was exercised on a fork (step 0b) before the real accepts |
