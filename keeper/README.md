# artcoins keeper runner

hosted loop for the three keeper contracts. the loop ticks every `INTERVAL_SECONDS` (600) to settle, replace or cancel the tx in flight; each keeper's `preview()` is read on its runbook cadence (111 hourly, LAYER daily, v2 hourly), decided per the runbook thresholds and the value vs gas rule, quoted by simulating the run with 0 and floored by an independent pool read, then sent one tx at a time with a fixed gas limit. a run that does not clear its trigger backs off. node 22, viem, nothing else. runs on one fly.io machine with a 1 gb volume for state.

| keeper | contract | runbook | call | gas limit | slippage default |
|---|---|---|---|---|---|
| `111` | `CollectFlushKeeperV1` | part 1 action 3 | `run(doConvert, minOut)` 0x02143aa9 | 1,200,000 | 100 bps |
| `layer` | `CollectFlushKeeperLayer` | part 1 action 2b | `run(doBurn, rate, unwrap)` 0xc2e8c918 | 3,500,000 | 200 bps |
| `v2:<s## when it runs

| keeper | checked | runs when (any) | at most | alert, not a trigger |
|---|---|---|---|---|
| 111 | hourly | `uncollectedEth > 0.02 eth`, `uncollectedCoin > 10,000e18`, `escrowedEth > 0.05 eth`, weekly timer | every 6 h | `swapperEth > 0` |
| layer | daily | any `routerWeth[i] > 0` and `>= routerThreshold[i]`, `routerWeth[0] + claimable[3] + 0.4 * (claimable[1] + controller weth) >= 0.01 weth`, weekly timer | every 24 h | `due_no_burn` (due, the simulation burned nothing) |
| v2 coin | hourly | `accruedPaired > 0.02 eth`, `accruedArtCoin > 10,000e18`, weekly timer (uncollected lp fees are not readable on v2, the timer collects them) | every 6 h | |

| gate, in order | rule |
|---|---|
| cadence | `KEEPER_<ID>_CHECK_INTERVAL_SECONDS` (3600, 86400, 3600; `CHECK_INTERVAL_SECONDS` sets all). a keeper not due for a check is `wait` |
| backoff | after a successful run every threshold metric that triggered it must drop by `PROGRESS_MIN_BPS` (5000, half) of its value at send time. if not: `no_progress` log, `keeper_no_progress_total`, the `/status` alert flag, and a backoff of 1 h doubling to 24 h (`BACKOFF_MIN_SECONDS`, `BACKOFF_MAX_SECONDS`). a run with progress clears it. the weekly timer never overrides a backoff |
| minimum run interval | `KEEPER_<ID>_MIN_RUN_INTERVAL_SECONDS` (21600, 86400, 21600; `MIN_RUN_INTERVAL_SECONDS` sets all) since the last successful run, from the state file |
| revert cooldown | `REVERT_COOLDOWN_SECONDS` (3600) after a reverted run. two in a row alerts |
| gas cap | base fee plus priority above `MAX_GAS_GWEI` (14) skips, checked again next tick |
| value vs gas | 111 and v2: skip (`below_gas_value`) when what the run moves (eth plus coin at pool spot net of fees) is worth less than typical gas (900k, 1.2M) at base plus priority, unless the weekly timer is due. needs the pool read; without it the thresholds decide |
| funds | skip (`insufficient_funds`) when the key holds less than gas limit x `maxFeePerGas` (the node would refuse the tx) |
| foreign pending | the node's `pending` nonce above `latest` (a tx the state file does not know): nothing is sent, alert |

the weekly timer counts from the last successful run and lives in the state file, so a restart does not re run. a fresh volume has no timers: the first tick runs every keeper once. a simulation that reverts is logged and not sent. a tx still unmined after `RECEIPT_TIMEOUT_SECONDS` (600) stays in flight and later ticks handle it (next section).


note: LAYER already has its own hosted keeper (`layer-keeper` in ripe0x/new-material). deploy this runner with `KEEPERS=111,v2` so the two bots do not race (D64).

## tx in flight

one tx at a time, never a new nonce while one is in flight. the record (keeper, nonce, every hash signed for that nonce, fees, calldata) is written to the state file after signing and before the broadcast, so a crash cannot lose a sent tx, and a restart resumes it.

| case | action |
|---|---|
| a receipt for any of its hashes | settled: run ok (timer, progress check), reverted (cooldown), or the cancel mined (`cancelled`, timer unchanged) |
| unmined after `PENDING_TIMEOUT_SECONDS` (1800) | replaced at the same nonce with the same calldata, fees +12.5% (and at least today's caps), up to `MAX_REPLACEMENTS` (3) and only while the fee stays under `MAX_GAS_GWEI` |
| still stuck after that | a 0 value transfer to self at the same nonce (21,000 gas, fee cap 2 x `MAX_GAS_GWEI`), bumped +12.5% each timeout. above the cap: `stuck_tx` alert, waits |
| nonce used, no receipt for our hashes | looked at for three ticks (lagging rpc), then cleared as `lost` with an alert |
| broadcast error | a definite reject (bad tx, funds) clears the record (`send_error`). a timeout or `nonce too low` keeps it in flight (`send_unknown`), the receipt and nonce checks settle it |

every send and receipt outcome is counted per keeper in the state file (`outcomes`, `lastOutcome`) and in `keeper_tx_outcomes_total{outcome}`: `sent`, `replaced`, `cancel_sent`, `mined_ok`, `mined_reverted`, `cancelled`, `send_error`, `send_unknown`, `replace_error`, `cancel_error`, `lost`.

## quoting

the rpc that simulates is not trusted alone. every convert and burn also needs an independent floor from pool state: `sqrtPriceX96` from `PoolManager.extsload` of the pool's slot0 (RUNBOOK action 5 recipe), the lp fee (the larger of slot0's and the hook's config) and the hook's `skimConfig` baseline skim. `spotNetOut = amountIn * price * (1 - skim - lpFee)`, `minOut = max(simulated * (1 - slippage), spotNetOut * (1 - slippage - MAX_IMPACT_BPS))`, `MAX_IMPACT_BPS` 100. a convert or burn is sent only when that floor is positive and the simulated output clears it; otherwise the run goes without it (`doConvert` / `doBurn` false) and the log says why: `no_quote` (pool read failed or zero), `floor_above_quote` (the simulation returned less than the pool implies: a lying rpc or too much impact), `impact_too_high` (LAYER). never `run(true, 0)`, never a LAYER rate of 0 with burn on.

| keeper | simulation (`eth_call` at the fixed gas limit) | amount for the floor | sent |
|---|---|---|---|
| 111 | `run(true, 0)` returns `(collected, flushed, converted)` | swapper coin plus its locker reward share of the uncollected coin, capped at the swapper's `maxStepIn` (pool key and step from the pinned swapper) | `run(true, minOut)`. nothing converted in the simulation, or no floor: `run(false, 0)` |
| layer | `run(true, 0, false)` returns `(lCol, wCol, lBurn, wBurn, lBought)` | the largest router balance (router0 counts the claims and the controller split it receives). the keeper applies one rate to each router's whole balance, so the rate is quoted for the worst impact: the simulated average rate is cut to that router's constant liquidity estimate | `run(true, rate, true)`. no weth burned in the simulation, impact of the largest balance above `MAX_IMPACT_BPS`, or no floor: `run(false, 0, true)` (collect, claims, splits, LAYER burn only). router 0x0EB2 has no owner floor getter: the keeper passes it 0 whatever the rate (its own 1% impact clamp and 80% spot floor apply) |
| v2 | `collectAndForward(token, true, 0)` through `eth_simulateV1` (outputs in `SwapperServiced` logs) | per swapper (the locker's reward recipients that answer the `IFeeAutoSwapperV2` erc165 probe): its pending coin capped at its `maxStepIn`, at its own pool | the keeper passes one minOut to every swapper. minOut is the largest per swapper floor, and `doConvert` is true only when every converting swapper's simulated output clears it. otherwise `doConvert` false, the log names the blocking swapper; a later run converts once the swappers' steps line up. no `eth_simulateV1`: `doConvert` false |

measured on the fork (block 26130269): 111 simulated 648,951,817,551,513 wei, spot net 648,777,005,312,996, sent minOut 642,462,299,375,997 (the simulation floor). a 0.0204 weth LAYER burn: simulated and constant liquidity rates both 1.60336e25, impact 10 bps, sent rate 1.5713e25, mined without a skipped step 5. the gas limit is fixed, never estimated: the keepers revert `InsufficientGas(step)` on a shortfall.

er.s.sol`, except the two "nothing quoted, do not convert or burn" rules above. the gas limit is fixed, never estimated: the keepers revert `InsufficientGas(step)` on a shortfall.

