# address wiring (job 2)

goal: every address bearing place reads from, or agrees with, `deployments/mainnet.json` (the registry, verified on chain). inventory comes from `registry-notes.md`; every row below was re-checked against the tree before editing. line numbers are the pre edit lines.

## how it is wired now

| piece | path | role |
|---|---|---|
| registry | `deployments/mainnet.json` | source of truth, checked by `node script-js/verify-registry.mjs` |
| generator | `script-js/gen-addresses.mjs` (`cd script-js && npm run gen:addresses`, `npm run check:addresses`) | writes the three files below, idempotent (no timestamps), `--check` exits 1 on drift and on a `ui/public/config.json` referrer that is not the registry payout wallet |
| solidity | `script/Addresses.sol` | library of constants `CURRENT_*`, `OPEN_*`, `LEGACY_*`, `COIN_*`, infra. header "generated from deployments/mainnet.json, do not edit" |
| ui | `ui/src/lib/deployments.generated.ts` | `STACKS`, `CURRENT`, `INFRA`, `COINS`, deploy blocks. `ui/src/lib/config.ts` imports it |
| readme | `README.md` between `<!-- deployments:start -->` and `<!-- deployments:end -->` | table of stack, status, factory, hook, locker, escrow, module, coins |
| shell and node | `script-js/sync-addresses.mjs --stack <id>`, `script/preflight-launch.sh`, `script/verify-stack.sh` | read the registry json directly (jq or node) |

guard rule for scripts that target a superseded stack: top comment "targets superseded stack <id>; current stack is 0x4959…", and on mainnet they revert unless `ALLOW_SUPERSEDED=1`.

## wrong or stale sites, what they said, what they say now

kind: wrong = pointed at the wrong contract or stated a false fact. stale = was true once. hard = correct value but unguarded or hand copied, now generated or guarded.

