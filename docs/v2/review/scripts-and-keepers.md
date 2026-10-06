# scripts, ops and keepers review

scope: script/*.s.sol, script/*.sh, script-js/*, .github/, ui/ (automation only), plus the contracts they call. read only. chain reads taken at block 26130325 (2026-10-06 ~02:25 utc) from the tenderly gateway, simulations on a local anvil fork. nothing was broadcast. severity: high = wrong target or loss path, med = foot gun with a real trigger, low = hygiene.

short version: no script in this repo can launch on the current stack (factory 0x4959, hook 0x636c, locker 0x866e). every launch script encodes the legacy `(buyFee, sell fee)` pool data and WETH pairing that the skim hook rejects. the one script that wires the "current" stack hardcodes the older open factory. there is no keeper code in the repo at all. the 111 fee path has a permissionless stranding bug in the swapper (proved on a fork).

## part a: scripts

compile check: all 39 files under script/ type check clean (solc 0.8.26 analysis, per file, remappings from remappings.txt). `forge build --skip test` could not give a signal: the shared tree currently fails on an unrelated test/v2/harness file (`LiquidityAmounts.getAmountsForLiquidity`). so "still compiles" is true, "still works against the live stack" is mostly false (see matrix).

### findings, ranked

| id | sev | title | evidence | fix |
|---|---|---|---|---|
| S-01 | high | phase 1/3 wiring script hardcodes the OLD open factory, hook, escrow, mev (0xF051, 0xAAd6, 0xDD1b, 0xAe19), and its preflight demands `!deprecated`, so it only passes on the wrong factory. on 0x4959 (deprecated) it fails closed; on 0xF051 it passes and sends irreversible txs (`renounceOwnership` of the new locker, depositor adds on the wrong escrow) | script/DeployConversionLockerAndWire.s.sol:58-61, :129, :84, :108-117 | take addresses from the registry or env, assert chainid, codehash and owner, drop the `!deprecated` precondition, make renounce an explicit flag, add post asserts |
| S-02 | high | README tells operators to run Deploy.s.sol (or DeployNativeEthStack, DeployProtocolFeeStack) for mainnet. Deploy.s.sol deploys the LEGACY stack (legacy factory, StaticFeeV2 hook, LpLockerMultiple, FeeLocker, WETH pairing). nothing in the readme points at DeployV1Stack | README.md:83-86, script/Deploy.s.sol:18-27, :163 | point readme at the one supported script, mark Deploy.s.sol and DeployNativeEthStack as legacy in the file header and move them under script/legacy/ |
| S-03 | high | DeployNativeEthStack opens the factory to the public by default: `setDeprecated(false)`, deploy fee 0, no mev module allowlisted. live 0xf051 matches this exactly (deprecated=false, fee 0). anyone can launch there without anti sniper and with the 20% protocol slot routed to the burn router | script/DeployNativeEthStack.s.sol:152-154 | default to deprecated=true; opening must be a separate, explicit owner script. decide whether 0xf051 should be closed now (owner call: `setDeprecated(true)`) |
| S-04 | high | no repo script can launch on the current skim stack. all Launch*/Smoke* scripts use the legacy factory ABI, `abi.encode(BUY_FEE, SELL_FEE)` pool data and a WETH pair. the skim hook decodes `SkimHookFeeData` (8 fields) and requires `quoteToken == address(0)`, so these revert at pool init (fail closed, unverified by broadcast). launching 111 happened from the permanent-collection repo, so the launch recipe is not in this repo | script/LaunchTestToken.s.sol:46-56, :115, src/hooks/libraries/SkimFeeInitLib.sol:36-66 | add `LaunchSkimToken.s.sol` for the live stack (native ETH, deployTokenWithProtocolBps[AndTax], skim feeData, mev linear skim) with preflight and post asserts; retire the legacy launchers |
| S-05 | med | LaunchLayer and PreflightLaunch are LAYER one shots with `startingTick == -190400`, name "LAYER", merkle root, burn 26.02%. LaunchLayer preflight reverts hard on `hook.protocolFeeNumerator()` (does not exist on ArtCoinsHook) and `teamFeeRecipient == PFC`; PreflightLaunch wraps the same reads in try/catch and only WARNS, so preflight can print "PASSED with warnings" while the launch reverts | script/LaunchLayer.s.sol:249-262, script/PreflightLaunch.s.sol:207-257 | fail on view failure in preflight; move LAYER scripts to script/legacy |
| S-06 | med | DeployV1Stack post flight asserts the locker is an escrow depositor but not the hook. the code comment says a missing hook depositor bricks every swap. also no assert that `hook.factory()`, `hook.feeEscrow()`, `locker.feeLocker` point at the new contracts | script/DeployV1Stack.s.sol:174-176 vs :200-216 | assert `allowedDepositors(hook)`, hook immutables, locker keeperRewardBps, owners |
| S-07 | med | DeployV1Stack leaves factory, escrow, allowlist, locker owned by the raw `PRIVATE_KEY` deployer. teamFeeRecipient = deployer, deploy fee forced to 0. live 0x4959 differs (fee 0.069 eth, teamFeeRecipient = 0xCB43 eoa), so it was NOT produced by this script as written. any non PC launch with default bps sends a 20% protocol slot and the deploy fee to a single eoa | script/DeployV1Stack.s.sol:130-168 | transfer ownership to a multisig as the last step, or document the eoa as a deliberate custody choice; reconcile script with live config |
| S-08 | med | no chain id guard in DeployV1Stack, DeployNativeEthStack, DeployConversionLockerAndWire, RedeployBurnRouter, RedeployHook, Bind*, DeployBurnExtension. mainnet constants are baked into DeployV1Stack, so a sepolia run builds a stack against mainnet pool manager addresses and logs success | script/DeployV1Stack.s.sol:83-86 (no `block.chainid` check; only a log at :188) | `require(block.chainid == 1)` or a network struct as in Deploy.s.sol:94-112 |
| S-09 | med | 32 scripts read `vm.envUint("PRIVATE_KEY")`. raw key in a `.env`, exported to every child process by `set -a; . ./.env` in the shell scripts, and several doc headers show `--private-key $PRIVATE_KEY` (visible in `ps`). only DeployConversionLockerAndWire supports ledger or keystore | script/*.s.sol (grep `vm.envUint("PRIVATE_KEY")`), script/LiveSwapVerify.s.sol:27 | use `--account`/`--ledger` and `--sender`, `vm.startBroadcast()` with no key; drop PRIVATE_KEY from .env.example |
| S-10 | med | verify-stack.sh is stale and fails open. SRC_PATH points at moved files (src/ArtCoinsFeeLocker.sol, src/hooks/ArtCoinsHookStaticFeeV2.sol, src/lp-lockers/ArtCoinsLpLockerMultiple.sol are under legacy/), the name `ArtCoinsFactory` maps to the NEW source while Deploy.s.sol broadcasts the legacy one, current stack contracts (HookSkimFee, LpLocker, FeeEscrow, MevLinearSkim) have no mapping, only two broadcasts are walked, and every verify is `|| true` so the script exits 0 when everything failed. api key passed as argv | script/verify-stack.sh:49-70, :93, :98-99 | rewrite against the registry, fail non zero on any failed verify, pass the key by env |
| S-11 | med | sync-addresses.mjs writes legacy addresses into `.env` (FACTORY, HOOK, LOCKER ...) and a config path in another repo. it only maps Deploy.s.sol, so the next run feeds the legacy factory into every env driven launch script. it also hardcodes names like NewMaterialHookStaticFeeV2 | script-js/sync-addresses.mjs:25-95, :30 | replace with registry reader; never write `.env` |
| S-12 | med | SetUpLayerAutoForward carries a stale hardcoded backfill (BUYS 321, SELLS 410, 2026-05-08). a rerun deploys a second extension and reseeds the LAYER counter from old numbers. same family: LiveSwapVerify/LiveSellVerify/LiveNoOpVerify do real mainnet swaps with `sqrtPriceLimit = MAX-1` | script/SetUpLayerAutoForward.s.sol:90-91, script/LiveSwapVerify.s.sol:56-60 | gate behind an env confirmation, read counts from chain, move to legacy |
| S-13 | med | `DeployPCController` doc and logs say a 80/20 split while the constant is 8667/1333; `DeployProtocolFeeStack` hardcodes 6000/4000. a reader trusting the log misstates the split. the controller mins are 4000 treasury and 1000 burn | script/DeployPCController.s.sol:78 (log), :53 (`PC_TREASURY_BPS = 8667`), script/DeployProtocolFeeStack.s.sol:32 | log the computed bps, one source of truth |
| S-14 | low | RedeployBurnRouter re-points `factory.setTeamFeeRecipient` on whatever FACTORY env is, then calls it "orphaned". on 0x4959 that would redirect the 0.069 eth deploy fee and every default protocol slot | script/RedeployBurnRouter.s.sol:79 | require explicit `CONFIRM_REWIRE=1`, print old and new, assert owner |
| S-15 | low | RedeployHook only builds the legacy 4 arg hook and never wires it; stale vs the 5 arg current hook | script/RedeployHook.s.sol:34-52 | delete or port |
| S-16 | low | launch test scripts hardcode `startingTick = -230400` (~0.1 eth fdv, about $300) and `salt = block.timestamp`; no chain guard, so a mainnet env launches a dust priced coin and pays the fee | script/LaunchTestToken.s.sol:70, script/LaunchLLToken.s.sol:70 | derive tick from fdv via compute-starting-tick, guard chainid 11155111 |
| S-17 | low | compute-starting-tick.mjs prints "if token0" ticks only. no native ETH mode (token is always token1 against address(0)), no check of tick bounds vs MIN/MAX minus the 110400 span | script-js/compute-starting-tick.mjs:62-110 | add `--native` and bound checks |
| S-18 | low | decode-and-verify.mjs opens on chain HTML (data: uri from any renderer) in puppeteer with js enabled. the self contained check is a regex on `<script src="...">` only (misses single quotes, spaces, `import()`, img/iframe/css). fetch-token-uri.mjs defaults to a sepolia public rpc and does not check chain id. both write under tmp/ | script-js/decode-and-verify.mjs:48-60, script-js/fetch-token-uri.mjs:7 | launch with sandbox on, `--proxy-server=none`/request interception that blocks non data: urls, run only on owned tokens |
| S-19 | low | build-allowlist.ts: no duplicate address check, zero amounts accepted, no sum vs extension allocation check (preview-claim-table.mjs is the manual check). imports ui/src/lib/merkle.ts so it only resolves with ui/node_modules | script-js/build-allowlist.ts:38-52 | dedupe, reject zero, print sum and share of supply |
| S-20 | low | shell: RunRehearsal.sh and preflight-launch.sh pass the rpc url as argv (keyed urls leak via `ps`), RunRehearsal tees -vv output to tmp/ (gitignored) and sources `.env` with `set -a`. `set -euo pipefail` is correct; the script depends on test/MainnetLaunchRehearsalForkTest which targets the LAYER stack, not 111 | script/RunRehearsal.sh:11-29, script/preflight-launch.sh:16-33 | use FOUNDRY env vars for the rpc, keep key out of the environment |
| S-21 | low | no dry run guard anywhere. safety relies on forge defaulting to simulation without `--broadcast`; several docs lead with `--broadcast` as the first command. FullDryRun/Live* use `vm.startBroadcast()` and depend on `--sender` | README.md:86, script/FullDryRun.s.sol:101 | add a `DRY_RUN` default and print a banner with chainid, factory, owner before any broadcast |

### script to target matrix (what each script would touch)

| script | factory / hook / locker source | verdict vs 0x4959, 0x636c, 0x866e |
|---|---|---|
| DeployV1Stack | deploys new, mainnet constants | right shape, fresh stack, would not touch live. no chain guard (S-08) |
| DeployConversionLockerAndWire | const 0xF051, hook 0xAAd6, escrow 0xDD1b | WRONG factory and hook (S-01) |
| DeployNativeEthStack | deploys new (this is the 0xf051 family), static hook | wrong hook family for 111, opens factory (S-03) |
| Deploy | deploys legacy stack | wrong stack (S-02) |
| LaunchLayer, PrepareLayerLaunch, PreflightLaunch | env FACTORY/HOOK/LOCKER, legacy ABI | fails closed on 0x4959 and 0x636c (teamFeeRecipient, protocolFeeNumerator) |
| LaunchTestToken, LaunchLLToken, LaunchLLTokenSimple, LaunchArtTest, SmokeTestLLCounter, SmokeTestArtTestSepolia | env, legacy ABI | would revert at pool init on the skim hook (S-04); on legacy factories they work |
| LaunchDynamicToken | const sepolia 0x3c3a, 0x36EF, 0x6e51 | sepolia only, no code on mainnet so reverts |
| BindProtocolFeeController, DeployMevSniperSteppedFees, DeployBurnExtension, RedeployBurnRouter | env FACTORY | act on whatever factory env holds, no stack check (S-14) |
| FullDryRun, LiveNoOp/Sell/SwapVerify, SetUpLayerAutoForward, TraceTestTokenFees | const LAYER stack (hook 0xA5eA, locker 0x75BE, fee locker 0x1143, pfc 0x5fDc, router 0x2eDB) | correct for LAYER only. not 111 |
| MigrateLayerRenderer, UpgradeLLMona, SwapMonaAsset, FixLLSketchAsset, VerifyLLRenderer, DeployLL*, DeployDynamicRenderer | LAYER renderer / scripty | out of scope for 111 |
| RedeployHook | env | legacy 4 arg hook, dead (S-15) |

nothing in script/ references 0x4959, 0x636c, 0x866e, 0x7559 or 0xb038. LaunchDefaults.sol holds no addresses (only ticks, fees, lp presets).

### launch misconfiguration checklist (current stack, from DeployV1Stack and the live factory)

| check | status |
|---|---|
| step order inside factory (token, pool init, locker, mev, extensions) | enforced by the factory, not scripts |
| locker allowlisted for hook (`enabledLockers`) | script sets it; live true |
| hook is escrow depositor | script sets it; post flight does not assert (S-06); live true |
| mev module allowlisted | live true for 0xb038 |
| extension allowlist | DeployV1Stack ships it empty by design; PC adds its own through the token admin |
| protocol fee controller bound | NOT bound. live teamFeeRecipient is the 0xCB43 eoa. pc passes protocol bps 0 for 111 |
| deprecated at deploy | true by constructor, stays true (good). live 0x4959 deprecated=true |
| deploy fee | script sets 0, live is 0.069 eth (differs) |
| locker keeper reward | script sets 0; live keeperRewardBps 0, cap 0.01 eth, owner 0xCB43 still holds the setters (not renounced) |
| post deploy verification | present in DeployV1Stack (partial), absent in DeployConversionLockerAndWire, DeployNativeEthStack |
| dry run | none beyond forge simulation |

## part b: keepers and automation

### keeper inventory

| name | kind | trigger | key | calls | notes |
|---|---|---|---|---|---|
| none in repo | | | | | no keeper, bot, cron or runner exists in script/, script-js/, ui/ or .github/ |
| ci (test.yml) | github action | every push, pull_request, dispatch | no secrets, `permissions: {}` | fmt check, build --sizes, forge test excluding two fork suites | actions pinned by tag only. exclusion list is by contract name and will drift: new v2 fork tests that call `createSelectFork` unconditionally would fail or hit the rpc in ci (.github/workflows/test.yml:47-50) |
| mirror.yml | github action | push to master, any tag, dispatch | `MIRROR_DEPLOY_KEY` ssh write key for the public repo | pushes master and all tags, fast forward only | `ssh-keyscan` trusts the first host key (mirror.yml:47); everything on master, including broadcast/ json, becomes public with same shas; a tag pushed from a branch with an edited workflow gets the secret |
| registry.yml | github action | not present at review | | | being written by the registry agent |
| hook per swap flush | on chain, keeperless | every swap | none | `_flushAccruedSkim`: bounty pushed to bounty recipient (reverts the swap if it cannot take eth), protocol leg to escrow, referral notify | src/hooks/ArtCoinsHookSkimFee.sol:684-743 |
| LAYER autoforward extension | on chain, keeperless | every LAYER swap, one stage per swap | none | processBurnLayer, processFees, escrow claim. processBurnWeth is deliberately left to a keeper | src/extensions/LiquidityLayerAutoForwardExtension.sol:30-60 |
| autoburn pool extension | on chain, keeperless | every swap on a bound pool | none | collectRewardsWithoutUnlock, burn, pfc, claim | not bound to the 111 pool (111 uses the PC extension) |
| EOA 0x71cA3E…b999 | off chain bot, unidentified | after swaps | its own key, nonce 1149, 0.0135 eth | `convert(0)` on the 111 swapper (2 txs, ~270k gas, blocks 26106497 and 26106550); `sweep()` on protocol recipient 0xed3e… a few blocks after each swap (tx 0x51f821…) | the only continuously running keeper seen. a single eoa with a thin balance |
| EOA 0xA35854…CCa5 | one shot bundle | manual, 2026-10-02 18:29 utc | own key | deployed a contract whose constructor ran locker.collectRewards, swapper.convert, swapper.flushPaired (tx 0xf438aa…, block 26106435, 1.315m gas, 1m coin converted for 0.0492 eth, 0.2432 eth flushed, keeper rewards 0.00025 + 0.00122 eth) | last time the 111 locker was collected. collection is manual and rare: one ClaimedRewards event since block 25.9m |

### permissionless functions that need a caller

| function | expected caller, cadence | if nobody calls | keeper exists |
|---|---|---|---|
| ArtCoinsLpLocker.collectRewards(token) (src/lp-lockers/ArtCoinsLpLocker.sol:405) | anyone, weekly or on size. the current hook does not auto collect. ~658k gas for 14 positions. keeper reward is `keeperRewardBps` (0 on the live locker) | lp fees stay in the positions, nothing lost, nothing compounds. recipients (swapper) get nothing until collected | manual only (0xA358 bundle) |
| FeeAutoSwapper.convert(minOut) (:328) | anyone. pacing 50 blocks, step cap 1m coin, ~300k gas, reward 0.5% of eth out capped 0.01 eth | coin side fees sit at the swapper's escrow slot, endRecipient gets no eth | 0x71cA bot, only when profitable |
| FeeAutoSwapper.flushPaired() (:446) | anyone, ~72k gas, same 0.5% reward | eth sits in the escrow slot. see stranding K-01 | via the bundle only |
| ArtCoinsFeeEscrow.claim(owner, token) (:85) | anyone, pushes to the fee owner | balances sit. for contract owners that reject eth it reverts (owner uses claimTo) | 0x71cA bot sweeps 0xed3e |
| referral payout 0xb03c… claim() | each referrer | 0.0635 eth sits, pull only. UI calls a `flushReferral` that no longer exists on the hook (ui/src/lib/abi.ts:170) | none, none needed |
| BurnRouter.processBurnWeth / processBurnLayer | anyone (LAYER stack). threshold 0.01 weth, reward 0.5% cap 0.01 eth | weth waits. LAYER router holds 0.000186 weth, below threshold | no keeper; autoforward covers only burnLayer |
| ProtocolFeeController.processFees / processNativeFees | anyone | pfc 0x5fDc… holds 0 now; escrow slot has 4,849 LAYER and 0.000489 weth, below the autoforward thresholds (100k LAYER, 0.01 weth) so it will sit | none |
| LAYER fee locker claims for 0xCB43 | the owner | 3,315,375 LAYER and 0.4796 weth unclaimed at 0x1143… for the owner. claim is permissionless but only pays the owner | none needed, owner decision |
| Factory.claimTeamFees, recoverETH, locker withdrawETH | owner only | manual | n/a |
| Vault.claim, Airdrop.claim | beneficiaries | vesting waits | none needed |

### findings, ranked

| id | sev | title | evidence | fix |
|---|---|---|---|---|
| K-01 | high | the 111 swapper strands eth. `escrow.claim(swapper, address(0))` is permissionless and pushes the swapper's eth slot into the swapper's `receive()`. `flushPaired` reads only the escrow slot, so it then reverts `NothingToFlush`, and no function can move the eth. one tx can do `locker.collectRewards(111)` then `escrow.claim(swapper, 0)`, so any eth sitting in the lp positions (0.243 eth was collected on 2026-10-02) can be stranded for the cost of gas. proved on a fork: 1 eth deposited, claimed by a stranger, swapper balance 1 eth, flush reverts 0xeb694a3c | src/FeeAutoSwapper.sol:280 (receive, doc admits no sweep), :446-452, src/ArtCoinsFeeEscrow.sol:85-100 | swapper is immutable, cannot be fixed in place. mitigate by always collecting and flushing in one tx, privately. v2 swapper: for native mode set `pairedOut = address(this).balance` after the claim and drop NothingToFlush when balance > 0; or make escrow.claim owner or keeper only for slots whose owner is a contract |
| K-02 | med | the in tree and spec'd helper must not use bare try/catch around `convert`. a tx limited by `estimateGas` ran the helper to success while the inner `convert` failed (hook `HookCallFailed`, out of gas in a sub call) and was silently skipped; with a 1.5m gas limit it executed. reproduced on a fork | prototype run, see helper spec | `gasleft()` floor before each step, explicit gas limit in the runner, report skipped steps |
| K-03 | med | `src/v2/keepers/CollectFlushKeeperV1.sol` (untracked draft in the tree): `preview()` only sums currency0 fee growth, but the live pending fees are all currency1 (13,404 coin, 0 eth), so the hint reads 0 when there is work; `run` has no gas floor (K-02), no `NothingDone` revert, forwards to `msg.sender` only | src/v2/keepers/CollectFlushKeeperV1.sol (run, preview) | add fee growth 1 to the hint, gas floors, rewardTo, NothingDone |
| K-04 | med | keeper economics do not close at the current size. one bundle costs ~1.03m gas (0.0012 eth at 1.13 gwei) and pays 0.5% of the eth output (cap 0.01). break even needs ~0.23 eth of output, roughly 4.7m coin at 4.9e-8 eth per coin; pending is 13.4k coin worth 0.00065 eth and pays 3.2e-6 eth. third party bots will not run it; the owner must fund gas | live reads below | owner run keeper on a cadence, or raise the swapper reward in v2 |
| K-05 | med | single keeper dependency. the only continuous keeper is an anonymous EOA with 0.0135 eth | tx 0x51f821…, 0x41b1e5… | run the owner keeper as a second path; monitor `lastConvertBlock` age |
| K-06 | low | convert pacing grief: anyone can send dust coin to the swapper and call `convert` every 50 blocks, resetting `lastConvertBlock` and blocking a real conversion for ~10 minutes at ~300k gas each | src/FeeAutoSwapper.sol:363 | min input size, or pacing only on paying converts |
| K-07 | low | convert with `minOut = 0` (what 0x71cA sends) leans on the contract floors only: 5% sqrt clamp and 80% spot floor, both read from the same tx spot, so a sandwich takes up to ~5% of each step | src/FeeAutoSwapper.sol:101-102, :330-381 | runner passes a quoted minOut and sends privately |
| K-08 | low | autoburn extension: `collectRewardsWithoutUnlock` pays the locker keeper reward to the extension. native reward is skipped (no receive, call fails, handled), but on a WETH paired pool with `keeperRewardBps > 0` the reward is an ERC20 transfer to the extension and strands. per swap collect on a 14 position locker adds ~650k gas to the trader | src/lp-lockers/ArtCoinsLpLocker.sol:166-181, src/extensions/ArtCoinsAutoBurnPoolExtension.sol:122-124 | keep keeperRewardBps 0 on pools using it, or add a sweep |
| K-09 | low | hook bounty leg reverts the swap if the bounty recipient (0x8C72…, a contract) cannot take eth. availability depends on that contract forever | src/hooks/ArtCoinsHookSkimFee.sol:708-712 | not a keeper issue; track in the hooks review |
| K-10 | low | mirror.yml and ci: tag pinned third party actions, `ssh-keyscan` tofu, secret reachable from any tag push | .github/workflows/mirror.yml:47, test.yml | pin shas, pin github host keys, restrict tag pushes |
| K-11 | low | ui bundles `VITE_ALCHEMY_API_KEY` into client js; ui has no write path to any keeper function, `ReferralsPage` calls the dead `flushReferral` | ui/src/main.tsx:20, ui/src/pages/ReferralsPage.tsx:207 | ui agent |

### missing keepers (summary)

| gap | consequence | recommended |
|---|---|---|
| locker collect for 111 | fees idle, keeper reward 0 | owner keeper (helper below), weekly |
| convert and flush bundling | stranding window K-01, wasted gas | one tx bundle via helper, private mempool |
| LAYER processBurnWeth | idle weth at the router (0.000186 now, below threshold) | cheap cron `status().readyForWethBurn` then `processBurnWeth(quoted minOut)` |
| pfc and fee locker dust for LAYER | below autoforward thresholds forever | cron: if slot ≥ 0.001 weth or 10k LAYER, call claim then processFees |
| liveness monitoring | no alert if the 0x71cA bot stops or the swapper balance becomes nonzero | runner prints swapper eth balance, `lastConvertBlock` age, escrow slots, helper `preview()` |

## live state of the 111 fee path (chain reads, block 26130325)

| item | value |
|---|---|
| factory 0x4959 | version "1", owner 0xCB43, deprecated true, deployFee 0.069 eth, defaultProtocolFeeBps 2000, teamFeeRecipient 0xCB43 (eoa), enabled: hook 0x636c, locker 0x866e (for that hook), mev 0xb038 |
| factory 0xf051 | version "3", deprecated false, deployFee 0, teamFeeRecipient 0xE600… |
| factory 0xd159 | version "1" (same string as 0x4959, so `version()` cannot tell them apart), deprecated true, fee 0, teamFeeRecipient pfc 0x5fDc… |
| 111 reward slots | locker.tokenRewards(111): 14 positions from id 309865, one slot: 100% (10000 bps) to 0xebd9b74a…2a961 (the swapper), admin 0xdead (renounced, cannot be rerouted). pool: currency0 eth, currency1 111, dynamic fee, spacing 200, hook 0x636c |
| locker | owner 0xCB43 (not renounced), keeperRewardBps 0, cap 0.01 eth, balance 0 eth, 3312 wei of coin |
| uncollected lp fees (simulated collectRewards on a fork) | 13,404.198 coin (1.3404e22), 0 eth. gas 658k |
| swapper 0xebd9… | setup true, pairedIsNative true, depositToLocker false, endRecipient 0x8C72… (contract, 6.9 kB, also the hook bounty recipient), maxSlippageBps 500, minBlocks 50, maxStepIn 1,000,000 coin, balance 0 eth, accruedPaired 0, accruedArtCoin 0 (before collect). lastConvertBlock 26106550 (23,775 blocks, ~3.3 days ago), totals: converted 2,619,765 coin, delivered 0.3695 eth, keeper rewards paid 0.001857 eth |
| convert on the 13.4k pending (fork) | 0.000649 eth out, reward 3.24e-6 eth, gas 299k |
| flushPaired with 2 eth in slot (fork) | reward 0.01 eth (cap), net to endRecipient 1.99 eth, gas 72k |
| escrow 0x7559 | balance 0 eth, owner 0xCB43, depositors: locker yes, hook yes. slots at zero for swapper, 0x41c3, 0xCB43, 0x8C72, 0xed3e |
| skim config (pool id 0xf860d8f4…) | baseline skim 6000/100000, bounty 8333 bps, referral cap 250, lp fee 5000, bounty recipient 0x8C72, protocol recipient 0xed3e… (1.3 kB contract, `sweep()`), referral payout 0xb03c… (balance 0.0635 eth), quote token eth |
| escrow events since block 26.0m | protocol leg deposits (0.00001 to 0.0013 eth) each followed 3 to 7 blocks later by a claim by 0x71cA via `sweep()`; one locker collect (block 26106435) |
| stranded eth in swapper | 0 now. mechanism K-01 proved on fork |
| LAYER stack | BurnRouter 0x2eDB: 0 eth, weth 0.000186, layer 0, threshold 0.01 (not ready). PFC 0x5fDc: 0 balance. 0x1143 fee locker slots: pfc 4,849 LAYER and 0.000489 weth, 0xCB43 3,315,375 LAYER and 0.4796 weth. LAYER locker 0x75BE pending ~403.6 LAYER, 0 weth |

## collect and flush keeper for 111 (spec for the builder)

goal: one tx per run that collects lp fees, drains the swapper's eth slot, and converts coin side fees, paying the caller what the contracts pay. stateless, immutable, no owner, no approvals. the in tree draft (src/v2/keepers/CollectFlushKeeperV1.sol) is close; changes needed are K-02 and K-03. I prototyped and ran the variant below on a fork against the live contracts (collect plus convert, 835k gas at gas limit 1.5m; helper deploy 615k gas).

### contract

| item | spec |
|---|---|
| name | `CollectAndFlushKeeper`, pinned to (locker 0x866e, token 0x61C9, swapper 0xebd9) as immutables. add escrow immutable for `preview` |
| access | permissionless. rewards go to `rewardTo` (0 means msg.sender), so a bot can use it too. no owner, no admin, no upgrade |
| approvals | none. the helper never deposits to the escrow and never holds coin: collect credits the swapper's escrow slot, convert and flush pay eth |
| eth handling | `receive()` payable. both the locker (when `keeperRewardBps > 0`) and the swapper pay the reward to `msg.sender`, which is the helper. at the end forward the whole eth balance to `rewardTo`, revert `ForwardFailed` if it fails. this also returns any eth donated by mistake. never send eth to the swapper (it strands) |
| order | 1 `locker.collectRewards(token)`; 2 if `swapper.accruedPaired() > 0` then `swapper.flushPaired()`; 3 if `doConvert` and coin accrued > 0 and `block.number >= nextConvertibleBlock` then `swapper.convert(minOut)`. collect and flush in the same tx is the stranding mitigation |
| failure handling | each step in try/catch, emit `Step(id, ok, reason)`. a failing step never blocks the next. revert `NothingDone` if no step succeeded. before step 1 require `gasleft() >= 700_000`, before step 3 require `gasleft() >= 450_000`, else revert `InsufficientGas` (do not silently skip: K-02) |
| reentrancy | simple lock; the only external calls are the three targets and the final forward |
| gas | measured: collect 658k (14 positions), convert 299k, flush 72k. total ~1.03m, runner sets limit 1.4m. helper deploy 615k |
| reward | swapper: 0.5% of eth out, cap 0.01 eth (convert and flush each). locker: 0 today (keeperRewardBps 0). do not change the locker rate; it taxes the swapper's own recipient |
| not possible | recovering eth already stranded in the swapper (K-01) |

### solidity interface (draft)

```solidity
interface ICollectAndFlushKeeper {
    struct Result {
        bool collected;            // locker.collectRewards succeeded
        bool flushed;              // swapper.flushPaired succeeded
        bool converted;            // swapper.convert succeeded
        uint256 coinAccruedBefore; // swapper.accruedArtCoin() before collect
        uint256 coinAccruedAfter;  // after collect, before convert
        uint256 ethFlushed;        // gross eth drained by flushPaired
        uint256 rewardEth;         // eth the helper received and forwarded
    }
    struct Preview {
        uint256 pendingCoinFees;   // uncollected lp fees, currency1 (fee growth 1), summed over positions
        uint256 pendingEthFees;    // uncollected lp fees, currency0 (fee growth 0)
        uint256 escrowEth;         // escrow.availableFees(swapper, 0), what flushPaired drains
        uint256 escrowCoin;        // escrow.availableFees(swapper, token)
        uint256 swapperEth;        // address(swapper).balance, nonzero means a stranding already happened
        uint256 nextConvertBlock;  // swapper.nextConvertibleBlock()
        bool canConvert;           // block.number >= nextConvertBlock
    }

    event Step(uint8 indexed step, bool ok, bytes reason);   // 1 collect, 2 flush, 3 convert
    event Done(address indexed caller, address indexed rewardTo, uint256 rewardEth);

    error NothingDone();
    error InsufficientGas(uint256 have, uint256 need);
    error ForwardFailed();
    error Reentered();

    function locker() external view returns (address);
    function token() external view returns (address);
    function swapper() external view returns (address);
    function escrow() external view returns (address);

    /// @param minOut   passed to swapper.convert, runner quotes it (ignored if !doConvert)
    /// @param doConvert run step 3
    /// @param rewardTo recipient of all eth received; address(0) means msg.sender
    function run(uint256 minOut, bool doConvert, address payable rewardTo)
        external
        returns (Result memory r);

    /// @notice cheap runner view; no state change
    function preview() external view returns (Preview memory p);

    receive() external payable;
}
```

### runner

| item | spec |
|---|---|
| language | node + viem in script-js/ (`keeper-111.mjs`), no other deps. read rpc `MAINNET_RPC_URL` (default tenderly gateway), send rpc `PRIVATE_RPC_URL` (a private relay such as flashbots protect). refuses to send on the public rpc unless `--allow-public` |
| key | dedicated hot key, `KEEPER_PRIVATE_KEY` from a secret store or an encrypted keystore with a 0600 password file. never a cli flag, never logged, never echoed. refuse to start if the address equals the owner 0xCB43 or holds more than 0.05 eth. the key has no privilege on chain, it only pays gas |
| cadence | check every 6 hours (cron or systemd timer, jittered). act when `pendingCoinFees` value plus `escrowEth` exceeds `MIN_ETH` (default 0.02 eth) or 7 days since the last run. do not use github actions for the key |
| decision | `preview()`, then `eth_call run(minOut, true, keeper)` from the keeper address to get the expected result. skip if the sim reverts `NothingDone`, or if gas price above `MAX_GWEI` (default 20). quote `minOut` from the pool spot (poolManager.getSlot0 of the 111 pool) times 0.98, never 0 |
| send | explicit gas limit 1,400,000 (never estimateGas, K-02), fee cap from `MAX_GWEI`, nonce from `pending`, replace by fee once after 3 blocks, then alert. dry run by default, `--send` required |
| after | read receipt events; alert (exit code 2 plus webhook) if any Step failed, if `swapperEth > 0`, or if `lastConvertBlock` age exceeds 14 days. log only addresses, amounts and tx hashes |
| races | a bot that runs convert first only makes `convert` skip (pacing) and the helper still collects and flushes. a stranger running collect then `escrow.claim(swapper,0)` strands that tx's eth, nothing the runner can do; hence short cadence and private sends |
| tests (builder) | fork tests at block 26130269: happy path, nothing pending (`NothingDone`), convert too early, gas floor revert, reward forwarding with keeperRewardBps pranked to 50, rewardTo that rejects eth, preview parity with the sim |

## what i could not verify

| item | why |
|---|---|
| that the launch scripts revert on 0x636c | analysis of `SkimFeeInitLib.validate` and the encoded pool data only. a fork run needs the owner as signer (factory is deprecated) and forge script cannot impersonate |
| how 0x4959, 0x866e, 0x7559, 0x636c were deployed | not in broadcast records. the registry agent owns provenance. script/live differences listed in S-07 are inferred |
| identity of 0x71cA…, 0xA358…, 0x8C72…, 0xed3e…, 0xb03c… | no verified source read. behavior inferred from calls and events only |
| full `forge build` of the project | blocked by an unrelated test/v2/harness compile error and the shared lock. scripts were type checked per file instead (no codegen, so stack too deep and size limits are untested; ci `forge build --sizes` covers those) |
| uncollected fee value in eth terms for the whole history | only the pending snapshot and one collect event were read; no full event scan |
| gas price and reward economics over time | single sample at 1.13 gwei and spot 4.9e-8 eth per coin |
| github secrets, branch protection, who can push tags | not visible from the repo |
| the legacy LAYER stack end to end | only balances and slots read; no simulation of processBurnWeth |
