# artcoins v2: handoff to the local session

you are taking over the artcoins v2 project from the cloud session that built it. read this file fully, then docs/v2/STATUS.md, docs/v2/REPORT.md, docs/v2/DECISIONS.md (D1 to D64), docs/v2/RUNBOOK.md and docs/v2/SYSTEM-REVIEW.md sections 2, 7 and 9, before doing anything.

## operating rules (from the owner, do not relax them)

| rule |
|---|
| write to the owner in compressed lowercase prose, tables over paragraphs, never dashes |
| no inline comments inside command blocks; explain above or below the block |
| rpc is tenderly's public gateway unless the owner says otherwise: `export ETH_RPC_URL=https://mainnet.gateway.tenderly.co` and `MAINNET_RPC_URL` the same. cast and forge read `ETH_RPC_URL`; in zsh never pass a variable holding two words as one argument |
| the owner key is the foundry keystore `ripe0x` (`--account ripe0x`), address 0xCB43078C32423F5348Cab5885911C3B5faE217F9. keepers use a separate keystore `artcoins-keeper` funded under 0.05 eth. never put a key in a file, an argument or a log |
| you never broadcast a mainnet transaction yourself. you prepare the exact command, simulate it with `cast call --from <sender>` or a forge dry run, and the owner runs the broadcast in their own terminal |
| never push to master. work on `v2` in the private repo ripe0x/new-material-coin-launcher. the public repo ripe0x/artcoins is a mirror of master only |
| do not rewrite history. commit often, push often |
| every decision the owner should make goes into docs/v2/DECISIONS.md as a new row with the alternatives and why, numbered after the last one. never edit old rows |
| keep docs/v2/STATUS.md current: a restarted session must be able to pick up from it |
| delegate implementation, tests and reviews to subagents on cheaper models where you can; you are the director and the final outputs are your responsibility |

## where things are

| item | value |
|---|---|
| private working repo | https://github.com/ripe0x/new-material-coin-launcher, branch `v2`, draft pr #35, head `ce2e955` or later |
| public mirror | https://github.com/ripe0x/artcoins. a day one copy of `v2` and pr #34 are still there (D26, D63); the owner deletes them |
| site repo | https://github.com/ripe0x/new-material: next.js site, `indexer/`, and the fly `layer-keeper` bot (`scripts/keeper.ts --watch`). not part of v2 |
| live mainnet | all v1, immutable. current factory 0x4959… (deprecated, owner only, one coin: 111 at 0x61C9…), open factory 0xf051… (public, zero fee, zero coins), legacy factory 0xd159… (LAYER). owner 0xCB43…. full list with roles and provenance in deployments/mainnet.json |
| v2 | not deployed. 37 contracts under src/v2 plus src/Constants.sol. external review 1 found no new medium or above (docs/v2/review/external-review-1.md); tags `v2-audit-1` = 9fed001 and `v2-audit-2` = d8575db exist locally in the cloud session only; create and push them from this machine (step 2 below) |
| ci | github `CI` and `Registry` workflows on the private repo; both green on the branch head after the fork job compile was batched |

## what is done

| area | state |
|---|---|
| registry | deployments/mainnet.json verified on chain (56 contracts, 2 coins, 0 drift), profile aware bytecode compare, readme / AGENTS.md / ui / 32 scripts read from it via generated files |
| system review | docs/v2/SYSTEM-REVIEW.md: 8 area reviews with 70 v1 proof tests on a fork, second pass on v2 (38 findings, all resolved or accepted), external review 1 |
| v2 stack | factory, deployer, token (NONE / VENUE / HARD tax modes), hook, locker, escrow, fee delivery, mev skim module, fee swapper, burn router, fee controller, airdrop, vault, dev buy, renderers, three keepers. 589 fork and unit tests at block 26130269 |
| deploy tooling | script/v2/DeployV2Lib.sol, DeployV2Stack.s.sol, LaunchV2Coin.s.sol, verify-v2.sh, README.md; fork dry run passes every post deploy assert |
| runbook | docs/v2/RUNBOOK.md: 11 owner actions, each simulated; v2 rollout order; 15 gate public checklist |
| keepers | on chain helpers src/v2/keepers/CollectFlushKeeperV1.sol (111), CollectFlushKeeperLayer.sol (optional, D64), ArtCoinsKeeperV2.sol (v2 coins); hosted runner keeper/ for fly.io (`KEEPERS=111,v2`, independently reviewed, 70 tests) |
| ui | v2 abis and encoder, factory validators mirrored, browser e2e on an anvil fork (19/19), six bugs fixed; waits for v2 addresses |

