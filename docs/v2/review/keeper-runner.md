# keeper runner (k4, hosted on fly.io)

package k4. `keeper/` is a node 22 service (viem only) that runs the three keeper contracts on a schedule: `CollectFlushKeeperV1` (111, RUNBOOK action 3), `CollectFlushKeeperLayer` (LAYER, action 2b) and `ArtCoinsKeeperV2` (every v2 coin in the registry, part 2 2b). operator guide: `keeper/README.md`. this file is the design and test record.

## what a tick does

| step | detail |
|---|---|
| 1 in flight | a tx recorded in the state file is settled first: receipt found, nonce used by something else (cleared), older than `DROP_AFTER_SECONDS` 1800 (cleared), else the whole tick is skipped. one tx in flight at a time |
| 2 gas | latest base fee plus capped priority (`MAX_PRIORITY_GWEI` 2) above `MAX_GAS_GWEI` 30: every due keeper is skipped this tick. else `maxFeePerGas = min(2 * base + priority, cap)` |
| 3 read | `preview()` per keeper. LAYER adds `weth.balanceOf(controller)` for the combined rule (weth and controller read from the keeper's own getters) |
| 4 decide | thresholds below, weekly timer from the last successful run, `REVERT_COOLDOWN_SECONDS` 3600 after a revert |
| 5 quote | `eth_call` of the run with minOut or rate 0 at the fixed gas limit, then slippage. a simulation revert is decoded and logged, nothing is sent |
| 6 send | signed locally, raw send (resending the same bytes is idempotent, so 429 and 5xx retries are safe), private relay for 111 when `PRIVATE_RPC_URL` is set |
| 7 receipt | waits up to `RECEIPT_TIMEOUT_SECONDS` 600. success: timer reset, events decoded and logged. revert: counted, reason replayed at the parent block, never resent in the tick. timeout: stays in flight, the tick ends |
| 8 state | json at `STATE_PATH` (fly volume), temp file plus fsync plus rename after every change. a corrupt or foreign version file stops the process instead of starting empty (empty would re run every keeper) |

## decisions

| keeper | run when (any) | gas limit | slippage |
|---|---|---|---|
| 111 | `uncollectedEth > 0.02 eth`, `uncollectedCoin > 10,000e18`, `escrowedEth > 0.05 eth`, weekly. `swapperEth > 0` is an alert only | 1,200,000 | 100 bps |
| LAYER | any router with `routerWeth[i] > 0` and `>= routerThreshold[i]`, `routerWeth[0] + claimable[3] + 0.4 * (claimable[1] + controllerWeth) >= 0.01 weth`, weekly | 3,500,000 | 200 bps |
| v2 coin | `accruedPaired > 0.02 eth`, `accruedArtCoin > 10,000e18`, weekly | 2,000,000 | 100 bps |

every threshold is an env override. gas limits are constants (not env): the keepers revert `InsufficientGas` on a shortfall by design (D49) and an estimate would hide that.

the `routerWeth[i] > 0` guard is an addition: a router whose threshold reads 0 would otherwise trigger every tick. the runbook's "skip when pending is below gas cost" rule is covered by the thresholds and the gas cap; no price feed is used.

## quoting and deviations from the forge scripts

| keeper | simulation | sent | deviation from `RunKeeper111` / `RunKeeperLayer` |
|---|---|---|---|
| 111 | `run(true, 0)`, returns `converted` | `run(true, converted * (1 - bps))` | simulated `converted == 0` sends `run(false, 0)`. the script sends `run(true, 0)`, which leaves only the swapper's 80% of spot floor if the convert becomes possible between quote and inclusion |
| LAYER | `run(true, 0, false)`, returns `wBurn, lBought` | `run(true, lBought * 1e18 / wBurn * (1 - bps), true)` | simulated `wBurn == 0` sends `run(false, 0, true)`. the script sends `doBurn` true with rate 0 (router floors only) |
| v2 | `collectAndForward(token, true, 0)` via `eth_simulateV1`, `SwapperServiced.converted` | `minOut` = smallest nonzero convert minus bps | no forge script exists. `collectAndForward` returns nothing, so the quote needs the logs. an rpc without `eth_simulateV1` gets `doConvert` false (logged) |

## failure handling

| case | behavior |
|---|---|
| 429, 5xx, timeouts | viem transport retries (3, 1s) plus an outer backoff (4 retries, 1s doubling, jitter). revert errors are never classed transient |
| simulation revert | decoded (`InsufficientGas(step: name)`, downstream errors from `abi/reasons.json`, `Error(string)`), `sim_revert`, nothing sent |
| tx reverted | `consecutiveReverts += 1`, reason replayed with `eth_call` at the parent block (best effort), cooldown 1h. two in a row logs `ALERT two consecutive reverts` |
| skip events | `FlushSkipped`, `ConvertSkipped` (111 and v2), `StepSkipped(step, target)` (LAYER) decoded with their reason. idle reasons (`NothingToFlush`, `NothingToConvert`, `ConvertTooEarly`) log at info, the rest at warn. all counted in `keeper_skipped_events_total` |
| hung loop | watchdog exits the process when no tick finished in `max(3 * interval, receipt timeout + 2 * interval) + 300` seconds; fly restarts it (`[[restart]] policy = "always"`) |
| owner key | refused at start when the key's address equals the registry `owner` or any contract `owner` field (0xCB43…17F9) |
| missing keeper address | logged as `no_address` per tick, the other keepers run |

## tests

`cd keeper && npm ci && npm test`: 41 tests, 8 files. without `MAINNET_RPC_URL` the fork test skips; without anvil on PATH the local anvil test skips (the ci `keeper` job runs the 39 others).

| file | tests | covers |
|---|---|---|
| `decide.test.mjs` | 13 | each 111 threshold (strict `>`), stranded eth alert, weekly timer, LAYER router threshold, zero threshold guard, combined rule at the exact 0.01 boundary, v2 thresholds, gas cap skip and fee caps, min out and rate math against the forge script formulas, v2 quote |
| `events.test.mjs` | 5 | abi decode of `FlushSkipped`, `ConvertSkipped`, `StepSkipped` with reasons (`NothingToFlush`, `ConvertTooEarly(n)`, `SlippageFloorNotSet`, `V4TooLittleReceived`), `SwapperServiced`, `InsufficientGas(step)`, unknown and empty reverts, logs from other addresses ignored |
| `state.test.mjs` | 3 | round trip with bigints and the tx in flight, atomic write, corrupt and wrong version files refuse to load |
| `config.test.mjs` | 5 | defaults, env overrides and bounds, owner key refusal, registry lookup by name with env override and ambiguity error, v2 skipped without a deployed v2 stack and one keeper per v2 coin |
| `runner.test.mjs` | 12 | fake io: first start runs both keepers with quoted args, restart on the same state does not re run, threshold runs one keeper, gas cap skip, revert not retried plus cooldown plus two in a row alert plus reset, simulation revert, no unquoted convert or burn, receipt timeout across a restart, dropped tx, skip events counted, dry run, missing address, healthz staleness |
| `server.test.mjs` | 1 | http `/healthz` 200 and 503, `/metrics`, 404 |
| `v2-sim.test.mjs` | 1 | local anvil (no fork): a stand in contract emitting `SwapperServiced` quoted through `eth_simulateV1` by the real io; a stand in reverting `InsufficientGas(3)` surfaces as a decoded simulation revert on the v2, 111 and LAYER paths |
| `integration.test.mjs` | 1 | anvil fork at 26130269, both keepers deployed with `cast send --create` from the foundry artifacts (constructor args from the registry), fresh hot key funded 0.04 eth. one tick through the real io: both runs mined with status 1, gas limits 1.2M and 3.5M on the txs, keepers hold 0 eth after, second tick idle, restart on the state file sends nothing |

## measured on the fork (block 26130269)

| item | value |
|---|---|
| 111 decision | `uncollectedCoin` 13,404.198e18 (threshold and weekly) |
| 111 quote | simulated convert 648,951,817,551,513 wei, sent `run(true, 642,462,299,375,997)` |
| 111 run | 869,690 gas, `FlushSkipped(NothingToFlush)`, `KeeperRun` converted 648,951,817,551,513 (the quote converted). above the 799k in keeper-111.md: the 1.2M limit still has 330k headroom |
| LAYER decision | weekly only (every router under 0.01 weth, combined 0.00038 weth) |
| LAYER quote | simulation burned no weth, sent `run(false, 0, true)` |
| LAYER run | 686,184 gas: collected 403.5 LAYER, burned 2,141.5 LAYER directly (controller and router slots claimed and split) |
| after | 111 `uncollectedCoin` 67e18 (the convert's own swap fee), LAYER claimable all 0 |
| test time | about 30 s against the tenderly gateway |

## image

`keeper/Dockerfile` (node:22-alpine, build context the repo root, copies `keeper/*.mjs`, `keeper/abi`, the lockfile install with `--omit=dev --ignore-scripts` and `deployments/mainnet.json`). the process runs as `node`: the start command chowns the state dir on the root owned fly volume and drops privileges with busybox `su` (pid 1 is node, sigterm reaches it). built and run locally against an anvil fork: both runs mined, state written by `node` on the volume, graceful stop on sigterm. the local build needed two sandbox only changes that are not committed: the base image from the public ecr mirror (docker hub answered 429) and the sandbox proxy ca for `npm ci`.

## not tested

| item | why |
|---|---|
| fly.io itself (`fly launch`, volumes, secrets, checks, restart policy, `[build] ignorefile`, the `--ignorefile` and `--env` flags) | no fly account here. commands follow current flyctl docs from memory; verify on the first deploy |
| private relay (flashbots protect) | no relay reachable with a test key. the code path is the same raw send to a different url |
| `eth_simulateV1` on the production rpc | anvil supports it (tested). the tenderly gateway answered 429 to the probe. a keyed provider without it makes v2 runs skip convert (logged) |
| v2 against a real v2 stack | none deployed. covered by the stand in contract and the unit tests |
| weth burns through the runner | no router was due at the pin. the LAYER rate math is unit tested against the script formula and the keeper's burn path is proved in `test/v2/KeeperLayer.fork.t.sol` |
| a reverted run and an in flight timeout on chain | covered with the fake io only |

## open items for the director

| item | detail |
|---|---|
| registry role `keeper` | `script-js/verify-registry.mjs` ROLES has no `keeper`, so recording the two keepers with role `keeper` fails the schema check. the runner matches by name and prefers role `keeper` but accepts any role: record them as `other` today, or add `keeper` to ROLES (outside k4 scope) |
| keeper addresses | until recorded, `KEEPER_111` and `KEEPER_LAYER` env (fly secrets) override |
| app name and region | `artcoins-keeper`, `iad` in `keeper/fly.toml`. change before `fly launch` if taken |
| public health endpoint | `[http_service]` exposes `/healthz` and `/metrics` at `<app>.fly.dev` (chain public data only). release the ips and use `fly proxy` to keep it private |