| # | file:line | kind | said | says now |
|---|---|---|---|---|
| 1 | `AGENTS.md:63-64` | wrong | "factory deployed 2026-05-18; see README for the current addresses" (no factory was deployed that day, readme had no addresses) | three factories, current `0x49596c37…4e0e` deployed 2026-06-06, points at the generated README table. new section "deployments and registry" |
| 2 | `README.md` (no section) | stale | no addresses anywhere | "Deployments" section, table generated from the registry, sentence that `deployments/mainnet.json` is the source of truth and `verify-registry.mjs` checks it |
| 3 | `README.md:83,86` | wrong | deploy with `forge script script/Deploy.s.sol ... --broadcast --verify` and "e.g. Deploy.s.sol, DeployNativeEthStack.s.sol, DeployProtocolFeeStack.s.sol" (these deploy the legacy and open stacks, the old token proxy flow) | table: v2 `script/v2/DeployV2Stack.s.sol` (coming, not in the tree), v1 `DeployV1Stack.s.sol` under `FOUNDRY_PROFILE=tune` marked superseded, the old scripts marked history only. example command is a dry run of DeployV1Stack |
| 4 | `README.md:29,55` | wrong | "up to 7 recipients" (the factory always appends the protocol slot, `MAX_REWARD_PARTICIPANTS = 7` counts it, so a deployer gets 6) | "up to 7 reward slots, one filled with the protocol slot", "up to 6 project recipients" |
| 5 | `README.md:11,44` | wrong | tokens "immutable", "construction-time configuration fixed for life" (admin can `updateAdmin`, `updateImage`, `updateMetadata`, `setMetadataRenderer`, `setTaxBps`) | not upgradeable, no proxy; supply, name, symbol, tax cap fixed; lists what the admin can still change |
| 6 | `README.md:16,54` | wrong | "default 20% of the protocol slice" (it is 20% of LP rewards, `defaultProtocolFeeBps = 2000`; the skim hook protocol leg is a different quantity) | "20% of LP rewards", noted as separate from the hook protocol leg |
| 7 | `README.md:17` | wrong | tax "a single deployment can switch on" (`deployTokenWithProtocolBpsAndTax` is public, nothing limits it to one deployment) | "a deployer can switch on at deploy time", nothing limits it |
| 8 | `README.md:5` | wrong | "ETH mainnet only" (no chain id guard in the contracts) | "built for Ethereum mainnet, no cross-chain code (the contracts do not enforce the chain id)" |
| 9 | `.env.example:25,31,34` | stale | "After running Deploy.s.sol, fill these with the addresses it printed", hook `NewMaterialHookStaticFeeV2`, locker `NewMaterialLpLockerMultiple` (pre rename names) | points at the registry and `sync-addresses.mjs --stack current`, names `ArtCoinsHookStaticFeeV2` / `ArtCoinsHookSkimFee`, `ArtCoinsLpLockerMultiple` / `ArtCoinsLpLocker`, notes the legacy launchers need `ALLOW_SUPERSEDED=1`. zero placeholders kept |
| 10 | `ui/src/lib/config.ts:28-44` | wrong | mainnet factory, hook, locker, mevLinearFees, mevDescFees, mevTimeDelay, vault, airdrop, devBuy, stateView, quoter all `ZERO`, the ui could not work on mainnet | factory `0x4959…4e0e`, hook `0x636c…a9cc`, locker `0x866e…6aab`, escrow `0x7559…25F2` (new field), mevLinearFees slot = skim module `0xb038…8B83`, stateView `0x7fFE…7227`, weth, poolManager, router, permit2 from `INFRA`. vault, airdrop, devBuy, mevDescFees, mevTimeDelay, quoter stay `ZERO`: no current stack deployment (they exist only on the legacy factory) |
| 11 | `ui/src/lib/config.ts:78-80` | wrong | factory deployment block `1: 0n` (genesis scans, rate limited) | `STACKS.current.deployBlock` = 25260062 from the registry |
| 12 | `ui/src/lib/config.ts:70-72` | wrong | `getAddresses` returned the sepolia stack for any unknown chain, so a mainnet user on an odd chain would be pointed at sepolia contracts | throws `Unsupported chain <id>`; `isSupportedChain` added. wagmi only offers mainnet and sepolia so the throw is a backstop |
| 13 | `ui/src/lib/config.ts:84` | wrong | `getFactoryDeploymentBlock` fell back to `0n` for unknown chains | throws like `getAddresses` |
| 14 | `ui/src/lib/config.ts:47-63` | stale | sepolia stack of 2026-04-15, factory `0x3c3aEfC8…` matches no sepolia broadcast record | values unchanged on purpose (code exists on sepolia, abi is stale anyway, sepolia is not in the registry). comment says stale, latest rehearsal factory `0xe18d3bec…`, not verified by the registry. `escrow` is `ZERO` there |
| 15 | `script/DeployConversionLockerAndWire.s.sol:58-61` | wrong | FACTORY `0xF051…` (open, superseded), HOOK `0xAAd6…`, ESCROW `0xDD1b…`, MEV_LINEAR_FEES `0xAe19…` (a legacy stack module, not even in the open stack) | `Addresses.CURRENT_FACTORY`, `CURRENT_HOOK`, `CURRENT_ESCROW`, `CURRENT_MEV_LINEAR_SKIM`. constant names kept (the fork test reads them). `run()` and `allowlistExtension()` now require chain id 1 |
| 16 | `script/DeployConversionLockerAndWire.s.sol:63-64` | hard | literal position manager and permit2 | `Addresses.POSITION_MANAGER`, `Addresses.PERMIT2` |
| 17 | `script/DeployPCController.s.sol:7-8,36-41` | stale | "Reuses the EXISTING LAYER BurnRouter", mainnet router `0x2edbdf01…` (the live PC controller `0xd8C6…` uses `0x0EB22955…`) | doc says `0x0EB2…`; `LAYER_BURN_ROUTER` defaults to `Addresses.CURRENT_BURN_ROUTER` on mainnet and the script logs a warning for any other router |
| 18 | `script/BindProtocolFeeController.s.sol` (no literals) | hard | acted on whatever `FACTORY` env held. on 0x4959 that redirects the 0.069 eth deploy fee and every default protocol slot | mainnet factory must be in the registry; current needs `CONFIRM_REWIRE=1` and the registry controller; open or legacy need `ALLOW_SUPERSEDED=1`. top comment added |
| 19 | `script/LaunchLayer.s.sol:65-71,82` | hard | literal weth, universal router, permit2, pool manager; no marker that it targets the legacy stack (LAYER, legacy factory abi) | infra from `Addresses`, top comment, `run()` reverts on mainnet without `ALLOW_SUPERSEDED=1` (tests call `launch()`, unaffected) |
| 20 | `script/LaunchTestToken.s.sol`, `LaunchLLToken.s.sol`, `LaunchLLTokenSimple.s.sol`, `LaunchArtTest.s.sol` | hard | env driven, legacy factory abi, would revert at pool init on the skim hook, no mainnet guard. `LaunchArtTest.s.sol:34` literal weth | top comment, `ALLOW_SUPERSEDED=1` guard on mainnet, weth from `Addresses.WETH` |
| 21 | `script/LaunchDynamicToken.s.sol:21-25` | stale | sepolia stack `0x3c3aEfC8…` presented as "from config.ts", no chain guard | addresses unchanged (same as ui sepolia block), comment says not in the registry, `run()` requires chain 11155111 |
| 22 | `script/preflight-launch.sh:13` | hard | "requires .env with all the addresses LaunchLayer reads" (hand copied, no stack check) | on chain id 1 refuses without `ALLOW_SUPERSEDED=1`, fills any unset address var from the registry stack `legacy` with jq. operator values win |
| 23 | `script/verify-stack.sh:49-70,93,98-99` | wrong | `SRC_PATH` pointed at moved files, `ArtCoinsFactory` mapped to the new source while Deploy broadcast the legacy one, only two broadcasts walked (the current stack has no record), `|| true` made it exit 0 when every verify failed, api key passed on argv | mainnet reads the registry: verifies every contract of `--stack` (default current) with `bytecodeMatch` verified, profile `ci` where the registry says so, links `ArtCoinsDeployer` and `SkimFeeInitLib`, exits 1 on any failure, key from env only, `--dry-run`. sepolia keeps the broadcast walk with failure counting |
| 24 | `script-js/sync-addresses.mjs:25-95` | wrong | read `broadcast/*/run-latest.json` (can only produce legacy and open stacks, never the current one), patched `../artcoins/src/lib/launcher/config.ts` in a sibling repo, rewrote `.env`, knew `NewMaterialHookStaticFeeV2` | prints `export VAR=addr` for a registry stack (`--stack`, `--json`). writes nothing |
| 25 | `script/FullDryRun.s.sol:55-67`, `SetUpLayerAutoForward.s.sol:59-65`, `TraceTestTokenFees.s.sol:39-44`, `LiveNoOpVerify.s.sol:26-30`, `LiveSellVerify.s.sol:25-29`, `LiveSwapVerify.s.sol:31-35`, `MigrateLayerRenderer.s.sol:34-38` | hard | LAYER, legacy hook, locker, fee locker, controller, burn router `0x2eDB…`, autoforward extension, weth, pool manager, scripty, owner typed as literals, no marker, no guard. `Live*Verify` do real mainnet swaps | constants point at `Addresses.COIN_LAYER`, `LEGACY_*`, `WETH`, `POOL_MANAGER`, `SCRIPTY_*`, `OWNER` (names kept). top comment "targets superseded stack legacy (LAYER)", `run()` calls `_requireSupersededAllowed()` (chain id 1 needs `ALLOW_SUPERSEDED=1`). `MigrateLayerRenderer.s.sol:36` called renderer `0x93bD…` live, that is the v0 renderer, the live one is `0x0572…` (`LEGACY_LL_RENDERER`) |
| 26 | `script/Deploy.s.sol:49-64`, `DeployV1Stack.s.sol:83-92`, `PreflightLaunch.s.sol:41-44,162`, `PrepareLayerLaunch.s.sol:58,104-111`, `DeployLLOnchainRenderer.s.sol:38-39`, `DeployNativeEthStack.s.sol:128`, `RedeployHook.s.sol:25`, `SwapMonaAsset.s.sol:24`, `UpgradeLLMona.s.sol:40`, `VerifyLLRenderer.s.sol:51-52`, `PreviewLLAnimation.s.sol:44` | hard | mainnet pool manager, position manager, weth, universal router, permit2, create2 deployer, scripty builder and storage typed by hand | `Addresses.POOL_MANAGER`, `POSITION_MANAGER`, `WETH`, `UNIVERSAL_ROUTER`, `PERMIT2`, `CREATE2_DEPLOYER`, `SCRIPTY_BUILDER`, `SCRIPTY_STORAGE`. sepolia literals stay (sepolia is not in the registry) |
| 27 | `Deploy.s.sol`, `DeployNativeEthStack.s.sol`, `DeployProtocolFeeStack.s.sol`, `RedeployBurnRouter.s.sol`, `RedeployHook.s.sol`, `DeployBurnExtension.s.sol`, `DeployMevSniperSteppedFees.s.sol`, `PrepareLayerLaunch.s.sol`, `SmokeTestLLCounter.s.sol`, `DeployLLExtension.s.sol`, `FixLLSketchAsset.s.sol`, `SwapMonaAsset.s.sol`, `UpgradeLLMona.s.sol`, `DeployLLOnchainRenderer.s.sol` | hard | act on the legacy or open stack (env `FACTORY`, `HOOK`, LAYER renderer), no marker, no mainnet guard. `RedeployBurnRouter` and `DeployBurnExtension` could rewire a live factory | top comment "targets superseded stack ...", `run()` reverts on chain id 1 unless `ALLOW_SUPERSEDED=1`. `PreflightLaunch.s.sol` is read only: comment, no guard. `DeployV1Stack.s.sol` builds the skim stack, not guarded (readme marks it superseded once the v2 deploy lands) |
| 28 | `ui/public/config.json:3` | ok | defaultReferrer `0x41c3BD8A…A6A4` | unchanged. `gen-addresses.mjs` now fails if it differs from the registry `PassThroughWallet` (the payout wallet) |
| 29 | `script/LaunchDefaults.sol` | ok | holds no addresses (ticks, fees, lp presets) | unchanged |

