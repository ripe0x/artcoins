# v2 mainnet fork harness

shared base for every v2 test. forks mainnet at one pinned block, deploys the current src stack on top of live uniswap v4, launches coins with the production config shape, and exposes the live deployed stack (coin 111 and friends) for attack tests.

## files

| file | what |
|---|---|
| `test/v2/harness/ForkBase.sol` | abstract `Test`. `forkMainnet()`, `skipUnlessFork()` / `onlyFork`, pinned `FORK_BLOCK`, infra + live address constants, `dealWeth`, `swapExactIn`, `addLiquidity`, `readSlot0`, `readLiquidity`. deploys `PoolSwapTest` + `PoolModifyLiquidityTest` on the fork. |
| `test/v2/harness/ForkStack.sol` | abstract, extends ForkBase. `deployFreshStack()`, `defaultLaunchParams()`, `launchToken(LaunchParams)`, `liveStack()`. |
| `test/v2/harness/Harness.t.sol` | proof suite (8 tests, 2 of them pin a hook bug as known issue). |

## usage

```solidity
import {ForkStack} from "../harness/ForkStack.sol";

contract MyV2Test is ForkStack {
    function setUp() public {
        forkMainnet(); // false + all tests skipped when rpc is down
    }

    function test_something() public onlyFork {
        deployFreshStack();                       // src stack, owner = stack.owner
        LaunchParams memory p = defaultLaunchParams();
        p.taxBps = 1500;                          // optional: 111 style buy tax
        Launched memory l = launchToken(p);       // token, key, id, positions
        skip(31 minutes);                         // past the mev skim window
        (, uint256 out) = swapExactIn(l.key, true, 1 ether, address(this), "");
        swapExactIn(l.key, false, out, address(this), "");
        LiveStack memory s = liveStack();         // live 0x4959.. stack
        swapExactIn(s.coin111Key, true, 0.1 ether, address(this), "");
    }
}
```

notes: ForkBase defines `receive() external payable virtual`; override, do not redeclare. `swapExactIn` pays from the test contract (native input topped up with `vm.deal`, erc20 input must be held) and forwards the realized output (net of any tax) to `recipient`. `addLiquidity` reverts while a skim mev window is open (the hook blocks public lp adds). the hook salt is mined against `address(this)`, so call `deployFreshStack()` from the test contract, not from a helper contract.

## run commands

```bash
source /tmp/claude-0/env.sh   # sets MAINNET_RPC_URL (defaults to tenderly public gateway)

# harness proof suite (forks itself via vm.createSelectFork at FORK_BLOCK)
/tmp/claude-0/forge.sh test --match-path "test/v2/harness/**" --skip "test/v2/review/**" --skip script -vv

# legacy style suites that need a cli fork: pin the block + retry
/tmp/claude-0/forge.sh test --fork-url $MAINNET_RPC_URL --fork-block-number 26130269 \
  --fork-retries 8 --fork-retry-backoff 2000 --skip "test/v2/review/**" --skip script \
  --match-path test/ArtCoinsHookSkimFeeForkTest.t.sol -vv
# same flags with --match-path test/MainnetLaunchRehearsalForkTest.t.sol

# no network / ci opt out: tests report as skipped
SKIP_FORK_TESTS=true /tmp/claude-0/forge.sh test --match-path "test/v2/harness/**" --skip "test/v2/review/**" --skip script -vv
```