## open items, in order

| # | item | who | pointer |
|---|---|---|---|
| 1 | runbook part 1 actions 1 to 6: collect 111 and LAYER, deprecate 0xf051, LAYER router floors, deploy the 111 helper, claim owner LAYER fees. the exact commands with `ETH_RPC_URL` and `--account ripe0x` are in RUNBOOK part 1; the owner broadcasts | owner, you prepare and verify | RUNBOOK part 1 |
| 2 | create and push the audit tags: `git tag -a v2-audit-1 9fed001 -m "external review target 1"`, `git tag -a v2-audit-2 d8575db -m "external review target 2: review 1 corrections"`, `git push origin v2-audit-1 v2-audit-2` | you | AUDIT-BRIEF.md |
| 3 | reviewer recheck of `src/Constants.sol` and `src/v2/protocol-fee/BurnRouterV2.sol` between the two tags | owner sends | external-review-1.md |
| 4 | record the deployed keepers (`KEEPER_111`, optional `KEEPER_LAYER`) in deployments/mainnet.json with role `keeper`, regenerate: `cd script-js && npm run gen:addresses && node verify-registry.mjs --build --require-artifacts`, commit | you, after step 1 | registry-notes.md |
| 5 | fly runner: `fly launch` per keeper/README.md with `KEEPERS=111,v2`, `DRY_RUN=1` first, then live; `KEEPER_PRIVATE_KEY` from the `artcoins-keeper` keystore into fly secrets. LAYER stays with the existing `layer-keeper` in new-material (D64) | owner runs fly, you prepare | keeper/README.md, D62, D64 |
| 6 | delete the public copy: branch `v2` and pr #34 on ripe0x/artcoins | owner | D63 |
| 7 | decisions the owner has not answered yet: D26 (public exposure, now moot once step 6 is done), D7, D41/D60, D46, D58 (behavior changing). if any is overruled, implement, retest, retag `v2-audit-3` | owner, then you | DECISIONS.md |
| 8 | check the credits engine treasury against docs/v2/CREDITS-ENGINE-INTERFACE.md (the bundle was never available; the interface is from assumptions). if the treasury needs something the interface does not give, change the hook delivery or swapper, retest | owner provides the bundle, you check | CREDITS-ENGINE-INTERFACE.md |
| 9 | ci secrets on the private repo: `MAINNET_RPC_URL` is set; add `ETHERSCAN_API_KEY` | owner | registry.yml, verify-v2.sh |
| 10 | mainnet deploy: RUNBOOK part 2a. `FOUNDRY_PROFILE=ci forge script script/v2/DeployV2Stack.s.sol --rpc-url $ETH_RPC_URL --sender $OWNER` dry run, then the owner broadcasts with `--account ripe0x --broadcast --slow`; `acceptOwnership` on escrow, hook, locker, factory; `script/v2/verify-v2.sh`; fill deployments/v2.template.json into mainnet.json as stack `v2`; verifier; commit | owner broadcasts, you drive | RUNBOOK 2a, script/v2/README.md |
| 11 | first coin via `deployTokenAsOwner` while the factory is deprecated; pre launch `setExemptAllowed(treasury)` if needed and `addDepositor(feeSwapper)`; `BurnRouterV2.initialize`; one keeper run; add the coin to the registry | owner broadcasts, you drive | RUNBOOK 2b |
| 12 | ui: set the v2 stack (`VITE_V2_*` or the generator), rerun `cd ui && npm run test:e2e` against it, deploy the site | you | ui/README.md, ui-fixes.md |
| 13 | `setDeprecated(false)` last, after the 15 gates in RUNBOOK 2c | owner | RUNBOOK 2c |

