# artcoins keeper runner

hosted loop for the three keeper contracts. every `INTERVAL_SECONDS` (600) it reads each keeper's `preview()`, decides per the runbook thresholds, quotes min out by simulating the run with 0, sends one tx at a time with a fixed gas limit, waits for the receipt and logs every skipped step. node 22, viem, nothing else. runs on one fly.io machine with a 1 gb volume for state.

| keeper | contract | runbook | call | gas limit | slippage default |
|---|---|---|---|---|---|
| `111` | `CollectFlushKeeperV1` | part 1 action 3 | `run(doConvert, minOut)` 0x02143aa9 | 1,200,000 | 100 bps |
| `layer` | `CollectFlushKeeperLayer` | part 1 action 2b | `run(doBurn, rate, unwrap)` 0xc2e8c918 | 3,500,000 | 200 bps |
| `v2:<symbol>` | `ArtCoinsKeeperV2`, one per registry coin with `stack: "v2"` | part 2, 2b keeper table | `collectAndForward(token, doConvert, minOut)` 0x4f4b6733 | 2,000,000 | 100 bps |

## when it runs

| keeper | runs when (any) | alert, not a trigger |
|---|---|---|
| 111 | `uncollectedEth > 0.02 eth`, `uncollectedCoin > 10,000e18`, `escrowedEth > 0.05 eth`, weekly timer | `swapperEth > 0` |
| layer | any `routerWeth[i] > 0` and `>= routerThreshold[i]`, `routerWeth[0] + claimable[3] + 0.4 * (claimable[1] + controller weth) >= 0.01 weth`, weekly timer | |
| v2 coin | `accruedPaired > 0.02 eth`, `accruedArtCoin > 10,000e18`, weekly timer (uncollected lp fees are not readable on v2, the timer collects them) | |

the weekly timer counts from the last successful run and lives in the state file, so a restart does not re run. a fresh volume has no timers: the first tick runs every keeper once.

skips: base fee plus priority above `MAX_GAS_GWEI` (30) skips every due keeper for that tick. a reverted run is never retried in the same tick and the keeper waits `REVERT_COOLDOWN_SECONDS` (3600). a simulation that reverts is logged and not sent. a tx still unmined after `RECEIPT_TIMEOUT_SECONDS` (600) stays in flight (recorded in the state file) and the next ticks wait for it, give up after `DROP_AFTER_SECONDS` (1800) or when its nonce is used.

## quoting

| keeper | simulation (`eth_call` at the fixed gas limit) | sent |
|---|---|---|
| 111 | `run(true, 0)` returns `(collected, flushed, converted)` | `run(true, converted * (10000 - bps) / 10000)`. a simulation that converts nothing sends `run(false, 0)`, never an unquoted convert |
| layer | `run(true, 0, false)` returns `(lCol, wCol, lBurn, wBurn, lBought)` | `run(true, lBought * 1e18 / wBurn * (10000 - bps) / 10000, true)`. no weth burned in the simulation sends `run(false, 0, true)` (collect, claims, splits, LAYER burn only) |
| v2 | `collectAndForward(token, true, 0)` through `eth_simulateV1` (it returns nothing, the outputs are in `SwapperServiced` logs) | `minOut` = smallest nonzero simulated convert minus bps (one minOut goes to every swapper). an rpc without `eth_simulateV1` sends `doConvert` false |

same math as `script/v2/RunKeeper111.s.sol` and `RunKeeperLayer.s.sol`, except the two "nothing quoted, do not convert or burn" rules above. the gas limit is fixed, never estimated: the keepers revert `InsufficientGas(step)` on a shortfall.

## deploy on fly.io

prerequisites: the keeper contracts are deployed (RUNBOOK actions 3 and 2b, any wallet, use the hot key) and `flyctl` is logged in. every command runs from the repo root.

```bash
# 1. hot key: a fresh key used only here. never the owner key (the runner refuses 0xCB43...17F9 and every registry owner)
cast wallet new                      # note the address and private key, store the key in a password manager

# 2. app and volume (fly.toml is committed: keep it, do not let launch overwrite it)
fly launch --no-deploy --copy-config --config keeper/fly.toml --name artcoins-keeper --region iad
#    if launch insists on rewriting the config: fly apps create artcoins-keeper
fly volumes create keeper_state --size 1 --region iad --app artcoins-keeper --yes

# 3. secrets (read the key from a file or prompt, not from shell history)
fly secrets set --app artcoins-keeper --stage MAINNET_RPC_URL=https://<keyed mainnet rpc> PRIVATE_RPC_URL=https://rpc.flashbots.net/fast
printf 'KEEPER_PRIVATE_KEY=%s\n' "$(cat /path/to/hotkey)" | fly secrets import --app artcoins-keeper --stage
# until the keepers are in deployments/mainnet.json (env wins over the registry):
fly secrets set --app artcoins-keeper --stage KEEPER_111=0x<deployed CollectFlushKeeperV1> KEEPER_LAYER=0x<deployed CollectFlushKeeperLayer>

# 4. first deploy as a dry run (simulates and quotes, sends nothing), read the logs, then go live
fly deploy . --config keeper/fly.toml --dockerfile keeper/Dockerfile --ignorefile keeper/.dockerignore --ha=false --env DRY_RUN=1
fly logs --app artcoins-keeper
fly deploy . --config keeper/fly.toml --dockerfile keeper/Dockerfile --ignorefile keeper/.dockerignore --ha=false
fly scale count 1 --app artcoins-keeper --yes      # exactly one machine: two would race on nonces
```