| knob | effect |
|---|---|
| `MAINNET_RPC_URL` | rpc. unset or empty falls back to `https://mainnet.gateway.tenderly.co`. |
| `FORK_BLOCK` (env) | overrides the pinned block. leave unset so everyone shares the rpc cache. |
| `SKIP_FORK_TESTS=true` | never touch the network; every `onlyFork` test is skipped. |
| `--skip "test/v2/review/**" --skip script` | `forge test --match-path` still compiles every test and script file. one broken file anywhere (another agent's work in progress: seen `test/v2/review/hooks-mev/LiveStack.t.sol` and `script/v2/RunKeeper111.s.sol`) fails the whole build. skip what you do not need. |

`--fork-retries` / `--fork-retry-backoff` require `--fork-url` (forge 1.7.1 rejects them otherwise with "required arguments were not provided: --rpc-url"), and there is no `fork_retries` config key in this forge version, so tests that fork in `setUp` via cheatcode use foundry's default retry policy. the pinned block plus the on disk cache is what actually keeps call counts low.

## pinned block

| item | value |
|---|---|
| `FORK_BLOCK` | `26_130_269` (head `26_130_319` minus 50, read 2026-10-06 with `cast block-number`) |
| rpc cache | `~/.foundry/cache/rpc/mainnet/26130269/`. second and later runs read storage from disk. other agents forked at 26130300, 26130326, 26130368, 26130392: each block is a separate cold cache. everyone should use `FORK_BLOCK`. |

## address sources

| constant | value | source |
|---|---|---|
| POOL_MANAGER | 0x000000000004444c5dc75cB358380D2e3dE08A90 | fork tests, DeployV1Stack |
| WETH | 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 | DeployV1Stack |
| PERMIT2 | 0x000000000022D473030F116dDEE9F6B43aC78BA3 | DeployV1Stack, equals live locker.permit2() |
| POSITION_MANAGER | 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e | DeployV1Stack, equals live locker.positionManager() |
| UNIVERSAL_ROUTER | 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af | MainnetLaunchRehearsalForkTest, ui config. poolManager() verified. |
| STATE_VIEW | 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227 | NOT in repo (ui mainnet stateView is zero). uniswap canonical; verified on chain: poolManager() == PM, getSlot0(111 pool) answers. |
| LIVE_FACTORY | 0x49596c375c139E79bb937bcf826068a8F78D4e0e | owner table |
| LIVE_HOOK | 0x636c050296B5Cc528D8785169Bf8923716FCa9cc | owner table, = tokenDeploymentInfo(111).hook |
| LIVE_LOCKER | 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab | owner table, = tokenDeploymentInfo(111).locker |
| LIVE_ESCROW | 0x7559689765aE86cBB38e68CD1294830CccB125F2 | owner table, = hook.feeEscrow() = locker.feeLocker() |
| LIVE_MEV_SKIM | 0xb038D597365FfD108D63C265Bb0621444a1D8B83 | owner table, = hook.mevModule(111 pool) |
| LIVE_POOL_EXT_ALLOWLIST | 0xd6D5fb5CfE386d0eB73a09cba5d190beb802e6E8 | hook.poolExtensionAllowlist() (not in owner table) |
| COIN_111 | 0x61C9d89fe1212F6b55fF888816A151463287B8ae | owner table |
| OLDER_FACTORY | 0xF051cd4C4F3F36F9f24d8a19d60Ee8F84FC6793e | owner table |
| LEGACY_FACTORY | 0xD1595A2742C392d1c109b616b4F08918D02292f9 | owner table |
| LIVE_OWNER | 0xCB43078C32423F5348Cab5885911C3B5faE217F9 | owner table, verified owner() on all three factories |

## fresh stack: which script, and parity with the live factory

the live factory 0x4959.. matches `script/DeployV1Stack.s.sol` `deployStack()` (six contracts: factory, escrow, ext allowlist, skim hook, lean locker, linear skim mev). `DeployProtocolFeeStack` and `DeployNativeEthStack` do not match (static fee hook, BurnRouter as team recipient). no protocol fee controller is wired on the current stack, so the harness does not deploy one.

cast getters on the live stack at FORK_BLOCK vs DeployV1Stack:

| getter | live | DeployV1Stack | harness |
|---|---|---|---|
| factory.version() | "1" | "1" | "1" |
| factory.owner() | 0xCB43.. | deployer | test owner |
| factory.teamFeeRecipient() | 0xCB43.. (= owner) | deployer | test owner |
| factory.deployFee() | 0.069 eth | 0 (setDeployFee(0)) | 0.069 eth (reset after script wiring) |
| factory.defaultProtocolFeeBps() | 2000 | 2000 (default) | 2000 |
| factory.deprecated() | true | true (ctor) | false (harness opens it) |
| enabledHooks / enabledLockers / enabledMevModules | true / true / true | set | set |
| escrow.allowedDepositors(locker / hook) | true / true | added | added |
| locker.keeperRewardBps() | 0 | 0 | 0 |
| hook.factory / feeEscrow / weth / poolManager | factory / escrow / WETH / PM | same shape | same shape |

finding: the live deployFee (0.069 eth, the constructor default) disagrees with DeployV1Stack, which sets it to 0. either the deploy ran an older script revision or the owner re raised the fee after. the broadcast record for this factory does not exist (see registry notes), so the repo cannot tell which.

wiring order mirrored exactly: factory, escrow, allowlist, hook (mined), locker, mev; then `setTeamFeeRecipient`, `setDeployFee(0)`, `setHook`, `setLocker`, `setMevModule`, `escrow.addDepositor(locker)`, `escrow.addDepositor(hook)`, `locker.setKeeperRewardBps(0)`. harness only additions after that: `setDeployFee(0.069 ether)`, `setDeprecated(false)`.

hook flags: `BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | AFTER_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA` (from ArtCoinsHookSkimFeeForkTest). the fresh hook's low 14 bits equal the live hook's (asserted).

build profile caveat: tests compile at the default profile (optimizer_runs 20_000). production is built at `ci` / `tune` (200 runs). bytecode differs from live, semantics should not. the external `SkimFeeInitLib` is auto linked by forge and survives `vm.createSelectFork` in setUp (proven by the launch tests).

## launch defaults (`defaultLaunchParams`)

| field | value | source |
|---|---|---|
| pair | native eth, dynamic fee, tick spacing 200 | live 111 pool key, LaunchDefaults.TICK_SPACING |
| tickIfToken0IsArtCoins | -190_400 | LaunchLayer (EXPECTED_LP_LOWEST_TICK) |
| positions | 12 position thin floor taper | LaunchDefaults.buildLayerThinFloor12Positions (LaunchLayer) |
| rewards | 3800 artist / 4200 project + 2000 protocol slot appended by the factory | LaunchLayer ARTIST_BPS / PROJECT_BURN_BPS, factory default |
| skim fee data | lpFee 5000, baseline 6000, bounty 8333, maxRef 250 | live 111 `skimConfig` |
| mev skim | 90_000 -> 6000 over 30 min | live 111 `skimConfigs` on the linear skim module |
| bounty recipient | fresh `PreSwapStreamSink` contract (implements `streamForward`, like the live 111 bounty recipient 0x8C72..) | required: an eoa bricks the pool, see known issue |
| tax | off; `taxBps > 0` uses `deployTokenWithProtocolBpsAndTax` with max 2000, burn 0xdEaD, canonical = fresh hook | live 111 shape (111 uses 1500 / 2000, burn sink 0xf5c3eC7e185d0a592264791D523496EA6e368753) |

coin 111 live facts read at FORK_BLOCK: reward slots `[10000]` to 0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961 (admin 0xdEaD, so frozen), 14 positions, no protocol slot (deployed with protocolBps 0), token admin 0xA96a11257890ED1C43C16c098E286e18e45E6258, bounty recipient 0x8C72FBc2bB32e76aa54243F76745266a0F92CD01, protocol recipient 0xed3E9D3Bf693372060b7ce62aDB49650145b2ba9, referral payout 0xB03Cbd862F47059e928C113182814c676eA29d4c, total supply 1.11e27.

## proof suite results

run at FORK_BLOCK, 2026-10-06: **8 passed, 0 failed**. second run of the whole suite takes about 1.2s of test time (rpc cache warm); compile about 1 min if only harness files changed.

| test | proves |
|---|---|
| test_fork_pinnedBlock_liveStackWiring | block == FORK_BLOCK; live factory owner / deprecated / version / deployFee / enabled hook, locker, mev; escrow depositors; 111 pool key (native eth, dynamic fee, spacing 200, live hook) read from the live locker; pool initialized with liquidity; older + legacy factory owners |
| test_freshStack_wiringMatchesLive | fresh stack matches live on version, protocol bps, deployFee, teamFeeRecipient == owner, keeperRewardBps, hook permission bits, depositors |
| test_freshStack_launchBuySell_feeFlows | launch pays 0.069 eth deploy fee to team; 12 positions; t0 buy: bounty = baseline share + anti sniper extra, protocol leg escrowed (exact to 2 wei at 90% skim); post window buy baseline only; sell skims both legs; `locker.collectRewards` credits artist, project and protocol slot in eth and token; escrow `claim` pays out |
| test_freshStack_taxedLaunch_canonicalBuyUntaxed | 111 style taxed launch: hook auto detects tax, canonical buy pays no tax to the burn sink |
| test_freshStack_addLiquidity_blockedInWindow_openAfter | `addLiquidity` reverts inside the skim window, succeeds after (one sided eth range) |
| test_live111_buySell_skimCreditedToLiveRecipients | swap the real 111 pool with live bytecode: 0.1 eth buy credits bounty 0x8C72.. and escrows protocol for 0xed3E.. in LIVE_ESCROW, matching skimConfig math to 2 wei (baseline 6000, bounty 8333); sell back skims both legs again |
| test_knownIssue_eoaBountyRecipientBricksSwaps | see findings |
| test_knownIssue_fallbackBountyRecipientBricksSwaps | see findings |

skip behavior verified: `SKIP_FORK_TESTS=true` gives 8 skipped; `MAINNET_RPC_URL=http://127.0.0.1:9` gives skipped ("fork unavailable") in under 4s.

## findings from building the harness

| # | severity | finding | proof |
|---|---|---|---|
| 1 | high | `ArtCoinsHookSkimFee._beforeSwap` calls `try IPreSwapStream(br).streamForward() {} catch {}` once the bounty recipient holds >= 0.01 eth. solidity try/catch does not catch the caller side extcodesize check (eoa recipient: "call to non-contract address") nor the caller side return data decode (contract whose fallback returns nothing, e.g. a Safe). result: every swap on that pool reverts `HookCallFailed`, permanently, and anyone can trigger it by sending the recipient 0.01 eth. the IPreSwapStream natspec claims a non implementing recipient "can never brick a swap"; false. live 111 is not affected (its bounty recipient implements streamForward), but any future launch on the skim hook with an eoa or Safe bounty recipient is. fix: low level `call` with gas cap, ignore result, or `br.code.length != 0` plus returndata length check. | `test_knownIssue_*` (pinned as current behavior; flip when fixed) |
| 2 | low | `placeLiquidity` leaves wei level coin dust in the locker (8767 wei on the default 12 position launch). owner only sweep. | `test_freshStack_launchBuySell_feeFlows` asserts < 1e9 |
| 3 | info | live deployFee 0.069 eth vs DeployV1Stack setting 0 | cast, see parity table |
| 4 | info | mainnet StateView is not recorded anywhere in the repo (ui has zero) | cast |

## existing fork suites on the pinned block

| suite | command flags | result | cause of failures |
|---|---|---|---|
| test/ArtCoinsHookSkimFeeForkTest.t.sol | `--fork-url $MAINNET_RPC_URL --fork-block-number 26130269 --fork-retries 8 --fork-retry-backoff 2000` | 13 passed, 0 failed | none |
| test/MainnetLaunchRehearsalForkTest.t.sol | same | 10 passed, 1 failed | `test_rehearsal_s06_highSuccess_burnCadence` reverts `InsufficientLayerOut(1.043e24, 1.331e24)` in `BurnRouter.processBurnWeth(0)`. not rpc related: the suite deploys its own legacy LAYER stack, so the result is block independent. after 5 x 10 eth buys the burn swap at t=800s (still inside the 900s stepped sniper window) realizes about 78% of the spot derived floor (`_referenceFloor`), so the router's own floor rejects it. the floor ignores the pool fee plus sniper extra and the clamp. belongs to the locker/fees review. |

no 429s hit during these runs (pinned block, serialized runs). first run of a cold block pulls a few hundred rpc calls; later runs read the disk cache.

## rate limits

| symptom | cause | fix |
|---|---|---|
| `HTTP error 429` / `failed to get account` / `could not instantiate forked environment` | tenderly public gateway throttling, worst on a cold cache | pin the block (`FORK_BLOCK` or `--fork-block-number 26130269`) so reruns hit `~/.foundry/cache/rpc`; add `--fork-retries 8 --fork-retry-backoff 2000` with `--fork-url`; run suites serially (forge.sh already serializes); prefer one fork per test contract |
| harness tests "skipped" unexpectedly | rpc unreachable at setUp, `forkMainnet()` caught the revert | rerun; check `curl` probe from the preamble |
| tests hit live state drift | someone used a different block | always use `FORK_BLOCK` |

## proposed foundry.toml additions (not applied)

```toml
# fork profile: FOUNDRY_PROFILE=fork forge test --match-path "test/v2/**"
[profile.fork]
eth_rpc_url = "${MAINNET_RPC_URL}"        # set MAINNET_RPC_URL; ci falls back to tenderly in the workflow env
fork_block_number = 26130269              # keep equal to ForkBase.FORK_BLOCK
rpc_storage_caching = { chains = ["mainnet"], endpoints = "remote" }
no_storage_caching = false
compute_units_per_second = 100            # soft throttle for the public gateway
# retries: forge 1.7.1 has no fork_retries config key; pass --fork-retries 8 --fork-retry-backoff 2000 on the cli

[profile.ci]
# add so ci without network stays green and fast; the harness skips itself
# env: SKIP_FORK_TESTS=true (or leave network on and let the fork tests run)
```

and make `[rpc_endpoints] mainnet` fall back explicitly in scripts and ci: `MAINNET_RPC_URL=${MAINNET_RPC_URL:-https://mainnet.gateway.tenderly.co}`. note `[profile.fork]` with `eth_rpc_url` forks every test, including those that call `vm.createSelectFork` themselves; that is harmless (they create a second fork at the same pinned block, served from cache).