count: 27 rows (rows 1 to 27, about 60 file sites) were wrong, stale or hand copied and are fixed. rows 14 and 21 are labelled and guarded rather than repointed, row 12 is a code fix. 2 rows were checked and are correct (28, 29). rows 25 to 27 were finished after the container restart: 32 scripts import `Addresses.sol`, 28 carry the top comment and 27 refuse chain id 1 without `ALLOW_SUPERSEDED=1` (the 28th, `PreflightLaunch`, is read only).

top ones by blast radius: row 10 (ui dead on mainnet), row 15 (wiring script aimed at the open factory), row 23 (verify script exited 0 on failure and never saw the current stack), row 24 (sync wrote legacy addresses into `.env`), row 18 (bind script could redirect the live 0x4959 fee recipient), row 3 (readme sent operators to the legacy deploy).

## remaining occurrences of superseded stack addresses (grep of every open and legacy registry address, outside lib, broadcast, build output)

| where | why it stays |
|---|---|
| `script/Addresses.sol`, `README.md` table, `ui/src/lib/deployments.generated.ts` | generated from the registry |
| `deployments/mainnet.json` | the registry |
| `docs/v2/**` (registry-notes, RUNBOOK, DESIGN, SYSTEM-REVIEW, STATUS, review notes, harness) | prose about the superseded stacks (deprecating 0xf051, LAYER ops). correct against the registry |
| `script/DeployConversionLockerAndWire.s.sol:62-63`, `DeployPCController.s.sol:16`, `DeployV1Stack.s.sol:19,54` | comments that name the superseded address on purpose |
| `test/AutoBurnOpenTabForkTest.t.sol`, `FeeAutoSwapperLayerRetrofit.t.sol`, `LiquidityLayerAutoForwardExtensionForkTest.t.sol`, `test/v2/harness/ForkBase.sol`, `test/v2/review/**` | fork tests pinned to the open and legacy stacks. correct, not mine to edit |
| `script/v2/RunKeeper111.s.sol:12-15` | current stack literals, equal to the registry, owned by another package. could take `Addresses.CURRENT_*` |
| `LEGACY_*` and `OPEN_*` uses in `LaunchLayer`, `Launch*Token`, `BindProtocolFeeController`, `DeployConversionLockerAndWire`, `FullDryRun`, `SetUpLayerAutoForward`, `TraceTestTokenFees`, `Live*Verify`, `MigrateLayerRenderer` | read from the generated library, correct by construction, guarded |
| `ui/src/pages/FeeFlowPage.tsx:63-78` | sepolia rehearsal snapshot (page says hardcoded, sepolia etherscan links). not a mainnet address, left as is |
| `script/LaunchDynamicToken.s.sol:24-28`, `ui/src/lib/config.ts` sepolia block, `SwapLiquidityLayerSepolia.s.sol`, `Smoke*Sepolia.s.sol`, sepolia constants in `Deploy.s.sol`, `PreflightLaunch.s.sol`, `LaunchLayer.s.sol` | sepolia, not in the registry, labelled |
| `script-js/scan-burns.mjs`, `scan-liquidity-layer.mjs` (`0x6B19…`), `scan-token-burns.mjs`, `scan-token-zero-burns.mjs` (`0x5a34…`) | one off scan helpers on addresses that are in no registry stack. not touched |
| `script-js/gen-addresses.mjs` infra table | the one place external infra (pool manager, weth, router, scripty) is typed, feeds `Addresses.sol` and the ui |