## deploy on fly.io

prerequisites: the keeper contracts are deployed (RUNBOOK actions 3 and 2b, any wallet, use the hot key) and `flyctl` is logged in. every command runs from the repo root.

```bash
# 1. hot key: a fresh key used only here. never the owner key (the runner refuses 0xCB43...17F9, the payout eoa and every registry owner)
cast wallet new                      # note the address and private key, store the key in a password manager

# 2. app and volume (fly.toml is committed: keep it, do not let launch overwrite it)
fly launch --no-deploy --copy-config --config keeper/fly.toml --name artcoins-keeper --region iad
#    if launch insists on rewriting the config: fly apps create artcoins-keeper
fly volumes create keeper_state --size 1 --region iad --app artcoins-keeper --yes

# 3. secrets (read the key from a file or prompt, not from shell history)
fly secrets set --app artcoins-keeper --stage MAINNET_RPC_URL=https://<keyed mainnet rpc> PRIVATE_RPC_URL=https://rpc.flashbots.net/fast
fly secrets set --app artcoins-keeper --stage STATUS_TOKEN="$(openssl rand -hex 32)"    # bearer for /status and /metrics
printf 'KEEPER_PRIVATE_KEY=%s\n' "$(cat /path/to/hotkey)" | fly secrets import --app artcoins-keeper --stage
# until the keepers are in deployments/mainnet.json (env wins over the registry):
fly secrets set --app artcoins-keeper --stage KEEPER_111=0x<deployed CollectFlushKeeperV1> KEEPER_LAYER=0x<deployed CollectFlushKeeperLayer>

# 4. first deploy as a dry run (simulates and quotes, sends nothing), read the logs, then go live
fly deploy . --config keeper/fly.toml --dockerfile keeper/Dockerfile --ignorefile keeper/.dockerignore --ha=false --env DRY_RUN=1
fly logs --app artcoins-keeper
fly deploy . --config keeper/fly.toml --dockerfile keeper/Dockerfile --ignorefile keeper/.dockerignore --ha=false
fly scale count 1 --app artcoins-keeper --yes      # exactly one machine: two would race on nonces
```