## how to run tests here

| group | command | expected |
|---|---|---|
| v2 unit, no fork | `forge test --match-path "test/v2/**" --match-contract "^(EscrowV2Test|FeeDeliveryTest|TokenV2Test|ConstantsV2Test|MevLinearSkimV2Test|KeeperV2Test|ProtocolFeeControllerV2Test|RendererV2Test|AirdropV2Test|VaultV2Test)$"` | 238 pass |
| v2 tree, fork | `FOUNDRY_PROFILE=ci forge test --match-path "test/v2/**" --fork-url $ETH_RPC_URL --fork-block-number 26130269 --fork-retries 8 --fork-retry-backoff 2000 --no-match-contract "^(EscrowV2Test|FeeDeliveryTest|TokenV2Test|ConstantsV2Test|MevLinearSkimV2Test|KeeperV2Test|ProtocolFeeControllerV2Test|RendererV2Test|AirdropV2Test|VaultV2Test)$"` | 364 pass |
| deploy rehearsal | `FOUNDRY_PROFILE=ci forge test --match-path "test/v2/DeployV2Stack.fork.t.sol" --fork-url $ETH_RPC_URL --fork-block-number 26130269 -vv` | 6 pass |
| review proofs | `forge test --match-path "test/v2/{review,review-v2}/**" --fork-url $ETH_RPC_URL --fork-block-number 26130269 --fork-retries 8 --fork-retry-backoff 2000` | 101 pass |
| keeper runner | `cd keeper && npm ci && npm test` | 70 pass |
| ui | `cd ui && npm ci && npm test && npm run build && npm run lint`, then anvil fork, `DRY_RUN=0 script/v2/deploy.sh local` and `npm run test:e2e` (ui/README.md) | 74 unit, 19 e2e |
| sizes | `FOUNDRY_PROFILE=ci forge build --sizes --skip "test/**" --skip script` | hook 16,716 bytes, headroom 7,860 |
| registry | `cd script-js && npm ci && node verify-registry.mjs --build --require-artifacts` | 0 drift; 18 older rows mismatch by design (registry-notes.md) |

a cold compile of the whole tree can need about 14 gb; build src, script and test batches first on small machines (the ci workflow shows the batches).

## things that bit the cloud session, so you do not repeat them

| lesson |
|---|
| forge compiles every test file under test/ even with `--match-path`; a broken file anywhere breaks every run. use `--skip` for in progress files |
| `forge test --match-path` cannot be passed twice; use one brace glob |
| under via ir, `block.timestamp` reads can be reordered past `vm.warp`; use `vm.getBlockTimestamp()` in tests |
| deterministic test addresses hold real eth on a fork; measure deltas, never assert zero balances on fresh contracts |
| the tenderly gateway 429s under parallel forge runs; serialize fork runs |
| the git proxy in the cloud session refused tag pushes; from this machine tags push normally |
| the PoolManager passes the PositionManager, not the locker, as `sender` to liquidity hooks |
| the afterSwap return delta can only adjust the unspecified currency, so an in swap eth refund is impossible (D58) |
| on the owner's mac, git config sets `submodule.active :!**` for linked worktrees, so `git submodule update --init --recursive` skips every nested lib and the compile fails with `lib/permit2/src/src/...` not found. init nested submodules by explicit path inside the worktree (`git -C lib/v4-periphery submodule update --init -- lib/permit2`, repeat until `git submodule status --recursive` shows only the two deep `ds-test` leaves); never change the global config |
| branch `v2` is also checked out in /Users/dd/CascadeProjects/launcher-v2, so another worktree cannot check it out. track it on a local branch (`git checkout -B v2-director origin/v2`) and push with `git push origin HEAD:v2` |
| the local forge is 1.8.1, ci pins 1.7.1. the suites were proven with a 1.7.1 binary; use that for counts that must match ci |
| port 8545 can be held by another session's anvil; run the ui e2e fork on another port with `E2E_FORK_RPC` |

## style of the docs you maintain

lowercase, tables over paragraphs, no dashes, blunt. every claim about live state carries the block it was read at. every test count carries its command.