## not fixed, on purpose

| item | note |
|---|---|
| ui abi is stale (ui review UI-03) | the factory `deployToken` abi lacks `renderer` and `sniperFeeConfig`, the encoded selector is `0xdf40224a`, the live one is `0x3f1638ea`, so a deploy from the ui reverts on every live factory. this job only fixed addresses. package u1 fixes the encoding. the `mevLinearFees` slot on mainnet is now the skim module, whose `mevModuleData` differs from the linear fees module, u1 must encode for it. `escrow` is exposed in `ContractAddresses` but unused until u1 |
| ui does not list the legacy factory | LAYER (legacy factory `0xD159…`) is invisible to coin discovery. `STACKS.legacy` and `COINS` are in the generated file for u1 to use |
| `DeployConversionLockerAndWire` preflight `!deprecated` | the current factory is deprecated (owner only), so phase 1 fails closed on it. the current stack already has locker `0x866e…`, so nothing needs the script. renounce and post asserts untouched (S-01, S-08 follow up) |
| `foundry.toml:32-37` stale hook size comment, `.github/`, `.gitignore`, `src/`, `test/` | other owners |
| sepolia stack | not in the registry, left as is and labelled |

## verification

| check | command | result |
|---|---|---|
| idempotent | `cd script-js && node gen-addresses.mjs` twice | second run prints `same` for all three files; `node gen-addresses.mjs --check` exit 0 |
| registry shape | `node script-js/verify-registry.mjs --shape` | schema ok |
| ui types | `ui/node_modules/.bin/tsc --noEmit -p ui/tsconfig.app.json` | no error in `config.ts` or the generated file (other errors predate this job) |
| scripts compile | `/tmp/claude-0/forge.sh build --skip "test/**" --skip "src/v2/hooks/**"` | compiler run successful, 256 files. skipped for other packages: `src/v2/hooks/ArtCoinsHookV2.sol` (error 7615, `tstore`/`tload` on a non number constant) and `test/**` (`test/v2/mocks/FactoryV2Mocks.sol` `constantsHash` mutability). `--skip test` alone does not skip `test/v2` |
| regen after the restart | `cd script-js && node gen-addresses.mjs` and `--check` | `same` for all files, exit 0. `Addresses.sol` block numbers carry underscores (`25_260_062`), the generator was changed to match by the hygiene job |
| superseded grep | all 39 open and legacy registry addresses over the tree minus `lib`, `broadcast`, `foundry-out` | hits are the generated files, the registry, docs, fork tests, guarded LAYER scripts and comments, all listed above |