`npm run deploy` in `keeper/` runs the live deploy line. the build context is the repo root because the image copies `deployments/mainnet.json`; `keeper/.dockerignore` keeps the upload to `keeper/` and the registry (never a `keeper/.env*`). the base image is pinned by digest. without `MAINNET_RPC_URL` the runner falls back to the tenderly public gateway, which rate limits: set a keyed rpc. live mode with the 111 keeper refuses to start without `PRIVATE_RPC_URL` (111 must be in `PRIVATE_RPC_KEEPERS`, default all three) unless `ALLOW_PUBLIC_MEMPOOL=1`; reads always go to `MAINNET_RPC_URL`. flashbots protect does not include reverting txs, so a would be revert there shows as a tx in flight that is replaced and then cancelled. the start command refuses a missing `/data` (volume not mounted) unless `EPHEMERAL_STATE=1`.

## fund the key

the node refuses a tx unless `balance >= gas limit x maxFeePerGas`, and `maxFeePerGas` can reach `MAX_GAS_GWEI`. the largest limit is LAYER's, so:

`required balance = 3,500,000 x MAX_GAS_GWEI gwei` (111 only: 1,200,000 x, v2: 2,000,000 x)

| `MAX_GAS_GWEI` | required | note |
|---|---|---|
| 14 (default) | 0.049 eth | fits the 0.05 eth hot key limit. `LOW_BALANCE_ETH` defaults to this figure |
| 30 | 0.105 eth | above the hot key limit: raise `HIGH_BALANCE_ETH` deliberately or keep 14 |
| at today's fees | 3.5M x (2 x base + priority) | what a LAYER send needs at the moment; the runner skips with `insufficient_funds` below it |

