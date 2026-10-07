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

## fixes (review KR-01 to KR-14)

response to `docs/v2/review/keeper-runner-review.md`. all 14 findings fixed. the tables above describe the first version; where they differ, this section wins (cadence, `DROP_AFTER_SECONDS` is gone, `/healthz` is liveness only, `MAX_GAS_GWEI` default 14, `PRIVATE_RPC_KEEPERS` default all three). operator detail: `keeper/README.md`.

| id | fix | where | proof |
|---|---|---|---|
| KR-01 | per keeper `MIN_RUN_INTERVAL_SECONDS` from the state file (111 6 h, LAYER 24 h, v2 6 h). after a successful run the preview is read again: every threshold metric that triggered the run must drop by `PROGRESS_MIN_BPS` (5000) of its value at send time, else `no_progress` (log, `keeper_no_progress_total`, `/status` alert) and a backoff doubling 1 h to 24 h. backoff and minimum interval gate before anything else, the weekly timer never overrides them. a run with progress clears the backoff | `runner.mjs` gates and `checkProgress`, `decide.mjs` `triggerMetrics`, `progressMade`, `nextBackoff` | review tests `KR-01` x4: LAYER 36 txs in 6 h is now 1 (5 in 4 days, every gap at least 24 h), v2 no `eth_simulateV1` 6 an hour is now 1 (4 a day), v2 paced 90 a day is now 4, backoff gaps 1, 2, 4, 8, 16, 24, 24 h with the weekly timer due every tick |
| KR-01b | "due, the simulation burned nothing" is its own alert `due_no_burn` and quote status `no_burn`; the run itself then backs off through KR-01 | `runner.mjs` | review test `KR-01 LAYER` |
| KR-02 | independent floor from pool state: `sqrtPriceX96` from `PoolManager.extsload` of the pool slot (slot 6 mapping, as RUNBOOK action 5), lp fee the larger of slot0's and the hook's (`skimConfig`, legacy `artCoinFee` / `pairedFee`), skim the `skimConfig` baseline. `spotNetOut = amountIn * price * (1 - skim - lpFee)`, `minOut = max(sim * (1 - slip), spotNetOut * (1 - slip - MAX_IMPACT_BPS))`, `MAX_IMPACT_BPS` 100. convert or burn only when that floor is positive and the simulated output clears it, else `doConvert` / `doBurn` false with `no_quote` or `floor_above_quote`. 111 amount: swapper coin plus its locker reward share of uncollected coin, capped at the pinned swapper's `maxStepIn`; pool key from `swapper.poolKey()` | `chain.mjs` `market`, `readPool`, `decide.mjs` `floorQuote`, `args111`, `argsLayer` | review test `KR-02` (1 wei quote sends `run(false, 0)` and `run(false, 0, true)`; no pool read: no convert; honest quote converts at the sim floor), decide tests `KR-02` x2, fork: spot net 648,777,005,312,996 vs simulated 648,951,817,551,513 (0.03% apart), sent minOut unchanged at 642,462,299,375,997 |
| KR-03 | v2 per swapper: swappers are the locker's reward recipients answering the `IFeeAutoSwapperV2` erc165 probe (0x08ce5e71); each gets a floor from its pending coin capped at its `maxStepIn` at its own pool. minOut is the largest floor; `doConvert` true only when every converting swapper's simulated output clears it, else false with `blockedBy`. a later run converts once the swappers' steps line up | `decide.mjs` `argsV2`, `chain.mjs` `market` (v2) | review test `KR-03`, decide test `KR-03` |
| KR-04 | the tx in flight keeps nonce, every hash signed for it, fees and calldata in the state file. after `PENDING_TIMEOUT_SECONDS` (1800) a same nonce replacement at +12.5% fees (and at least today's caps) with the same calldata, up to `MAX_REPLACEMENTS` (3) while under `MAX_GAS_GWEI`, then a 0 value self transfer at the same nonce (cap 2 x `MAX_GAS_GWEI`, re bumped each timeout). any hash mining settles it (a mined cancel is `cancelled`). new txs sign at the `latest` nonce and nothing is sent while the node's `pending` nonce is ahead (`foreign_pending`). a restart resumes from the state file | `runner.mjs` `resolveInFlight`, `replaceOrCancel`; `chain.mjs` `send(..., {nonce})`, `cancel` | review tests `KR-04` x2 and runner test `KR-04 at the fee cap` (9 stacked nonces is now one nonce: run, 3 replacements, cancels, each fee +12.5%, one pool entry; restart resumes at replacement 3; an earlier replacement mining settles the run with the first send's time), runner test `foreign pending` |
| KR-05 | `/healthz` returns `{ok, lastTickAgeSeconds}` only. `/status` (detail, alerts) and `/metrics` need `authorization: Bearer $STATUS_TOKEN` and 404 without the secret. the tx in flight shows keeper, nonce, age, replacement count, never hash or args; `lastTx` is set only when mined | `server.mjs` | review test `KR-05`, server tests x2 |
| KR-06 | funding need stated as `3,500,000 x MAX_GAS_GWEI`; `MAX_GAS_GWEI` default 30 to 14 so the need (0.049 eth) fits the 0.05 eth hot key; `LOW_BALANCE_ETH` defaults to it; a send the key cannot cover (`gas limit x maxFeePerGas > balance`) is skipped as `insufficient_funds`, not a `send_error` every tick | `config.mjs`, `runner.mjs`, README, RUNBOOK 2b and 3 hosted runner rows | runner test `KR-06`, config defaults test |
| KR-07 | `DRY_RUN`: anything but unset, empty, `0` or `false` (trimmed, any case) is dry | `config.mjs` `parseDryRun` | review test `KR-07`, config test `KR-07` |
| KR-08 | live mode with 111 enabled refuses to start unless `PRIVATE_RPC_URL` is set with 111 in `PRIVATE_RPC_KEEPERS`, or `ALLOW_PUBLIC_MEMPOOL=1`. `PRIVATE_RPC_KEEPERS` defaults to all three and unknown entries fail. preflight warns when every send is public | `config.mjs`, `app.mjs` | config test `KR-08` |
| KR-09 | refusal list: registry owners plus 0xCB43…17F9 and the payout eoa 0x41c3…6A4 built in, plus `OWNER_ADDRESS`. a registry without `owner` refuses to start | `config.mjs` `ownerAddresses` | config test `KR-09` |
| KR-10 | the state dir must exist at start (volume mounted) unless `EPHEMERAL_STATE=1`; the image start command no longer creates it (it exits with a message), node checks again | `state.mjs` `checkStateDir`, `app.mjs`, `Dockerfile` | state test `KR-10`, review test `KR-13`, start command exercised with `sh` |
| KR-11 | (a) nonce used without a receipt: looked at for three ticks, then `lost` with an alert. (b) the record is written after signing and before the broadcast; a timeout or `nonce too low` keeps it in flight (`send_unknown`), a definite reject clears it. (c) follows from (b). every outcome (`sent`, `replaced`, `cancel_sent`, `mined_ok`, `mined_reverted`, `cancelled`, `send_error`, `send_unknown`, `replace_error`, `cancel_error`, `lost`) counted per keeper in state and `keeper_tx_outcomes_total` | `runner.mjs` `outcome`, `chain.mjs` `broadcast` | runner tests `nonce used without a receipt`, `KR-11` |
| KR-12 | the rate is quoted for the largest router balance (router0 counts its incoming claims and split): the simulated average rate is cut to that balance's constant liquidity estimate (pool liquidity from `extsload`), and a balance whose estimated impact exceeds `MAX_IMPACT_BPS` is not burned (`impact_too_high`) | `decide.mjs` `argsLayer`, `inRangeOut` | decide test `KR-12`; fork: 0.0204 weth on router0, simulated and estimated rates both 1.60336e25 (equal to the wei), impact 10 bps, sent rate 1.5713e25, burn mined with no step 5 skip |
| KR-13 | base image pinned `node:22-alpine@sha256:0a7108bf…2e402` (docker hub, 2026-10-06); `keeper/.env*` in `.dockerignore`; an invalid key fails with a fixed message; `KEEPER_PRIVATE_KEY` deleted from `process.env` after load | `Dockerfile`, `.dockerignore`, `config.mjs`, `app.mjs` | review test `KR-13`, config test `KR-13` |
| KR-14 | cadence per the runbook rows: preview read 111 hourly, LAYER daily, v2 hourly (`KEEPER_<ID>_CHECK_INTERVAL_SECONDS`), the loop still ticks every 10 min for the tx in flight. value vs gas: a 111 or v2 threshold run worth less than typical gas (900k, 1.2M) at base plus priority is skipped unless the weekly timer is due (needs the pool read to price coin) | `config.mjs`, `runner.mjs`, `decide.mjs` `pendingValueWei` | runner tests `KR-14` x2 |

### runs

| run | result |
|---|---|
| `cd keeper && npm ci && npm test` (with `MAINNET_RPC_URL`, anvil on PATH) | 70 pass, 0 fail, 0 skipped (49 before plus 21 new). the 8 review tests are flipped (one became 3 KR-01 tests plus a backoff test, KR-04 got a restart test, KR-13 added) |
| `npm audit --omit=dev` | 0 vulnerabilities, viem 2.57.3 unchanged, no new dependency |
| anvil fork, block 26130269 | both keepers deployed, one tick: 111 `run(true, 642,462,299,375,997)` mined (869,690 gas), progress ok, LAYER `run(false, 0, true)` (`no_burn`) mined (686,184 gas); second tick and restart send nothing (`wait`); then 0.02 weth on router0, `run(true, 1.5713e25, true)` mined (930,052 gas), 0.0204 weth burned for 326,788 LAYER, progress ok |

### not verified

| item | why |
|---|---|
| v2 pool reads on chain (`deploymentInfo`, `rewardRecipients`, erc165 probe, swapper getters) | no v2 stack deployed. the floor math is unit tested; the read path follows the frozen interfaces |
| flashbots protect handling of same nonce replacements and cancels | no relay reachable with a test key |
| docker build with the pinned digest, fly volume and restart behaviour | no docker daemon, no fly account here. the start command was run with `sh` for both branches |
| dynamic lp fee overrides by a hook beyond slot0 and `skimConfig` | the floor takes the larger known fee; a hook charging more per swap would make the floor too high, which drops the convert (safe direction) and shows as `floor_above_quote` |