`npm run deploy` in `keeper/` runs the live deploy line. the build context is the repo root because the image copies `deployments/mainnet.json`; `keeper/.dockerignore` keeps the upload to `keeper/` and the registry. without `MAINNET_RPC_URL` the runner falls back to the tenderly public gateway, which rate limits: set a keyed rpc. `PRIVATE_RPC_URL` is optional; when set the 111 run goes through it (`PRIVATE_RPC_KEEPERS`, default `111`) and every read goes to `MAINNET_RPC_URL`. flashbots protect does not include reverting txs, so a would be revert there shows as a tx in flight that is dropped after 30 minutes.

## fund the key

| item | value |
|---|---|
| send | `cast send <hot key address> --value 0.03ether --rpc-url $MAINNET_RPC_URL --account <owner keystore>` |
| keep under | 0.05 eth (the log warns above `HIGH_BALANCE_ETH` 0.05 and below `LOW_BALANCE_ETH` 0.005) |
| cost per run | 111 870k gas (fork, block 26130269), LAYER 0.69M without weth burns up to about 1.9M with two reward router burns. at 1 gwei that is 0.0009 eth and 0.0007 to 0.0019 eth |
| rewards | the keepers forward every reward to the caller (this key): swapper flush and convert 50 bps capped 0.01 eth, reward routers 0.5%. at current volume runs are owner funded |
| sweep | the key is a plain eoa: move anything above 0.05 eth back by hand |

## logs, health, metrics

| what | how |
|---|---|
| logs | `fly logs --app artcoins-keeper`. one json line per event: `preview` (values and the decision), `quoted`, `sent`, `run ok` (decoded events), `step skipped` (event, step, decoded reason), `run reverted` / `ALERT two consecutive reverts`, `alert` |
| health | `fly checks list --app artcoins-keeper`, or `curl https://artcoins-keeper.fly.dev/healthz`: 200 with `lastTickAt`, per keeper `lastResult`, `lastRunAt`, `lastTx`, `consecutiveReverts`, last preview. 503 when no tick finished in 3 intervals plus 2 minutes |
| metrics | `curl https://artcoins-keeper.fly.dev/metrics` (prometheus text): `keeper_ticks_total`, `keeper_runs_total`, `keeper_results_total{result}`, `keeper_reverts_total`, `keeper_consecutive_reverts`, `keeper_skipped_events_total{event}`, `keeper_gas_cap_skips_total`, `keeper_alerts_total{alert}`, `keeper_key_balance_wei`, `keeper_111_swapper_eth_wei`, `keeper_last_run_timestamp` |
| state | `fly ssh console --app artcoins-keeper -C "cat /data/state.json"`. delete it only to force every keeper to run on the next tick |
| private | `/healthz` and `/metrics` show only chain public data (hot key address, balances, previews). to keep them off the internet: `fly ips release <ip> --app artcoins-keeper` and use `fly proxy 8080:8080 --app artcoins-keeper` |
| restarts | a watchdog exits the process when ticks stop finishing (hung rpc) and fly restarts the machine (`[[restart]] policy = "always"`). a tx in flight survives in the state file |

## alert rules

| rule | meaning | action |
|---|---|---|
| `keeper_111_swapper_eth_wei > 0` (log `alert swapper_eth_stranded`) | a third party claimed the swapper's escrow credit (LF-02). that eth is stranded, nothing on chain recovers it | record it. keep the runner going, it shrinks the window |
| `keeper_consecutive_reverts{keeper} >= 2` (log `ALERT two consecutive reverts`) | two runs in a row reverted (reason replayed in the log) | read the reason. `InsufficientGas` means the gas floors moved, re measure. anything else: run the forge script dry run by hand |
| `/healthz` 503 or the fly check critical | the loop stopped | `fly logs`, `fly machine restart` |
| `keeper_key_balance_wei < 5e15` | key nearly empty, runs will fail to send | fund it (0.03 eth) |
| `keeper_skipped_events_total{keeper="layer",event="StepSkipped"}` with step 5 | a weth burn was refused: router floor stale or 0 (`SlippageFloorNotSet`, `MinLayerOutBelowFloor`) | refresh the floors (RUNBOOK action 5) |
| `keeper_results_total{result="gas_cap"}` growing for a day while due | base fee above `MAX_GAS_GWEI` all day | raise `MAX_GAS_GWEI` with `fly secrets set` or wait |
| `keeper_results_total{result="sim_revert"}` growing | the run reverts at simulation (collect failure bubbles) | dry run the forge script, check the locker |
| a LAYER router at or above 0.01 weth for more than a day (healthz preview) | RUNBOOK gate 9b | check floors and the step 5 reasons |