| item | value |
|---|---|
| send | `cast send <hot key address> --value 0.05ether --rpc-url $MAINNET_RPC_URL --account <owner keystore>` |
| keep at | the required balance above, under 0.05 eth (the log warns above `HIGH_BALANCE_ETH` 0.05 and below `LOW_BALANCE_ETH`, default the required balance) |
| cost per run | 111 870k gas (fork, block 26130269), LAYER 0.69M without weth burns, 0.93M with one router burn, up to about 1.9M with two reward router burns. at 1 gwei that is 0.0009 eth and 0.0007 to 0.0019 eth. replacements and cancels only ever mine one tx per nonce |
| spend bound | at most one run per keeper per minimum run interval (111 6 h, LAYER 24 h, v2 6 h per coin), less while a backoff holds |
| rewards | the keepers forward every reward to the caller (this key): swapper flush and convert 50 bps capped 0.01 eth, reward routers 0.5%. at current volume runs are owner funded |
| sweep | the key is a plain eoa: move anything above 0.05 eth back by hand |

## logs, status, metrics

| what | how |
|---|---|
| logs | `fly logs --app artcoins-keeper`. one json line per event: `preview` (values and the decision), `quoted` (with the floor detail), `no_quote` / `floor_above_quote` / `impact_too_high`, `sent`, `run ok` (decoded events), `no_progress`, `step skipped` (event, step, decoded reason), `stuck tx replaced` / `cancelled`, `run reverted` / `ALERT ...`, `alert`. logs carry tx hashes; they are private to the fly org |
| health (public) | `curl https://artcoins-keeper.fly.dev/healthz`: `{ok, lastTickAgeSeconds}` only. 503 when no tick finished in 3 intervals plus 2 minutes. the fly check uses it |
| status | `curl -H "authorization: Bearer $STATUS_TOKEN" https://artcoins-keeper.fly.dev/status`: per keeper `lastResult`, `lastRunAt`, `lastTx` (mined only), `nextCheckAt`, `backoffUntil`, `noProgress`, `outcomes`, last preview and quote status, `alerts` (`no_progress`, `consecutive_reverts`, `stuck_tx`, `low_balance`), the tx in flight as keeper, nonce, age and replacement count (never its hash or args). 404 without `STATUS_TOKEN` |
| metrics | same bearer on `/metrics` (prometheus text): `keeper_ticks_total`, `keeper_runs_total`, `keeper_results_total{result}`, `keeper_tx_outcomes_total{outcome}`, `keeper_quote_status_total{status}`, `keeper_no_progress_total`, `keeper_no_progress`, `keeper_backoff_until`, `keeper_replacements_total{kind}`, `keeper_in_flight`, `keeper_pending_age_seconds`, `keeper_insufficient_funds_total`, `keeper_reverts_total`, `keeper_consecutive_reverts`, `keeper_skipped_events_total{event}`, `keeper_gas_cap_skips_total`, `keeper_alerts_total{alert}`, `keeper_key_balance_wei`, `keeper_111_swapper_eth_wei`, `keeper_last_run_timestamp` |
| state | `fly ssh console --app artcoins-keeper -C "cat /data/state.json"`. deleting it forces every keeper to run on the next tick and forgets the tx in flight: do it only with no tx pending (`pending` nonce equals `latest`) |
| private | `/healthz` leaks nothing but liveness. to keep everything off the internet: `fly ips release <ip> --app artcoins-keeper` and `fly proxy 8080:8080 --app artcoins-keeper` |
| restarts | a watchdog exits the process when ticks stop finishing (hung rpc) and fly restarts the machine (`[[restart]] policy = "always"`). the tx in flight survives in the state file and is resumed |

## alert rules

