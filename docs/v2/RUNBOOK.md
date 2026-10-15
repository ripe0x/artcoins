# artcoins ops runbook

> disclosure: part 1 describes LF-01 (critical, live, immutable lockers) and other findings on deployed contracts. keep this file off the public mirror until the owner has run actions 1, 2 and 4 (collects and the open factory) and 5 (router floors). nothing here needs a code change. every address was read on chain at block 26130514 (2026-10-06) and every selector was checked against the deployed bytecode or the v1 source. the owner calls in actions 1, 2, 4, 5, 6 (scripty freeze, lockPoolExtension), 7 and 8 were simulated with `cast call --from $OWNER` and succeed today. nothing was broadcast.

## setup, used by every command

```
export ETH_RPC_URL=https://mainnet.gateway.tenderly.co
export MAINNET_RPC_URL=$ETH_RPC_URL
export OWNER=0xCB43078C32423F5348Cab5885911C3B5faE217F9
export F_CUR=0x49596c375c139E79bb937bcf826068a8F78D4e0e F_OPEN=0xF051cd4C4F3F36F9f24d8a19d60Ee8F84FC6793e F_LEGACY=0xD1595A2742C392d1c109b616b4F08918D02292f9
export L111=0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab C111=0x61C9d89fe1212F6b55fF888816A151463287B8ae SWAPPER=0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961 ESCROW=0x7559689765aE86cBB38e68CD1294830CccB125F2
export LAYER=0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9 LLOCKER=0x75BE7E95745915fD0C1761B74F3f9650ad2d1118 LFEELOCKER=0x1143db0913Ca5eCe8A42FC01b625fD81F9386b05 LHOOK=0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc
export R_LAYER=0x2eDBdF011768d8cd4Ef537658b41440900C52000 R_OPEN=0xE60046ee745B235109C10d322A1cbDB3c029De43 RENDERER=0x0572C1754378c2f9Aef51b57b2830D343ee9d186 SCRIPTY=0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699
export WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 PM=0x000000000004444c5dc75cB358380D2e3dE08A90
```

the owner `0xCB43…` signs with the foundry keystore `ripe0x` (`--account ripe0x`); keeper calls sign with the keystore `artcoins-keeper`. no key is ever passed as an argument or written to a file. the owner eoa carries an eip 7702 delegation (code `0xef0100…`), so nodes accept one in flight tx from it: `cast send` waits for each receipt, and every multi tx `forge script --broadcast` from it needs `--slow`.

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

done on chain (part 1 actions 1 to 5 and 8 complete; read at block 26137826):

| action | tx | block |
|---|---|---|
| 1 collect 111 | owner nonce 3766, `collectRewards(0x61C9…)` on 0x866e, https://evm.now/tx/0xd02578644e6e7af831da59a111618c5620f874c66945ee44e86b64aaca80c723?chainId=1 | 26135717 |
| 5 floor 0x2eDB | owner nonce 3767, `setMinLayerOutPerWeth(15402461028354640333126378)`, https://evm.now/tx/0xbb83afee249adb2ac03db77bc1a8c66d2b345752655dc18dce10d2f6728f02b2?chainId=1 | 26135720 |
| 5 floor 0xE600 | owner nonce 3768, same floor, https://evm.now/tx/0x084c43596046634ffa282e13a4f7af654ef0f809450b6e0202a27773ddab1b46?chainId=1 | 26135723 |
| 4 deprecate 0xf051 | nonce 3769, `setDeprecated(true)`, https://evm.now/tx/0x2aaa56ff62a6cbdea060c21883645bb928d6e42b98232a38db7ece7ded69ef87?chainId=1 | 26137418 |
| 2 collect LAYER | nonce 3770, `collectRewards(LAYER)` on 0x75BE, https://evm.now/tx/0xd4f1c19067128080626a638c8008bdc88f4e78c318bd6c3b2551edaea41a751d?chainId=1 | 26137423 |
| 8 claim owner LAYER | nonce 3771, `claim(owner, LAYER)` on 0x1143, 3,315,375.59 LAYER, https://evm.now/tx/0xe8b4b438ae93992afc77f6ffaa72cf1f6386efecec45acd71293aa2211aac35f?chainId=1 | 26137426 |
| 4 deprecate 0xf051 (repeat, no state change) | nonce 3772, https://evm.now/tx/0x09127b1ee0b31353eba8eaca6623a2480ed69954c536f245aebca04d5d56d999?chainId=1 | 26137798 |
| 2 collect LAYER (repeat) | nonce 3773, https://evm.now/tx/0x20b6781dd138f701ea036ee0e52888d9b4e1b51e09e772863d5147003b319fa3?chainId=1 | 26137800 |
| 8 claim owner weth | nonce 3774, `claim(owner, WETH)` on 0x1143, 0.4796 weth, https://evm.now/tx/0xcc6a42bb0733587383a26831cf47bedc30f3494fdb27cee2e0c3c5a2b667ee06?chainId=1 | 26137802 |
| 3 deploy 111 helper | nonce 3775, `CollectFlushKeeperV1` at 0xa8fd2c8DB6A8EDfBa9eC2993b37F534e34D0B50E, runtime matches the repo (registry `verified`, default profile), https://evm.now/tx/0x1abd9c123b902276c25f881b6802fa7fd5690f0bfef06c43af00d2d2cc56c159?chainId=1 | 26137826 |

## part 1: today, without redeploying

### 1. collect 111 lp fees now and keep collecting (LF-01, LF-02 window)

| field | value |
|---|---|
| finding | LF-01 critical: `collectRewardsWithoutUnlock` is permissionless and `TAKE_PAIR` takes the net position manager credit, so anyone can divert the fees still sitting in the lp positions. no switch exists on the locker (immutable, no pause). exposure is exactly what accrued since the last collect |
| contract | locker `0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab` |
| call | `collectRewards(address token)` selector 0x5763dbd0, arg = 111 `0x61C9d89fe1212F6b55fF888816A151463287B8ae` |
| caller | anyone. locker pays the caller the v1 keeper reward share of the eth side (live 0, so nothing) |
| send | `cast send $L111 "collectRewards(address)" $C111 --gas-limit 900000 --rpc-url $ETH_RPC_URL --account ripe0x` |
| read now | pending is 13,404 coin and 0 eth (simulated, 658k gas). the swapper then holds the coin, the eth side would sit at the escrow under the swapper slot |
| verify | `cast call $C111 "balanceOf(address)(uint256)" $SWAPPER --rpc-url $ETH_RPC_URL` rises by about the pending coin. `cast call $ESCROW "feesToClaim(address,address)(uint256)" $SWAPPER 0x0000000000000000000000000000000000000000 --rpc-url $ETH_RPC_URL` (eth credit, 0 expected now) |
| risk | gas (~665k, about 0.003 eth at 5 gwei) exceeds the 0.0007 eth value pending today: this resets the exposure, it does not earn. if an eth credit appears at the escrow, flush in the same minute (`cast send $SWAPPER "flushPaired()" --gas-limit 200000 ...`, 72k gas) because anyone can `escrow.claim(swapper, 0)` and strand it (LF-02, nothing recovers it). coin side: leave it in the swapper until a keeper run converts it with a real minOut, `convert(0)` invites a sandwich bounded only by the swapper's 80% of spot floor |
| keep collecting | action 3 keeper, hourly check, collect when `preview()` shows more than 0.02 eth or 10,000 coin uncollected, or weekly regardless. it shrinks exposure and cannot close the hole |
| v2 class note | the LF-01 class does not exist on v2 coins. `ArtCoinsLpLockerV2` is a pure lock: `placeLiquidity` mints each position to the locker, and the contract has no function that collects fees, decreases liquidity or transfers a position (`rescue` refuses the PositionManager). the v2 pool lp fee is 0 and fees are skim paid in eth by the hook at swap time. the hourly collect rule above is a v1 111 rule, v2 has nothing to collect |