fly has no log based alerting: point any external uptime checker at `/healthz`, and scrape `/metrics` or ship logs (fly log shipper) for the counters.

## add a v2 coin

no code change. in `deployments/mainnet.json`: the v2 stack has a status other than `planned`, `ArtCoinsKeeperV2` is recorded with `stack: "v2"`, and the coin is in `coins` with `stack: "v2"` (RUNBOOK 2b step 8). check with `node script-js/verify-registry.mjs`, commit, redeploy (the registry is copied into the image at build). the runner adds a `v2:<symbol>` keeper per coin. `KEEPER_V2` overrides the keeper address. thresholds are shared: `KV2_MIN_PAIRED_ETH`, `KV2_MIN_COIN`.

## configuration

| env | default | note |
|---|---|---|
| `KEEPER_PRIVATE_KEY` | required | fly secret. refused when it is a registry owner |
| `MAINNET_RPC_URL` | `https://mainnet.gateway.tenderly.co` | reads, simulations, receipts, sends for keepers not in `PRIVATE_RPC_KEEPERS` |
| `PRIVATE_RPC_URL`, `PRIVATE_RPC_KEEPERS` | unset, `111` | private relay for those keepers' sends |
| `KEEPER_111`, `KEEPER_LAYER`, `KEEPER_V2` | registry | registry contracts named `CollectFlushKeeperV1`, `CollectFlushKeeperLayer`, `ArtCoinsKeeperV2` (role `keeper` preferred, any role accepted) |
| `KEEPERS` | `111,layer,v2` | which keepers run |
| `INTERVAL_SECONDS`, `WEEKLY_SECONDS` | 600, 604800 | |
| `MAX_GAS_GWEI`, `MAX_PRIORITY_GWEI` | 30, 2 | `maxFeePerGas = min(2 * base + priority, cap)` |
| `KEEPER_SLIPPAGE_BPS`, `KEEPER_111_SLIPPAGE_BPS`, `KEEPER_LAYER_SLIPPAGE_BPS`, `KEEPER_V2_SLIPPAGE_BPS` | 100, 200, 100 | max 1000 |
| `K111_MIN_UNCOLLECTED_ETH`, `K111_MIN_UNCOLLECTED_COIN`, `K111_MAX_ESCROWED_ETH` | 0.02, 10000, 0.05 | decimal amounts |
| `KLAYER_MIN_COMBINED_WETH` | 0.01 | |
| `KV2_MIN_PAIRED_ETH`, `KV2_MIN_COIN` | 0.02, 10000 | |
| `RECEIPT_TIMEOUT_SECONDS`, `DROP_AFTER_SECONDS`, `REVERT_COOLDOWN_SECONDS` | 600, 1800, 3600 | |
| `LOW_BALANCE_ETH`, `HIGH_BALANCE_ETH` | 0.005, 0.05 | log warnings |
| `STATE_PATH`, `PORT`, `DRY_RUN` | `./state.json` (`/data/state.json` on fly), 8080, off | |
| `REGISTRY_PATH` | `../deployments/mainnet.json` | |

## develop

```bash
cd keeper && npm ci && npm test        # unit tests; the fork test skips without MAINNET_RPC_URL, the anvil test without anvil
MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co npm test    # adds the anvil fork test at block 26130269 (needs anvil, cast, built artifacts)
forge build --skip "test/**" --skip script && npm run gen:abi    # regenerate abi/ after a keeper contract change
node scripts/gen-abi.mjs --check                                  # committed abis match the artifacts
docker build -f keeper/Dockerfile -t artcoins-keeper .            # from the repo root
```

| file | role |
|---|---|
| `index.mjs` | entry: server, preflight (chain id, keeper code), loop, watchdog, sigterm |
| `config.mjs` | registry and env |
| `decide.mjs` | thresholds, weekly timer, gas cap, quote math (pure) |
| `runner.mjs` | one tick |
| `chain.mjs` | viem reads, simulations, signing, raw sends with retry, receipts |
| `events.mjs` | event and revert decoding |
| `state.mjs` | atomic json state |
| `server.mjs`, `metrics.mjs`, `log.mjs` | `/healthz`, `/metrics`, json logs |