| rule | meaning | action |
|---|---|---|
| `keeper_no_progress{keeper} == 1` (log `no_progress`, `/status` alert) | a successful run did not clear its trigger (weth burn skipped, convert paced or unquoted, flush skipped). the keeper backs off 1 h to 24 h | read the run's `step skipped` reasons and the `quoted` status. LAYER: refresh router floors (RUNBOOK action 5). v2: check `maxStepIn` and pacing |
| `keeper_alerts_total{alert="due_no_burn"}` | a LAYER router is due but the simulation burned nothing (the stale floor case, KR-01b) | router floors (action 5), `SlippageFloorNotSet` |
| `keeper_quote_status_total{status=~"floor_above_quote|no_quote|impact_too_high"}` | the convert or burn was dropped: the rpc's quote is below the pool, the pool read failed, or a router balance is too large for one burn | compare the rpc with a second provider. LAYER: a large router burns once its balance or the pool depth allows, or by hand with a floor |
| `keeper_111_swapper_eth_wei > 0` (log `alert swapper_eth_stranded`) | a third party claimed the swapper's escrow credit (LF-02). that eth is stranded, nothing on chain recovers it | record it. keep the runner going, it shrinks the window |
| `keeper_consecutive_reverts{keeper} >= 2` (log `ALERT two consecutive reverts`) | two runs in a row reverted (reason replayed in the log) | read the reason. `InsufficientGas` means the gas floors moved, re measure. anything else: run the forge script dry run by hand |
| `keeper_replacements_total` growing, `/status` `stuck_tx`, `keeper_alerts_total{alert="stuck_tx"}` | a tx did not mine in 30 minutes and was replaced or cancelled | base fee vs `MAX_GAS_GWEI`; with a relay, check whether it dropped a would be revert |
| `keeper_alerts_total{alert=~"foreign_pending|lost_tx"}` | the node holds a tx from this key the runner did not send, or a nonce was used with no receipt for our txs | something else uses the key: stop it. one key, one runner |
| `keeper_results_total{result="insufficient_funds"}` or `keeper_key_balance_wei` under the required balance | the key cannot cover gas limit x max fee | fund it (previous section) |
| `/healthz` 503 or the fly check critical | the loop stopped | `fly logs`, `fly machine restart` |
| `keeper_skipped_events_total{keeper="layer",event="StepSkipped"}` with step 5 | a weth burn was refused: router floor stale or 0 (`SlippageFloorNotSet`, `MinLayerOutBelowFloor`) | refresh the floors (RUNBOOK action 5) |
| `keeper_results_total{result="gas_cap"}` growing for a day while due | base fee above `MAX_GAS_GWEI` all day | raise `MAX_GAS_GWEI` (and the funding) or wait |
| `keeper_results_total{result="sim_revert"}` growing | the run reverts at simulation (collect failure bubbles) | dry run the forge script, check the locker |

fly has no log based alerting: point any external uptime checker at `/healthz`, and scrape `/metrics` with the bearer token or ship logs (fly log shipper) for the counters.

## add a v2 coin

no code change. in `deployments/mainnet.json`: the v2 stack has a status other than `planned`, `ArtCoinsKeeperV2` is recorded with `stack: "v2"`, and the coin is in `coins` with `stack: "v2"` (RUNBOOK 2b step 8). check with `node script-js/verify-registry.mjs`, commit, redeploy (the registry is copied into the image at build). the runner adds a `v2:<symbol>` keeper per coin. `KEEPER_V2` overrides the keeper address. thresholds are shared: `KV2_MIN_PAIRED_ETH`, `KV2_MIN_COIN`.

## configuration