### 2. collect LAYER on the legacy locker (LF-01, legacy)

| field | value |
|---|---|
| finding | LF-01 on `ArtCoinsLpLockerMultiple`, same code path. smaller exposure: the legacy hook collects on swaps, ~403 LAYER (about 0.00002 eth) pending, 0 weth |
| contract | locker `0x75BE7E95745915fD0C1761B74F3f9650ad2d1118`, token LAYER `0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9` |
| call | `collectRewards(address token)` selector 0x5763dbd0 (checked in bytecode, simulation succeeds, 597k gas) |
| caller | anyone |
| send | `cast send $LLOCKER "collectRewards(address)" $LAYER --gas-limit 900000 --rpc-url $ETH_RPC_URL --account ripe0x` |
| split | slots read on chain: 3800 bps owner `0xCB43…` (credited to fee locker 0x1143), 4200 bps burn router 0x2eDB, 2000 bps protocol fee controller 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60. slot admins: owner for slots 0 and 1, factory 0xd159 for slot 2 |
| verify | `cast call $LFEELOCKER "availableFees(address,address)(uint256)" $OWNER $LAYER --rpc-url $ETH_RPC_URL` rises. `cast call $R_LAYER "status()(uint256,uint256,bool)" --rpc-url $ETH_RPC_URL` shows router balances |
| risk | gas only. do it once now and when LAYER trading volume is high. not worth a cron at current size |

### 2b. deploy and run the LAYER keeper (collect, claim, split, burn)

note (D64): LAYER already has a hosted keeper, `layer-keeper` on fly.io in ripe0x/new-material, running this same pipeline every 30 minutes. do not run a second LAYER bot. this action is optional: deploy `CollectFlushKeeperLayer` only if you want the layer keeper to switch to one atomic tx. the artcoins runner must be deployed with `KEEPERS=111` (the v2 fee steps run in the LAYER bot, D92).