| env | default | note |
|---|---|---|
| `KEEPER_PRIVATE_KEY` | required | fly secret, removed from the process env after load. refused when it is a registry owner, 0xCB43…17F9, the ui payout 0x41c3…6A4 or `OWNER_ADDRESS`; a registry without `owner` refuses to start |
| `OWNER_ADDRESS` | unset | one more address the key must not be (0xCB43…17F9 is always refused) |
| `MAINNET_RPC_URL` | `https://mainnet.gateway.tenderly.co` | reads, simulations, receipts, sends for keepers not in `PRIVATE_RPC_KEEPERS` |
| `PRIVATE_RPC_URL`, `PRIVATE_RPC_KEEPERS` | unset, `111,layer,v2` | private relay for those keepers' sends, replacements and cancels. entries are validated |
| `ALLOW_PUBLIC_MEMPOOL` | unset | `1` lets live mode send the 111 run without the relay |
| `STATUS_TOKEN` | unset | bearer for `/status` and `/metrics`, at least 16 characters. unset: both 404 |
| `KEEPER_111`, `KEEPER_LAYER`, `KEEPER_V2` | registry | registry contracts named `CollectFlushKeeperV1`, `CollectFlushKeeperLayer`, `ArtCoinsKeeperV2` (role `keeper` preferred, any role accepted) |
| `KEEPERS` | `111,layer,v2` | which keepers run |
| `INTERVAL_SECONDS`, `WEEKLY_SECONDS` | 600, 604800 | loop tick, weekly timer |
| `KEEPER_<ID>_CHECK_INTERVAL_SECONDS`, `CHECK_INTERVAL_SECONDS` | 3600, 86400, 3600 | preview cadence per keeper (`<ID>` is `111`, `LAYER`, `V2`) |
| `KEEPER_<ID>_MIN_RUN_INTERVAL_SECONDS`, `MIN_RUN_INTERVAL_SECONDS` | 21600, 86400, 21600 | minimum spacing of successful runs |
| `PROGRESS_MIN_BPS`, `BACKOFF_MIN_SECONDS`, `BACKOFF_MAX_SECONDS` | 5000, 3600, 86400 | no progress rule and backoff |
| `MAX_GAS_GWEI`, `MAX_PRIORITY_GWEI` | 14, 2 | `maxFeePerGas = min(2 * base + priority, cap)`. sets the funding need |
| `MAX_IMPACT_BPS` | 100 | impact allowance of the spot floor, on top of slippage |
| `KEEPER_SLIPPAGE_BPS`, `KEEPER_111_SLIPPAGE_BPS`, `KEEPER_LAYER_SLIPPAGE_BPS`, `KEEPER_V2_SLIPPAGE_BPS` | 100, 200, 100 | max 1000 |
| `K111_MIN_UNCOLLECTED_ETH`, `K111_MIN_UNCOLLECTED_COIN`, `K111_MAX_ESCROWED_ETH` | 0.02, 10000, 0.05 | decimal amounts |
| `KLAYER_MIN_COMBINED_WETH` | 0.01 | |
| `KV2_MIN_PAIRED_ETH`, `KV2_MIN_COIN` | 0.02, 10000 | |
| `RECEIPT_TIMEOUT_SECONDS`, `PENDING_TIMEOUT_SECONDS`, `MAX_REPLACEMENTS`, `REVERT_COOLDOWN_SECONDS` | 600, 1800, 3, 3600 | |
| `LOW_BALANCE_ETH`, `HIGH_BALANCE_ETH` | required balance, 0.05 | log warnings |
| `STATE_PATH`, `EPHEMERAL_STATE` | `./state.json` (`/data/state.json` on fly), unset | the state dir must exist (volume mounted) unless `EPHEMERAL_STATE=1` |
| `PORT`, `DRY_RUN` | 8080, live | `DRY_RUN`: anything but unset, empty, `0` or `false` is a dry run |
| `REGISTRY_PATH` | `../deployments/mainnet.json` | |

## develop

```bash
cd keeper && npm ci && npm test        # 70 tests; the fork test skips without MAINNET_RPC_URL, the anvil test without anvil
MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co npm test    # adds the anvil fork test at block 26130269 (needs anvil, cast, built artifacts): both runs, the pool floors and a 0.02 weth LAYER burn
forge build --skip "test/**" --skip script && npm run gen:abi    # regenerate abi/ after a keeper contract change
node scripts/gen-abi.mjs --check                                  # committed abis match the artifacts
docker build -f keeper/Dockerfile -t artcoins-keeper .            # from the repo root
```

| file | role |
|---|---|
| `index.mjs` | entry: server, preflight (chain id, keeper code), loop, watchdog, sigterm |
| `config.mjs` | registry and env |
| `decide.mjs` | thresholds, weekly timer, gas cap, quote and pool floor math, progress and backoff (pure) |
| `runner.mjs` | one tick: tx in flight (settle, replace, cancel), cadence gates, quote, send |
| `chain.mjs` | viem reads, pool reads (extsload, skimConfig), simulations, signing, raw sends with retry, cancels, receipts |
| `events.mjs` | event and revert decoding |
| `state.mjs` | atomic json state |
| `server.mjs`, `metrics.mjs`, `log.mjs` | public `/healthz`, token guarded `/status` and `/metrics`, json logs |