| field | value |
|---|---|
| finding | nothing calls `processBurnWeth` on the LAYER routers: the autoforward extension 0x38d0 deliberately skips it (no nested unlock), and its claim and split stages only fire above 0.01 weth or 100,000 LAYER, so small slots sit forever (scripts-and-keepers gap list). LF-01 exposure on LAYER is one swap's fee, because the hook collects on every swap |
| contract | `src/v2/keepers/CollectFlushKeeperLayer.sol`, ctor `(locker, LAYER, weth, feeLocker, controller, [router0, router1, router2])` = `$LLOCKER $LAYER $WETH $LFEELOCKER 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60 [$R_LAYER, $R_OPEN, 0x0EB22955E8904b8C5a4EC6f1D476f5b0C93854ca]`, taken from `script/Addresses.sol` by the script. no owner, holds nothing, any wallet deploys and runs it. use the keeper hot key, not the owner key |
| path | collect to the fee locker (38% owner, 42% router 0x2eDB, 20% controller 0x5fDc), `claim` (0x21c0b342) the controller and router slots (never the owner slot), `processFees(address)` (0x61582eaa: 60% treasury 0x41c3, 40% router), `processBurnLayer()` (0x811be55f), `processBurnWeth(uint256)` (0x2cb58c11) on every router at or above 0.01 weth. no LF-02 stranding shape: router and controller book by balance (`test_layerKeeper_thirdPartyClaim_doesNotStrand`) |
| deploy dry run | `ALLOW_SUPERSEDED=1 forge script script/v2/RunKeeperLayer.s.sol:DeployKeeperLayer --rpc-url $ETH_RPC_URL` (the scripts refuse mainnet without `ALLOW_SUPERSEDED=1`, the legacy stack is superseded in the registry) |
| deploy | `ALLOW_SUPERSEDED=1 forge script script/v2/RunKeeperLayer.s.sol:DeployKeeperLayer --rpc-url $ETH_RPC_URL --broadcast --account artcoins-keeper` then `export KEEPER_LAYER=<printed address>`. record it in `deployments/mainnet.json` |
| check | `cast call $KEEPER_LAYER "preview()(uint256,uint256,uint256[4],uint256[3],uint256[3])" --rpc-url $ETH_RPC_URL` (0xefae2305): uncollected LAYER, uncollected weth, claimable [controller LAYER, controller weth, router LAYER, router weth], weth plus eth at [0x2eDB, 0xE600, 0x0EB2], their thresholds |
| run dry | `ALLOW_SUPERSEDED=1 forge script script/v2/RunKeeperLayer.s.sol:RunKeeperLayer --rpc-url $ETH_RPC_URL` (prints preview, simulates with rate 0, quotes the realized LAYER per weth minus `KEEPER_SLIPPAGE_BPS`, default 200) |
| run | `ALLOW_SUPERSEDED=1 forge script script/v2/RunKeeperLayer.s.sol:RunKeeperLayer --rpc-url $ETH_RPC_URL --broadcast --account artcoins-keeper --gas-limit 3500000`. by hand: `cast send $KEEPER_LAYER "run(bool,uint256,bool)" true $RATE true --gas-limit 3500000 --rpc-url $ETH_RPC_URL --account artcoins-keeper` (selector 0xc2e8c918, `$RATE` LAYER per 1e18 weth, 0 means each router's own floor; simulate first with `cast call --from <keeper key address>` and the same arguments) |
| gas floors (D49) | floors, not caps: collect 640k, claim 60k, processFees 80k, processBurnLayer 60k, processBurnWeth 900k (each burn is a swap and pays the hook's collect), each plus 50k margin, the 1/63 reserve and 20k. a shortfall reverts `InsufficientGas(step)` (0x969aeb08, 1 collect to 5 weth burn), a collect revert bubbles, other reverts are logged as `StepSkipped(uint8,address,bytes)` (topic 0x0ec30982ffee6bdc8b4f21abd0cf9b3d5a7f4f836a0c96799c3efc0118d66235) and the run completes. measured: full path with one burn 853k, two reward router burns 1.84M, smallest completing limit with one burn 1.5M. set 3,500,000 |
| floors and rate | routers with an owner floor (0x2eDB 5e24, 0xE600 1.0353e25) get `max(rate, floor) * balance / 1e18`. floor 0 means paused, the router reverts `SlippageFloorNotSet` (0xc2358797), reported. 0x0EB2 has no floor setter and gets 0 (its 1% impact clamp and 80% spot floor on the consumed amount apply) |
| cadence | daily cron: run when any `routerWeth[i] >= routerThreshold[i]` or `routerWeth[0] + claimable[3] + 0.4 * (claimable[1] + controller weth) >= 0.01 weth`; weekly regardless. an idle run is about 0.65M gas for nothing, skip it. refresh the router floors first (action 5) |
| hosted runner | `keeper/` (fly.io, one machine) applies this cadence: reads `preview()` daily, runs at most once per 24 h, weekly regardless, with the 3,500,000 gas limit. rate: the simulated `run(true, 0, false)` rate cut to the largest router balance's constant liquidity estimate, minus 200 bps, and never under the pool floor `spot * (1 - lp fee - skim) * (1 - 200 bps - 100 bps impact)` read from `extsload` of the pool slot0; no weth burned in the simulation, impact above 100 bps or no floor sends `run(false, 0, true)`, never a rate of 0 with burn on. a run that leaves its trigger (routerWeth, combined weth) above half its value backs off 1 h doubling to 24 h and alerts `no_progress` (`due_no_burn` when the burn was skipped). funding: the key needs `3,500,000 x MAX_GAS_GWEI` (default 14 gwei: 0.049 eth) or LAYER sends are skipped `insufficient_funds`. stuck tx: same nonce replacement at +12.5% after 30 min, 3 times, then a cancel. deploy, secrets, alerts: `keeper/README.md`. set `KEEPER_LAYER` until the keeper is in the registry |
| verify | `cast call $R_LAYER "status()(uint256,uint256,bool)" --rpc-url $ETH_RPC_URL` shows weth under 0.01 after a burn. `cast call $LFEELOCKER "availableFees(address,address)(uint256)" 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60 $WETH --rpc-url $ETH_RPC_URL` is 0. `cast balance $KEEPER_LAYER --rpc-url $ETH_RPC_URL` is 0 |
| risk | rewards: 0x2eDB pays none, 0xE600 and 0x0EB2 pay 0.5% (cap 0.01 eth) to the caller, so the run is owner funded at current volume. a stale low owner floor is still callable by anyone directly (LF-09). key under 0.05 eth. proof tests: `test/v2/KeeperLayer.fork.t.sol` (11), detail in `docs/v2/review/keeper-111.md` (LAYER keeper) |

### 3. deploy and run the 111 collect and flush keeper

| field | value |
|---|---|
| finding | LF-01 (reduces pending), LF-02 / K-01 (collect, flush and convert in one tx), K-04 (no third party earns enough to run it) |
| contract | `src/v2/keepers/CollectFlushKeeperV1.sol`, ctor `(locker, token, swapper, escrow)` bound to `$L111 $C111 $SWAPPER $ESCROW`. no owner, holds nothing, any wallet can deploy and run it. use a dedicated hot key, not the owner key |
| deploy dry run | `forge script script/v2/RunKeeper111.s.sol:DeployKeeper111 --rpc-url $ETH_RPC_URL` |
| deploy | `forge script script/v2/RunKeeper111.s.sol:DeployKeeper111 --rpc-url $ETH_RPC_URL --broadcast --account artcoins-keeper` then `export KEEPER_111=<printed address>`. record it in `deployments/mainnet.json` |
| check | `cast call $KEEPER_111 "preview()(uint256,uint256,uint256,uint256,uint256)" --rpc-url $ETH_RPC_URL` returns uncollectedEth, uncollectedCoin, escrowedEth, swapperEth, swapperCoin. `swapperEth > 0` means a third party already stranded eth |
| run dry | `forge script script/v2/RunKeeper111.s.sol:RunKeeper111 --rpc-url $ETH_RPC_URL` (prints preview and a quoted minOut, `KEEPER_SLIPPAGE_BPS` default 100) |
| run | `forge script script/v2/RunKeeper111.s.sol:RunKeeper111 --rpc-url $ETH_RPC_URL --broadcast --account artcoins-keeper --gas-limit 1200000` (`run(bool,uint256)` selector 0x02143aa9, measured 799k gas) |
| gas floors (D49) | the gas limit is part of the call, set it by hand and never take a limit from an `estimateGas` search. the floors are not caps: each step runs with all remaining gas but only starts if `gasleft()` clears floor plus 50k margin plus the 1/63 reserve plus 20k. collect floor 658k (needs 739k left to start), flush 72k (needs 144k left), convert 299k (needs 375k left). the smallest limit that completes is about 1.1M, use 1.2M. below that the run reverts `InsufficientGas(step)` (selector 0x969aeb08, step 1 collect, 2 flush, 3 convert), it never skips a step silently: the sweep from 1.3M to 0.3M gave 8 completed, 33 reverted, 0 skipped. a collect revert bubbles, a flush or convert revert is reported as `FlushSkipped` or `ConvertSkipped` and the run completes |
| cadence | cron hourly: read `preview()`, run when uncollectedEth > 0.02 eth, uncollectedCoin > 10,000e18, escrowedEth > 0.05 eth (flush overdue), or the weekly timer is due. skip if pending is worth less than the gas, unless the timer is due. convert has its own 50 block pacing, extra attempts are swallowed no ops. monitor `lastConvertBlock` age and `swapperEth` |
| hosted runner | `keeper/` (fly.io, one machine) applies this cadence: reads `preview()` hourly, runs at most once per 6 h, skips a threshold run worth less than its gas (eth plus coin at pool spot) unless the weekly timer is due, with the 1,200,000 gas limit. minOut: `max(simulated run(true, 0) - 100 bps, spot * (1 - skim - lp fee) * (1 - 100 bps - 100 bps impact))` for the swapper's next step, spot from `extsload` of the pool slot0 and the hook's `skimConfig`; no convert in the simulation, a missing floor or a quote under it sends `run(false, 0)`, never `run(true, 0)`. live mode refuses to start without `PRIVATE_RPC_URL` unless `ALLOW_PUBLIC_MEMPOOL=1`. a run that leaves its trigger above half its value backs off 1 h doubling to 24 h (`no_progress`). alerts on `swapperEth > 0` and two reverts in a row. funding: `3,500,000 x MAX_GAS_GWEI` with LAYER enabled (0.049 eth at the default 14 gwei), `1,200,000 x MAX_GAS_GWEI` for 111 alone (0.0168 eth). deploy, secrets, alerts: `keeper/README.md`. set `KEEPER_111` until the keeper is in the registry |
| verify | `cast call $SWAPPER "lastConvertBlock()(uint256)" --rpc-url $ETH_RPC_URL` moves after a convert. `cast balance $KEEPER_111` is 0 after every run |
| risk | cannot stop a griefer who calls `collectRewards` then `escrow.claim(swapper,0)` himself in one tx, cannot recover eth already stranded. send runs through a private relay. the key only pays gas, keep under 0.05 eth. proof tests: `test/v2/KeeperV1_111.fork.t.sol` (8), detail in `docs/v2/review/keeper-111.md` |

### 4. deprecate the open factory 0xf051 (FT-02, FT-03, S-03)

| field | value |
|---|---|
| finding | FT-02 launch hijack, FT-03 protocol bps zeroed by any caller, S-03 open by default. live: deprecated false, deployFee 0, version "3", owner 0xCB43, hook 0xAAd6 and locker 0xd914 enabled |
| confirm first | `cast call $F_OPEN "deprecated()(bool)" --rpc-url $ETH_RPC_URL` returns false. zero coins: `cast logs --address $F_OPEN --from-block 25125700 --to-block latest "TokenCreated(address,address,address,string,string,string,string,string,int24,address,bytes32,address,address,address,uint256,address[])" --rpc-url $ETH_RPC_URL` returns nothing (positive control: the same query on $F_CUR from block 25260000 returns the 111 launch) |
| contract and call | `$F_OPEN` `setDeprecated(bool)` selector 0xd848dee7, arg `true`. onlyOwner (also present on 0x4959 and 0xd159) |
| send | `cast send $F_OPEN "setDeprecated(bool)" true --rpc-url $ETH_RPC_URL --account ripe0x` |
| verify | `cast call $F_OPEN "deprecated()(bool)" --rpc-url $ETH_RPC_URL` returns true |
| risk | none for coins (zero launched). reversible by `setDeprecated(false)`. the allowlist 0xd6D5fb5CfE386d0eB73a09cba5d190beb802e6E8 is shared with the live hook 0x636c, do not touch it. no other action on 0xf051 is needed once deprecated (owner can still launch there) |

### 5. LAYER burn router floors (LF-09)

| field | value |
|---|---|
| finding | LF-09 high: the live routers burn the whole weth balance per call, the only guard is the owner floor `minLayerOutPerWeth` (LAYER out per 1e18 weth, 1e18 scaled), now 30.8% and 63.9% of spot. a floor above spot blocks burns until updated (safe), floor 0 pauses `processBurnWeth` with `SlippageFloorNotSet` |
| contracts | LAYER router `0x2eDBdF011768d8cd4Ef537658b41440900C52000` (floor 5.0e24, owner 0xCB43, threshold 0.01 weth, holds 0.000186 weth). open stack router `0xE60046ee745B235109C10d322A1cbDB3c029De43` (floor 1.0353e25, owner 0xCB43, holds 0). both bound to the LAYER pool, source `src/protocol-fee/legacy/BurnRouter.sol`. `processBurnWethOpenTab` does not exist on either |
| call | `setMinLayerOutPerWeth(uint256 newFloor)` selector 0xe12eb8ba, owner only, emits `MinLayerOutPerWethUpdated` |
| compute | spot from the pool (id 0x85c15a70d86374f345b25c9e97a1f06b2a39765ac48269445ce0514037f31e50, LAYER is currency0, lp fee 1%, hook 0xA5eA): `SLOT=$(cast keccak $(cast abi-encode "f(bytes32,uint256)" $PID 6))`, `V=$(cast call $PM "extsload(bytes32)(bytes32)" $SLOT --rpc-url $ETH_RPC_URL)`, `SQRT=$(python3 -c "import sys;print(int(sys.argv[1],16)&((1<<160)-1))" $V)`, `SPOT=$(python3 -c "import sys;s=int(sys.argv[1]);print(10**18*2**192//(s*s))" $SQRT)`, `FLOOR=$(python3 -c "import sys;print(int(sys.argv[1])*95//100)" $SPOT)`. at block 26130514 spot = 1.6213e25 LAYER per weth, 95% = 1.5402e25 |
| recommended | 95% of spot (1% pool fee plus about 4% for impact on a sub weth balance). raise the margin to 90% if the router balance is above 1 weth or the pool is thin. refresh at least daily and before any manual burn, because a stale low floor is the exposure and a stale high floor only blocks. keep router balances small |
| send | `cast send $R_LAYER "setMinLayerOutPerWeth(uint256)" $FLOOR --rpc-url $ETH_RPC_URL --account ripe0x` and the same on `$R_OPEN` |
| verify | `cast call $R_LAYER "minLayerOutPerWeth()(uint256)" --rpc-url $ETH_RPC_URL`. enforced minimum is `requiredMinLayerOutForWethAmount(1e18)`. LF-12: on 0xE600 the view reads about 0.5% under the stored floor, so keepers should pass `minLayerOut` from the setter value, not the view |
| risk | the setter is the whole control. a floor set in a public mempool right before a burn is front runnable only in the harmless direction. not a fix: LF-03 (clamp loops) is in the src router, v2 replaces both. burning is permissionless (`processBurnWeth(uint256 minLayerOut)`, ready at 0.01 weth), so also call `status()` before changing floors |
| other routers | `0x0EB22955E8904b8C5a4EC6f1D476f5b0C93854ca` (behind permanent collection controller 0xd8C6…, owner 0xCB43) has no floor setter, nothing to set, flagged LF-03 and LF-04. `0x9304a81965Ef3F7A092bd9eFd8c2fFc411E5F34d` (superseded) has floor 0 so it is paused, holds 0 |

### 6. freeze LAYER assets (R4, renderer and extension mutability)

what is mutable today, all owned by the owner eoa (token admin, renderer owner, scripty content owner, hook token admin gate):

| asset | state read | freeze call | what it means |
|---|---|---|---|
| scripty content, sketch js | `ll/sketch.b64.1778120217836`, 22,996 bytes, frozen false, owner 0xCB43 | `cast send $SCRIPTY "freezeContent(string)" "ll/sketch.b64.1778120217836" --rpc-url $ETH_RPC_URL --account ripe0x` (selector 0x7a2c5701, on `ScriptyStorageV2` 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699, third party contract, source not in repo) | the bytes under that name can never change again. one way. without it the owner can append chunks and rewrite the animation script |
| scripty content, history | `ll/history.b64.1778120217836`, 3,632 bytes, frozen false | same call with that name | seeded trade history fixed |
| scripty content, mona image | `ll/mona.1778120217836`, 78,065 bytes, frozen false | same call with that name | backdrop image fixed |

verify each freeze: `cast call $SCRIPTY "contents(string)(bool,address,uint256,bytes)" "<name>" --rpc-url $ETH_RPC_URL` first value true. freezing storage alone does not freeze the animation: the renderer still lets the owner point at other content names. all of these are one way, so do them last and only after the v2 plan is final:

| lever | call | effect | recommendation |
|---|---|---|---|
| renderer `0x0572C1754378c2f9Aef51b57b2830D343ee9d186` owner | `transferOwnership(address)` selector 0xf2fde38b to `0x000000000000000000000000000000000000dEaD` (no zero check, no freeze function exists) | locks `setSketchScriptName`, `setHistoryAsset`, `setMonaAsset`, `setImageOverrideUri`, name, symbol, supply, description strings. `counter` (0x38d0), builder and storage are immutable already | do after the three scripty freezes. also pins the ipfs `imageOverrideUri` pointer |
| LAYER token admin (owner) | `renounceAdmin()` selector 0x8bad0c0a on `$LAYER` | no more `updateImage`, `updateMetadata`, `setMetadataRenderer`, `updateAdmin`. renderer swap becomes impossible | last. renderer gas is 32M and grows with trades (G2), a future renderer migration needs this power |
| hook pool extension | `lockPoolExtension((address,address,uint24,int24,address))` on `$LHOOK`, arg `(0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9,0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,8388608,200,0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc)`, caller token admin (owner). now unlocked, extension 0x38d03af54ba9F80c3476B3D3B3a6415A399303f7 | the counter extension can never be swapped or cleared | do not lock while LL1, LL2 or the autoforward thresholds may need a migration. the sniper recipient is already locked |
| autoforward extension | owner 0xCB43, `setThresholds(uint256,uint256,uint256,uint256)`, `seedCounters`, `seedHistory`. thresholds now 0.01 weth and 100,000 LAYER | tuning only, nothing to freeze | `transferOwnership` to dead only if thresholds are final |
| LAYER slot admins (LF-05) | `updateRewardAdmin(address,uint256,address)` on `$LLOCKER`, slots 0 and 1 are owner admin | would freeze recipients | do not freeze slot 1: the burn router recipient 0x2eDB must be repointable when v2 replaces it |
| legacy hook `protocolFeeNumerator` | stays 0, `setProtocolFeeNumerator(uint256)` selector 0x45b11434 by the 0xd159 owner, max 500000 (50% of lp fee, taken to the factory) | the one live fee lever on LAYER | leave at 0 (D21); zero is deployment policy, asserted by the v2 deploy postflight. the v2 burn router reads the hook's stored `protocolFee()` at burn time and removes the charge, computed on the whole budget, from the weth it prices at spot (`floorForPartial`), so a nonzero value lowers the floor and does not stop the burn. if the owner key is a concern, no on chain lock exists |

### 7. keep current factory 0x4959 deprecated, retire hook 0x636c later (DESIGN 2.1)

| field | value |
|---|---|
| finding | superseded stack, only owner can launch (deprecated true, deployFee 0.069 eth, owner 0xCB43) |
| now | nothing to send. confirm: `cast call $F_CUR "deprecated()(bool)" --rpc-url $ETH_RPC_URL` returns true. never call `setDeprecated(false)` on it |
| later, when v2 is live and the credits coin launched | `cast send $F_CUR "setHook(address,bool)" 0x636c050296B5Cc528D8785169Bf8923716FCa9cc false --rpc-url $ETH_RPC_URL --account ripe0x` (`setHook(address,bool)` selector 0x833e8db1, onlyOwnerOrAdmin, checked in the 0x4959 bytecode) |
| verify | `cast call $F_CUR "enabledHooks(address)(bool)" 0x636c050296B5Cc528D8785169Bf8923716FCa9cc --rpc-url $ETH_RPC_URL` returns false |
| risk | affects future launches on 0x4959 only. coin 111, its hook, locker and pool are untouched. reversible by `setHook(..., true)`. the hook has no owner and no off switch, `setHook` is the only lever |

### 8. claim the owner's unclaimed LAYER fees (legacy fee locker)

| field | value |
|---|---|
| finding | the owner is slot 0 recipient (3800 bps) of the LAYER locker, credited at the fee locker, never claimed: 3,315,375.59 LAYER and 0.4796 weth (read: `availableFees`) |
| contract | fee locker `0x1143db0913Ca5eCe8A42FC01b625fD81F9386b05`, owner 0xCB43, allowed depositor: the LAYER locker |
| call | `claim(address feeOwner, address token)` selector 0x21c0b342. permissionless but pays only `feeOwner`, so anyone can trigger it and it can only pay the owner. reverts `NoFeesToClaim` at zero |
| send | `cast send $LFEELOCKER "claim(address,address)" $OWNER $LAYER --rpc-url $ETH_RPC_URL --account ripe0x` and again with `$WETH` |
| verify | `cast call $LFEELOCKER "availableFees(address,address)(uint256)" $OWNER $LAYER --rpc-url $ETH_RPC_URL` returns 0, `cast call $LAYER "balanceOf(address)(uint256)" $OWNER --rpc-url $ETH_RPC_URL` rose |
| risk | none in the claim. selling 3.3M LAYER (about 0.2 eth at spot) moves a thin pool and the burn router floors. no deadline. same pattern for the protocol slot: 4,849 LAYER and 0.000489 weth at `0x5fDc…0A60` (below autoforward thresholds forever): `claim(0x5fDc39756A64A84518ef00CB6a0ED46971e00A60, token)` on the fee locker then `processFees(address)` on the controller, both permissionless |

### 9. 111 swapper stranding (LF-02, K-01): what the owner can and cannot do

| item | answer |
|---|---|
| mechanism | `escrow.claim(swapper, 0x0)` is permissionless and pushes the swapper's eth credit into its `receive()`. `flushPaired` sizes from the escrow ledger, so it then reverts `NothingToFlush`. the swapper has no owner, no sweep, `convert` forwards only swap output |
| recover stranded eth | nothing on chain can. swapper `0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961` has no owner, the 111 slot admin is 0xdEaD, the escrow owner cannot touch credited balances. current stranded balance: 0 (`cast balance $SWAPPER`) |
| prevent | keeper only (action 3): collect then flush in one tx. cannot stop a same tx griefer. reduces exposure only |
| owner levers that do not help | escrow `addDepositor`, factory setters. none touch the swapper |
| residual | accept. the v2 stack has no fee swapper |

### 10. other owner actionable items and things to leave alone

| item | contract and call | recommendation |
|---|---|---|
| escrow depositors | `$ESCROW` `addDepositor(address)` selector 0xfc8acba2, no remove, no pause. depositors now: locker 0x866e, hook 0x636c | do not add any. a bad depositor can credit junk and cannot be removed. the same function exists on the open escrow 0xDD1b8C9C99Be3C717B9A5eb3C84297C5bfca1C06 and fee locker 0x1143 |
| locker `withdrawETH(address)` 0x690d8320, `withdrawERC20(address,address)` 0x9456fbcc | `$L111`, `$LLOCKER` | stray balances only (3,312 wei of coin at 0x866e). `withdrawETH` uses `transfer` (LF-11), pass an eoa. position nfts cannot be withdrawn |
| LAYER `protocolFeeNumerator` | hook `$LHOOK`, read 0, `protocolFeeNumerator()` | stays 0 |
| factory 0xd159 (LAYER) | deprecated true, owner 0xCB43 | keep deprecated |
| coin 111 tax rate and exemption (FT-01, H14) | token admin is `0xA96a11257890ED1C43C16c098E286e18e45E6258` (permanent collection poker), not the owner. `setTaxBps(uint16)` exists on the token. the hook `0x636c` has no owner | not owner actionable here. any change is a permanent collection call. v2 fixes the exemption mint |
| 111 `contractURI` gas (G1, 177M gas) | renderer 0x7604… and 0x9438…, outside this repo | permanent collection side |
| burn router and controller owners | `$R_LAYER`, `$R_OPEN`, controllers 0x5fDc… and 0xd8C6… all owned by 0xCB43, two step transfer absent (plain Ownable) | do not transfer ownership without a read back of `owner()` on a fork first |

## part 2: v2 rollout order

sources of truth, in this order: `script/v2/DeployV2Lib.sol` (the routine), `script/v2/DeployV2Stack.s.sol`, `script/v2/deploy.sh` with `script/v2/env/*.env`, `script/v2/README.md`, `docs/v2/CREDITS-ENGINE-INTERFACE.md`. the same routine runs in the script and in the fork harness (`ForkStack.deployV2Stack`), so the tests exercise the exact broadcast. if this file and the lib differ, the lib wins and this file is wrong. always `FOUNDRY_PROFILE=ci`: at the default profile `ArtCoinsDeployerV2` is 24,806 bytes, over EIP-170, and the post deploy asserts refuse it.

the v2 stack deployed on 2026-10-09 is the `v2` entry of `deployments/mainnet.json` with status `current`, and no coin launched on it. the simplified stack below is redeployed before the first coin. the sequence: deploy with the factory deprecated, merge the record (it becomes the `v2` entry with status `current`, and the previous record stays listed as `v2-<deployedAt>`, `superseded`), regenerate the addresses, pass the first coin rehearsal on a fork of the new stack (gate 7), then launch the credits coin.

### 2a. deploy, one broadcast

values in `script/v2/env/mainnet.env` (read by `deploy.sh`, passed to `DeployV2Stack.s.sol` as env vars):

| env var | mainnet value | meaning |
|---|---|---|
| CHAIN_ID, RPC_DEFAULT, FOUNDRY_PROFILE | 1, `https://mainnet.gateway.tenderly.co`, ci | `RPC_URL` in the shell overrides the rpc |
| WALLET_MODE, KEYSTORE | account, ripe0x | the keystore address must equal OWNER |
| OWNER | 0xCB43078C32423F5348Cab5885911C3B5faE217F9 | owner of every owned contract and the factory team fee recipient |
| TREASURY, TREASURY_BPS | 0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4, 8000 | controller treasury and its share (Constants allow 1000 to 9000, the rest buys and burns LAYER); owner tunable with `setSplit` |
| DEPLOY_FEE | 0 | factory deploy fee in wei; owner tunable with `setDeployFee` |
| VERIFY, REQUIRE_CLEAN_GIT | full, true | explorer plus chain verification; HEAD must be `origin/master` or a tag on origin, tree clean |
| BROADCAST_DIR, DEPLOY_JSON, RECORD | `broadcast`, `tmp/v2-deploy-1.json`, `deployments/1.v2.json` | forge broadcast files, the script's address json, the registry fragment |

`deploy.sh` refuses while any of CHAIN_ID, RPC_DEFAULT, FOUNDRY_PROFILE, WALLET_MODE, OWNER, TREASURY, TREASURY_BPS, DEPLOY_FEE, VERIFY, REQUIRE_CLEAN_GIT, BROADCAST_DIR, DEPLOY_JSON or RECORD is empty. `DeployV2Stack.s.sol` run directly reads OWNER, TREASURY, TREASURY_BPS and DEPLOY_FEE from the environment and defaults them to `Addresses.OWNER`, OWNER, 8000 and 0.

`script/v2/deploy.sh mainnet` runs the guards (rpc chain id, wallet, git), the warm ci build, the dry run, a per transaction gas estimate with the OWNER balance check, the keystore signer check and typed confirmation, the `--slow` broadcast with `--account ripe0x`, the readback, the record `deployments/1.v2.json` and `verify-v2.sh`. the transaction count and gas are printed by the wrapper before the keystore prompt. the hook address depends on the broadcaster, so a dry run with `--sender $OWNER` shows the real one.

| step | rehearsal, no key | command |
|---|---|---|
| 0a | dry run on a fork | `RPC_URL=$ETH_RPC_URL script/v2/deploy.sh mainnet` (`DRY_RUN` defaults to 1: guards, warm ci build, simulation only) |
| 0b | harness rehearsal, broadcaster differs from OWNER, then accept | `FOUNDRY_PROFILE=ci forge test --match-path "test/v2/DeployV2Stack.fork.t.sol" --fork-url $ETH_RPC_URL -vv`. record the block |
| 0c | broadcast | `RPC_URL=$ETH_RPC_URL DRY_RUN=0 script/v2/deploy.sh mainnet` (typed confirmation of the last 6 hex digits of OWNER, `--account ripe0x --slow`, forge prompts for the keystore password) |

hook address flags: `HOOK_FLAGS` is beforeInitialize, beforeAddLiquidity, beforeSwap, afterSwap, beforeSwapReturnDelta and afterSwapReturnDelta. the low 14 bits of the hook address equal `0x28CC` (binary `10 1000 1100 1100`), so the address ends in `28cc`, `68cc`, `a8cc` or `e8cc` (the two bits above bit 13 are free). `post deploy asserts` checks `uint160(hook) & Hooks.ALL_HOOK_MASK == 0x28CC` and that the declared permissions equal the address flags.

the v2 stack is 12 contracts, in the order `DeployV2Lib.deploy` creates them:

| # | contract | constructor args as deployed | note |
|---|---|---|---|
| 1 | `ArtCoinsFeeEscrowV2` | `(broadcaster)` | owner is the broadcaster until the ownership hand over |
| 2 | `ArtCoinsPoolExtensionAllowlist` (v1 source, new instance) | `(OWNER)` | a new instance serves the v2 hook |
| 3 | `ArtCoinsHookV2`, CREATE2 via 0x4e59b44847b379578588920cA78FbF26c0B4956C | `(PoolManager, broadcaster, escrow, allowlist)` | salt mined in the script for low 14 bits 0x28CC, max 400,000 tries, printed as `hookSalt` in the output json |
| 4 | `ArtCoinsLpLockerV2` | `(broadcaster, PositionManager, Permit2)` | pure lock: holds the launch positions, no fee path |
| 5 | `ArtCoinsMevLinearSkimV2` | `(hook)` | ownerless |
| 6 | `ArtCoinsFactoryV2` | `(broadcaster, PoolManager, deployFee)` | ships `deprecated = true` |
| 7 | `ArtCoinsDeployerV2` | `(factory)` | then `factory.setTokenDeployer(deployer)` (owner only); the registry records its runtime code |
| 8 | `BurnRouterV2` | `(OWNER, PoolManager, WETH, LAYER, LAYER pool key)` | bound to the live LAYER/WETH pool at construction; the key is read from the legacy locker's `tokenRewards(LAYER)` |
| 9 | `ProtocolFeeControllerV2` | `(OWNER, escrow, treasury, burnRouter, treasuryBps)` | after the router, its constructor needs it |
| 10 | `ArtCoinsUniv4EthDevBuyV2` | `(factory, PoolManager)` | launch extension, ownerless. enabled on the factory in wiring |
| 11 | `ArtCoinsAirdropV2` | `(factory)` | launch extension, ownerless. enabled on the factory in wiring |
| 12 | `ArtCoinsVaultV2` | `(factory)` | launch extension, ownerless. enabled on the factory in wiring |

wiring, in the order `_wire` sends it:

| # | contract | call | why |
|---|---|---|---|
| 1, 2 | escrow | `addDepositor(hook, true)`, `addDepositor(controller, false)` | the hook is a core depositor and `setFeeEscrow` reverts without it. the controller needs depositor rights for its push fallback |
| 3 to 5 | hook | `setFeeEscrow(escrow)`, `setExtensionAllowlist(allowlist)`, `setLauncher(factory, true)` | |
| 6 | locker | `setLauncher(factory, true)` | the factory is the only caller of `placeLiquidity` |
| 7 to 9 | factory | `setHook(hook, true)`, `setLocker(locker, true)`, `setMevModule(mev, true)` | enable the stack |
| 10, 11 | factory | `setProtocolRecipient(controller)`, `setTeamFeeRecipient(OWNER)` | |
| 12 | factory | `setDeployFee(DEPLOY_FEE)` | |
| 13 to 15 | factory | `setExtension(devBuy, true)`, `setExtension(airdrop, true)`, `setExtension(vault, true)` | enables the three launch extensions (the factory checks the ERC-165 id and `constantsHash()`) |
| none | factory | `deprecated` stays true | opening is the last owner tx, 2c |

| step | what | detail |
|---|---|---|
| 13 | wiring | the table above, 15 calls after contract 12 |
| 14 | ownership, Ownable2Step | broadcaster == OWNER: nothing to do. otherwise escrow, hook, locker and factory end with `pendingOwner() == OWNER` (0xe30c3978) and the broadcaster still owns them. the allowlist, router and controller are constructed with OWNER, nothing to accept |
| 15 | post deploy asserts, in the script | `DeployV2Lib.check`, in this order. constants: `constantsHash()` of escrow, hook, locker, mev, factory, deployer, router, controller, dev buy, airdrop, vault. hook: low bits 0x28CC, permissions equal the address flags and the declared set, PoolManager, globals escrow and allowlist, factory is a hook launcher. escrow: hook is a core depositor, controller a non core depositor. locker: factory is a launcher. factory: PoolManager, deployer binding both ways, `enabledExtensions` true for the dev buy, the airdrop and the vault, each with `factory()` equal to the factory, the dev buy `poolManager()`, the ERC-165 interface id of each extension supported by its own address and unsupported by the other two, protocol recipient, team fee recipient, deploy fee, `deprecated` true, `STACK_VERSION`. periphery: mev hook, controller escrow, treasury, router and split, router PoolManager, weth, `coin()` and pool key, controller `coin()` and PoolManager, locker PositionManager and Permit2, router tunables at the `Constants` defaults. LAYER hook: `protocolFeeNumerator` and the stored `protocolFee` are 0 (deployment policy). owners or pending owners of the seven owned contracts. runtime size of all 12 under 24,576 and hook and locker with the headroom. prints `post deploy asserts: ok`, the registry json, writes `tmp/v2-deploy-1.json` |

step 14 for a broadcaster that is not OWNER, one tx at a time, before anything else (until all four are accepted the broadcaster holds the owner powers). `acceptOwnership()` is 0x79ba5097:

```
J=tmp/v2-deploy-1.json
for k in escrow hook locker factory; do
  a=$(jq -r ".addresses.$k" $J)
  cast call --from $OWNER $a "acceptOwnership()" --rpc-url $ETH_RPC_URL
  cast send $a "acceptOwnership()" --rpc-url $ETH_RPC_URL --account ripe0x
  cast call $a "owner()(address)" --rpc-url $ETH_RPC_URL
  cast call $a "pendingOwner()(address)" --rpc-url $ETH_RPC_URL
done
```

per contract: the first line simulates, the second sends, `owner()` must return OWNER and `pendingOwner()` must return 0x0.

| step | what | command and check |
|---|---|---|
| 16 | verify | `script/v2/verify-v2.sh` (profile ci, run it after the accepts): `forge verify-contract` per contract with the json's constructor args (etherscan with `ETHERSCAN_API_KEY`, else blockscout), then the chain check through `script-js/verify-registry.mjs` on a one stack registry: runtime vs the local ci build with immutables masked, owners equal OWNER, escrow depositors, factory still deprecated. `--dry-run` prints the verify commands, `--skip-source` is chain only. the hook is verified as `src/v2/hooks/ArtCoinsHookV2.sol:ArtCoinsHookV2` (v1 has the same contract name). exit 0 |
| 17 | registry | `deploy.sh` wrote the record `deployments/1.v2.json`. after the `acceptOwnership` calls run `script/v2/verify-v2.sh` and `node script-js/v2-record.mjs tmp/v2-deploy-1.json broadcast/DeployV2Stack.s.sol/1/run-latest.json deployments/1.v2.json --verified`. merge: `node script-js/merge-v2.mjs deployments/1.v2.json --build` merges the record into `deployments/mainnet.json` (template `deployments/v2.template.json`). a `v2` entry with another factory (the 2026-10-09 stack) moves to `v2-<deployedAt>` with status `superseded` and the record becomes the `v2` entry with status `current` (D96); a `planned` or `deployed` entry gets status `deployed` and the `0x4959` stack stays `current`. the merge runs `verify-registry.mjs` on a temporary file first. then `node script-js/verify-registry.mjs --fill --update-blocks`, `node script-js/verify-registry.mjs --require-artifacts` (exit 0) and `cd script-js && npm run gen:addresses` (`V2_*` constants and the ts `V2` export). cutover, needed only while `v2` is not `current`: `node script-js/merge-v2.mjs deployments/1.v2.json --cutover --build` makes v2 `current` and the `0x4959` stack `superseded`, `node script-js/merge-v2.mjs --rollback` reverses it. commit the broadcast record (H4) |

### 2b. launch the first coin (credits engine coin), factory still owner only

the first coin is launched with `factory.deployToken`, which the owner can call while the factory is deprecated.

| step | what | detail and check |
|---|---|---|
| 1 | owner calls before launch | none. the referral rate is per pool (`fee.referralBps` in the launch config, default 0, cap 100 bps, changed by the coin admin with `hook.setReferralBps` until `lock()`), the protocol recipient is the controller, and a plain treasury bounty recipient needs no depositor rights |
| 2 | config | `cp script/v2/launch-configs/example.json my-coin.json`, set treasury, names, ticks, `"example": false`. limits: `bountyBps` at most 9,999, `baselineSkimBps` from 1 to 1,000, `positionBps` sum to 10,000, native eth only. the json carries the keys of `script/v2/launch-configs/example.json` |
| 3 | dry run | `forge script script/v2/LaunchV2Coin.s.sol --sig "run(string)" "$(cat my-coin.json)" --rpc-url $ETH_RPC_URL --sender $OWNER`. preflight on the wiring, `predictToken`, a snapshot dry run, then it stops before the tx. record the predicted token, `configHash`, value (the deploy fee) and pool id |
| 4 | broadcast | the same command plus `--account ripe0x --broadcast --slow`. excess value above `deployFee()` plus extension msgValues is refunded |
| 5 | checks | `factory.isCoin(token)`, token equals the predicted address, `hook.poolInfo(poolId).version == 2`, `token.launcherVersion() == 2`, the `TokenCreatedV2` event echoes the config and its `configHash` equals the dry run |
| 6 | post launch owner calls | none. the burn router burns LAYER for every coin |
| 7 | check the fee legs | a small buy and sell and check the fee legs: the bounty is pushed with the 2,300 gas stipend, anything that fails sits in the escrow under the recipient, claim it |
| 8 | registry | add the coin to the registry `coins` list (`verify-registry` passes) |

fee processing for the stack: the LAYER bot calls `ProtocolFeeControllerV2.processFees()` to split the ETH the controller received directly plus any escrow credit it claims, between the treasury and the burn router, and `BurnRouterV2.processBurn(minOut)` to buy and burn LAYER with the router's weth.

| item | value |
|---|---|
| dry run | `cast call --from $BOT_ADDR $CONTROLLER "processFees()" --rpc-url $ETH_RPC_URL` |
| send | `cast send $CONTROLLER "processFees()" --rpc-url $ETH_RPC_URL --account artcoins-keeper`, then `cast send $BURN_ROUTER "processBurn(uint256)" $MINOUT --rpc-url $ETH_RPC_URL --account artcoins-keeper`. `$MINOUT` is the simulated LAYER output minus 100 bps |
| cadence | the bot reads the controller and router balances and runs when the pending amount is worth more than the gas |
| monitor | key balance under 0.05 eth, escrow credit under the controller, router eth and weth balances (the controller sends eth, the router wraps it) |
| LAYER hook fee | before opening and while burns run, read `protocolFeeNumerator()` on the LAYER hook and alert when it is nonzero. the router reads the hook's `protocolFee()` at burn time and removes the weth the hook takes from the whole budget of an exact input swap from the weth priced at spot before applying `spotFloorBps`. a nonzero value therefore burns less LAYER per weth (the hook takes that share of every burn) and the floor tracks it |

### 2c. open to the public, `setDeprecated(false)` last

before the call: every gate below is true, the first coin ran at least one full fee cycle, and `cast call $F_V2 "deprecated()(bool)" --rpc-url $ETH_RPC_URL` returns true. then `cast send $F_V2 "setDeprecated(bool)" false --rpc-url $ETH_RPC_URL --account ripe0x` (0xd848dee7). to close again: `setDeprecated(true)`. no other owner tx is needed at opening.

### must be true before public

| # | gate | how to check |
|---|---|---|
| 1 | ci green on the release commit, fork tests that actually ran | jobs `Foundry project (no network)` (fmt, build sizes, hook size gate, tests), `Foundry fork tests (pinned mainnet block)`, `Registry schema`, `Registry vs chain and bytecode`. read the skip count: a fork job that skipped is not green (H5). the four known red v1 `BurnRouter` floor fork tests in `hygiene-fixes.md` are fixed or accepted in writing. `review-proofs` stays informational |
| 2 | `script/v2/verify-v2.sh` clean | exit 0 after the `acceptOwnership` calls, source verified on the explorer, runtime equals the ci build, wiring and owners match |
| 3 | registry verifies against chain and build | `node script-js/verify-registry.mjs --require-artifacts` exit 0, weekly workflow green, v2 stack present with deploy blocks |
| 4 | sizes under the ci profile | `FOUNDRY_PROFILE=ci forge build --sizes`: all 12 contracts under 24,576, hook and locker at least 1,024 bytes of headroom. both are asserted by the deploy postflight (`DeployV2Lib._checkSizes`), which `test/v2/DeployV2Stack.fork.t.sol` runs |
| 5 | external review of the hook swap path | written report covering beforeSwap, afterSwap return delta, the skim refund, stipend fee pushes, `FeeDelivery`, the factory and locker interplay. every high fixed or accepted in writing. covered by tests: a hostile fee recipient (`test_swap_hostileRecipient_cannotRevertSwap`), partial fills through the Universal Router with and without a refund address (`test_i1_partialFill_universalRouter_*`, `test_skim_universalRouterPartialFill_nothingInEscrow`), and the dev buy partial fill refund (`test_holds_devBuy_partialFill_skimRefundReachesRecipient`). not covered by a test: a nested swap from a recipient |
| 6 | review of the restricted transfer rule and the skim bounds | read `ArtCoinsTokenV2._route` (restricted transfers need an allowlisted side, or the PoolManager on one side with a transient allowance the canonical hook granted for a canonical swap in the same transaction), the allowlist setters (`AllowedForbidden` for the PoolManager and the canonical hook), and the hook's skim bounds (`baselineSkimBps` from 1 to 1,000, `bountyBps` at most 9,999, `lowerBaselineSkim` only downward). accepted residual: restriction is fee priced (D73, D74), so a canonical round trip of X in one transaction lets a holder move X through PoolManager balances |
| 7 | fork rehearsal of the first coin | the 2b steps 3 to 7 against a fork of the deployed stack with the real launch json, run by `test_gate7_fullSequence` and `test_gate7_rejectingBountyRecipient` in `test/v2/fork/FirstCoinRehearsal.t.sol`. `LAUNCH_CONFIG` names the launch json (the credits coin config; the default is `example.json`), parsed by `LaunchV2Lib`, the parser `LaunchV2Coin` runs, and the extension keys resolve to the addresses in `V2_DEV_BUY`, `V2_AIRDROP` and `V2_VAULT` (the registry's addresses for the deployed stack; the test fails on a config that names an extension whose address is unset). `test_gate7_freshStack_fullSequence` and `test_gate7_freshStack_rejectingBountyRecipient` in `test/v2/fork/FreshStackRehearsal.fork.t.sol` run the same flow on a stack that `DeployV2Lib` deploys on the fork, with a dev buy, an airdrop and a vault allocation added. `RehearsalFlow` checks: the predicted token equals the launched token, the launch gas is under the 16.7m tx cap (D54: a config with every cap at its limit costs about 19.6m gas, accepted, the ui keeps configs far below), `isCoin`, the hook pool version, the pool id, one `TokenCreatedV2` event (config hash, protocol recipient, pool plus extension supply equal the total supply), one `ExtensionTriggered` per configured extension and each extension's effect (dev buy swap, airdrop tranche and a claim by leaf index, vault tranche), Universal Router buy, wait, buy and sell with a refund address in hookData, no refund credit on full fills, the bounty leg paid or credited, an exact `processFees()` split, and `processBurn(minOut)` with the router floor, the keeper reward paid in eth, LAYER supply reduced by the burned amount and router ETH and WETH equal to the expected values. the rejecting recipient test checks the escrow credit of a bounty recipient that rejects eth and its `claimTo`. the dev buy partial fill refund is covered by `test_holds_devBuy_partialFill_skimRefundReachesRecipient`. run it on the real deployed stack once the registry holds the new addresses |
| 8 | site points at the v2 factory | the site (ripe0x/new-material) mirrors `abi/deployments.generated.ts` and `abi/{v1,v2}` from this repo's submodule pin; bump the pin after the registry holds the v2 stack. it reads `deprecated()` and `deployFee()`, shows the fee, blocks on an unknown chain, simulates before send (UI-01 to UI-09). check the coin renders in a real marketplace (not verified) |
| 9 | bot cron running | `CollectFlushKeeperV1` for 111 (part 1 action 3, 1.2M gas limit) and the LAYER bot calling `processFees()` and `processBurn(minOut)` on the v2 stack (2b), hot key under 0.05 eth, alerts set |
| 9b | LAYER keeper cron running | `CollectFlushKeeperLayer` (part 1 action 2b, 3.5M gas limit, `ALLOW_SUPERSEDED=1` for the scripts), daily `preview()` check, weekly run regardless. alert when a router stays at or above 0.01 weth for more than a day, or a run logs `StepSkipped` step 5 |
| 10 | old factories deprecated | `deprecated()` true on `$F_OPEN`, `$F_CUR`, `$F_LEGACY`. `setHook(0x636c…, false)` on `$F_CUR` after the first v2 coin trades (part 1 action 7) |
| 11 | part 1 actions 1, 2, 4 and 5 done, router floors fresh | collect timestamps, `minLayerOutPerWeth()` within 5% of 95% of spot |
| 12 | stack defaults read back | controller split 8000/2000, `deprecated` true until the last tx |
| 13 | public repo decision D26 reviewed | `origin` is the public ripe0x/artcoins (H3), branch `v2` and the review docs with findings on live contracts are already public (D26): keep or delete the remote branch on purpose. curated merge of `docs/v2` and `test/v2/review` (H2), mirror tag filter fixed (H1). part 1 of this file stays off the mirror until actions 1, 2, 4 and 5 are done |
| 14 | owner key custody | hardware or keystore. `acceptOwnership` was exercised on a fork (step 0b) before the real accepts |
