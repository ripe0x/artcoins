# ui e2e on a mainnet fork

first time the ui ran in a real browser. chromium (playwright 1.56.1) against `npm run dev`, reads and writes
through a local anvil fork of mainnet at block 26130269. harness in `ui/e2e/`, how to run it in `ui/README.md`
(section e2e). nothing under `ui/src/` was changed: every ui bug below has a repro and a proposed diff, not applied.

## setup that ran

| item | value |
|---|---|
| fork | `anvil --fork-url $MAINNET_RPC_URL --fork-block-number 26130269 --port 8545 --compute-units-per-second 100 --chain-id 1` (tenderly gateway, no 429 seen) |
| ui | vite dev server, `VITE_MAINNET_RPC_URL=http://127.0.0.1:8545`, dummy `VITE_WALLETCONNECT_PROJECT_ID`, no `ui/.env`. port 5181 without v2, port 5182 with `VITE_V2_*` of a fork deployed v2 stack |
| rpc override | the ui hardcodes no public rpc for reads: `main.tsx` uses `VITE_MAINNET_RPC_URL`, else the tenderly gateway. the v4 quoter address is typed in `config.ts` (not in the registry) |
| wallet | `window.ethereum` shim injected with `addInitScript`, announced over EIP-6963. rainbowkit lists it as "E2E Wallet" and connects through it (no blocker). requests go to node via `exposeFunction`: accounts, chain id 1, `personal_sign` / `eth_signTypedData_v4` signed by a viem local account, `eth_sendTransaction` signed locally and sent raw (or anvil impersonation for live addresses), everything else forwarded to anvil |
| test keys | deterministic `keccak("artcoins-ui-e2e:<label>")`, funded by a real transfer from anvil account 1. anvil default accounts carry a mainnet eip-7702 sweeper delegation, so none is used as a trader |
| v2 stack | `script/v2/DeployV2Stack.s.sol` broadcast on the fork with OWNER = anvil account 0 (its delegation removed with `anvil_setCode` first). factory 0xAbFd91B16D77a1F62Fe00Dea5aE6478bCc9c7615, hook 0x907BaF32C72C254989599cD2bFEAC63B582e2Dcc, locker 0xf268088a5b9f52445eb0C7C19ad78a0793Ca8943, escrow 0x17d9d652E2FD969cDfdb4eC7a71137BDd9aada95, mev 0x568F9FaCFB8a10dAEeF0928B33a856Db03E217DB. fork only addresses. post deploy asserts ok |
| isolation | global setup takes `evm_snapshot`, teardown `evm_revert`: every run starts from the same fork state |

## results

final run: 19 tests, 14 passed, 5 "expected to fail" (`test.fail`, known ui gaps, they flip to a failure once fixed). 1.7 min.

| # | scenario | result | evidence |
|---|---|---|---|
| 1 | token list loads, shows 111 | pass | discovery from registry deploy block 25260062 to head: one card, `permanent collection` / `111`, badge `artcoins factory v1`, `block 25275351`, "1 token total" |
| 2a | 111 page, rpc with a 60M eth_call cap (anvil default) | pass, with a finding | name, symbol, supply 1,110,000,000, admin 0xA96a…6258, factory, renderer 0x7604…eEc7, creator flag "not set", pair native ETH, tick spacing 200, fees 0.50% lp + 6.00% skim, bounty 83.33%, protocol 16.67%, referral cap 0.25%, lp recipient 0xeBD9…A961 100%. no image: `contractURI()` needs ~180M gas (UI-E2E-06) |
| 2b | 111 page, rpc that runs the renderer (block gas 250M) | pass | image `data:image/svg+xml;base64,…`, `referrerpolicy=no-referrer`, description from the on chain json, metadata modal opens |
| 2c | no self asserted verified badge | pass | only badge next to the title is `artcoins factory v1`; `isVerified()` false shows as the "creator flag" row, no badge element mentions verified |
| 3 | buy 111 with 0.01 eth, sell half back, native pool | pass | buy: quote 180,553.40, floor 178,747.87 (1%), impact 6.54% (fees included), wallet paid 0.010299 eth incl gas, coin balance up. calldata decoded: `execute(0x10, …)`, actions `0x060c0f`, zeroForOne true, amountIn 0.01e18, hooks = current hook. sell half: permit2 approve then swap, both success, coin balance exactly halved, eth back, permit2 allowance spent to 0. `Swap confirmed in block N` shown |
| 3 | hookData refund address | pass (v1 by design, v2 asserted) | 111 is on the v1 skim hook: hookData = `PoolSwapData{mevModuleSwapData: 0x, poolExtensionSwapData: PCSwapData{referrer 0x41c3…A6A4, referralBps 250}}`, no refund address, as the widget intends (only v2 hooks read it). on the fork launched v2 coin (5b) buy and sell carry `mevModuleSwapData = abi.encode(wallet)`, asserted |
| 3b | sell more than the balance | expected fail, bug | UI-E2E-02 |
| 4a | LAYER through the widget | expected fail, gap | `/tokens/0xb728…E6c9` says "Token not found": discovery reads only the current (and v2) factory. UI-E2E-01 |
| 4b | LAYER weth path, the ui's own calldata (`buildBuyCalldata` / `buildSellCalldata` weth branch) sent on the fork | pass | first fork run of the weth path. buy `WRAP_ETH` + `V4_SWAP[SWAP, SETTLE(weth, payerIsUser false), TAKE_ALL]`: 0.01 eth -> 160,424.51 LAYER (= quote), gas 739,876. sell `V4_SWAP[SWAP, SETTLE_ALL, TAKE(weth, router)]` + `UNWRAP_WETH(me)`: all coins -> 0.009801 eth (= quote). router left with 0 weth, 0 eth. LAYER pool: LAYER currency0, weth currency1, legacy hook 0xA5eA…28cc, hookData `0x` |
| 5a | deploy page, no v2 configured | pass | status "Launching is closed … Launches are owner only on the current factory (its deprecated() flag is set) …", deploy fee 0.069 eth and "Public launches: closed" read from the factory, send button disabled with that reason after a filled form and a connected wallet. no tx sent |
| 5b | v2: stranger blocked while deprecated | pass | factory bar: deploy fee 0.069, protocol slot 20%, min skim share 10%, min lp fee 0.3%, closed. send disabled "owner only". wording bug UI-E2E-04 |
| 5b | v2: after `setDeprecated(false)` (owner tx) the form validates | pass | byte caps: 🎨 name over the cap -> "name is N bytes, the cap is 64" (bytes, not characters), symbol likewise. min lp fee: slider min is 0.3, a lower value is clamped by the input (cannot be typed). referral cap max: bounty 90% -> "referral cap is above the maximum of 0% of volume", "Set it to 0%" clears it; at 83.33% the cap slider max is 0.4 = 6% x (100 - 83.33 - 10)%. exempt allowlist: weth as venue exempt -> "not allowed by the launcher owner", send disabled ("N problems to fix above") |
| 5b | v2: launch tx through the ui | pass | `Deploy token (0.069 ETH)`, simulated then sent, value 0.069 eth, gas 4,417,162, `TokenCreatedV2`, `isArtCoin` true, "Token launched" with the address. new coin listed as `artcoins factory v2` |
| 5b | v2 coin buy and sell through the widget | pass | anti sniper active (68.57%), widget asks to acknowledge the 70.7% impact, buy and sell succeed, refund address in hookData. fee legs pushed (escrowed false): bounty 0.006763, protocol 0.0000922, referral 0.0000078 eth to 0x41c3…A6A4 |
| 5b | v2 coin referral page | pass, copy bug | `EscrowClaim` reads `escrow.balances(referrer, 0)`: 0 for the wallet (button "Claim 0 ETH" disabled) and 0 for the default referrer, because the hook pushed the referral directly (D59). UI-E2E-05 |
| 5b | known bugs | expected fail x3 | UI-E2E-03, -04, -05 |
| 6 | `?ref=` sticky indicator | pass | `?ref=0x…f00d1` -> "Referred by 0x0000…00d1 (from your link)"; same tab without `?ref` -> "(from an earlier link this session)"; `?ref=0xdead` -> "ignored ?ref: …", remembered referrer kept; a buy carries it in hookData; "Don't use a referrer" -> hookData `0x`; a new browser session -> "(site default)" 0x41c3…A6A4 from `/config.json` |
| 6 | referral claim reads the ledger | pass | 111's `skimConfig.referralPayout` is 0xB03C…9d4c (registry "UnverifiedPcContract"). stranger: "Claim 0 ETH" disabled. default referrer (impersonated): "Claim 0.060669281850572299 ETH", disabled until the "chosen by this token's deployer" box is ticked, claim succeeds, ledger to 0, referrer receives exactly the balance (net of its gas), button back to "Claim 0 ETH" |
| 7 | claim page renders | pass | `/tokens/111/claim`: "No allowlist found … /allowlists/0x61c9….json", renders with and without a wallet, malformed address -> "Not a token address.", no page errors |

console: no application errors or uncaught exceptions in any test. the only errors are sandbox noise, filtered and
kept in `ui/e2e/artifacts/*.console.json`: walletconnect / reown remote config and pulse (dummy project id, the
sandbox proxy's tls), `https://example.com/e2e.png` (same), and the "Lit is in dev mode" warning.

## ui bugs

| id | severity | where | what |
|---|---|---|---|
| UI-E2E-01 | medium (product gap) | `lib/discovery.ts`, `pages/TokenDetailPage.tsx` | legacy LAYER (and any non current, non v2 coin) has no page and no widget, though `classifyPool` and the weth calldata work (4b). the detail page also hardcodes "Pair: native ETH" |
| UI-E2E-02 | low, wrong state | `components/SwapWidget.tsx` 217-223 | sell with an amount above the balance: the permit2 step wins over the balance check, the button reads "2. Let the router spend it for 10 minutes" and is enabled; the user can sign a useless permit2 approval and never sees "Insufficient 111". same for step 1 (disabled but labelled "Approve") |
| UI-E2E-03 | medium, wrong units of time | `pages/TokenDetailPage.tsx` 169, `components/SwapWidget.tsx` 218, 244 | chain deadlines compared with the browser clock. on the fork (chain clock 9 h behind the wall clock) an active anti sniper window reads "Time remaining: expired" and "decaying to the baseline in expired". on mainnet a browser clock that runs behind by more than deadline + 5 min signs a permit2 approval that is already expired on chain, the swap simulation reverts (AllowanceExpired) and the widget keeps offering "Sell" because its own `nowSec` says the approval is fine: a stuck state |
| UI-E2E-04 | low, copy | `pages/DeployPage.tsx` 166 | with a v2 stack the deprecated notice says "owner only on the current factory": it is the v2 factory |
| UI-E2E-05 | medium, copy contradicts the contracts | `components/EscrowClaim.tsx` 70, `components/PoolConfigForm.tsx` 93, `components/ReviewAndDeploy.tsx` 159 | the ui says v2 referral fees are "credited to the referrer in the fee escrow" and claimed from there (D57). D59 and `ArtCoinsHookV2._leg` push the referral straight to the referrer; the escrow holds only failed pushes. on the fork the referral leg was pushed (escrowed false) and the escrow balance stayed 0, so a referrer reading the page sees "Claim 0 ETH" and is told that is its earnings |
| UI-E2E-06 | low to medium, rpc dependent | `pages/TokenDetailPage.tsx` 79-110, 330 | `contractURI()` of 111 needs ~180M gas and returns ~633 KB (on chain svg). it is batched in the same multicall as name, supply, admin, renderer and `skimConfig`. an rpc with geth's default 50M `rpc.gascap` (or anvil's 60M) drops the image and description silently; a slow node holds the whole token card: on anvil the call takes ~30 s and meanwhile Supply shows "…", Admin "—", Fee distribution "Loading…", and Renderer "default (on-chain)", which is false (111 has renderer 0x7604…eEc7). tenderly answers in ~1 s, so the default config is fine |
| UI-E2E-07 | cosmetic | `pages/TokenDetailPage.tsx` image button | an image url that fails to load is hidden by `onError` and leaves an empty box instead of the symbol placeholder (seen on the v2 coin with an unreachable https image) |

not bugs, recorded so nobody chases them:

| item | note |
|---|---|
| step "1. Approve exactly … to Permit2" never shows for artcoins coins | the tokens give permit2 an infinite allowance (`allowance(x, permit2) = 2^256-1`), so the exact amount policy applies only to permit2 -> router, which the e2e confirms is spent to 0 after the sell |
| v2 referral leg smaller than `0.25% x 0.01 eth` | the hook computes the referral on the volume after the anti sniper skim (0.003137 eth here), contract side, not ui |
| default launch fdv 0.099 eth | `DEFAULT_STARTING_TICK = -230400` at 1B supply, documented in `launchDefaults.ts` |

## proposed patches (not applied)

UI-E2E-02, balance before approvals:

```diff
--- a/ui/src/components/SwapWidget.tsx
+++ b/ui/src/components/SwapWidget.tsx
-  const needsErc20Approval = direction === 'sell' && amountInWei > 0n && ((erc20ToPermit2 as bigint | undefined) ?? 0n) < amountInWei;
+  const needsErc20Approval =
+    direction === 'sell' && amountInWei > 0n && !overBalance && ((erc20ToPermit2 as bigint | undefined) ?? 0n) < amountInWei;
   const nowSec = Math.floor(Date.now() / 1000);
   const needsPermit2Approval =
     direction === 'sell' &&
     amountInWei > 0n &&
+    !overBalance &&
     !needsErc20Approval &&
     (permit2Amount < amountInWei || permit2Expiration < nowSec + deadlineMin * 60);
```

UI-E2E-03, chain clock for chain deadlines:

```diff
--- a/ui/src/components/SwapWidget.tsx
+++ b/ui/src/components/SwapWidget.tsx
 import {
   useAccount,
   useBalance,
+  useBlock,
   usePublicClient,
@@
-  const nowSec = Math.floor(Date.now() / 1000);
+  // permit2 compares expirations with block.timestamp, never with the browser clock
+  const { data: head } = useBlock({ query: { refetchInterval: QUOTE_REFRESH_MS } });
+  const nowSec = head ? Number(head.timestamp) : Math.floor(Date.now() / 1000);
@@
   const handleApprovePermit2 = async () => {
-    if (!permit2 || !router) return;
+    if (!permit2 || !router || !client) return;
@@
-      const expiration = Math.floor(Date.now() / 1000) + (deadlineMin + 5) * 60;
+      const block = await client.getBlock();
+      const expiration = Number(block.timestamp) + (deadlineMin + 5) * 60;
--- a/ui/src/pages/TokenDetailPage.tsx
+++ b/ui/src/pages/TokenDetailPage.tsx
-import { useReadContract, useReadContracts } from 'wagmi';
+import { useBlock, useReadContract, useReadContracts } from 'wagmi';
@@
-  const mevRemaining = mevEnd !== undefined ? Math.max(0, mevEnd - Math.floor(Date.now() / 1000)) : undefined;
+  const { data: head } = useBlock({ query: { refetchInterval: 12_000 } });
+  const chainNow = head ? Number(head.timestamp) : Math.floor(Date.now() / 1000);
+  const mevRemaining = mevEnd !== undefined ? Math.max(0, mevEnd - chainNow) : undefined;
```

UI-E2E-04:

```diff
--- a/ui/src/pages/DeployPage.tsx
+++ b/ui/src/pages/DeployPage.tsx
   else if (state.deprecated && !isOwner)
-    pageBlock = 'Launches are owner only on the current factory (deprecated() is true). Only the factory owner can launch until it is reopened.';
+    pageBlock = 'Launches are owner only on the v2 factory (deprecated() is true). Only the factory owner can launch until it is reopened.';
```

UI-E2E-05, copy that matches D59:

```diff
--- a/ui/src/components/EscrowClaim.tsx
+++ b/ui/src/components/EscrowClaim.tsx
-        <p className="font-medium text-zinc-100">Referral earnings are claimed from the fee escrow</p>
+        <p className="font-medium text-zinc-100">Referral earnings that could not be delivered</p>
         <p>
-          On this coin the hook does not send referral fees to a wallet. It credits the referrer in the fee escrow, as ETH. The claim is{' '}
+          On this coin the hook sends each referral fee straight to the referrer, in ETH, during the swap. Only a payment the referrer could not
+          receive (a contract that rejects ETH with 2,300 gas) is credited in the fee escrow, and that balance is claimed here. The claim is{' '}
--- a/ui/src/components/PoolConfigForm.tsx
+++ b/ui/src/components/PoolConfigForm.tsx
-... Maximum for these fees: ${capMax}% of volume = baseline skim x (100% - bounty share - ${protocolFloorPct}%). Referrers claim their earnings from the fee escrow.`} />
+... Maximum for these fees: ${capMax}% of volume = baseline skim x (100% - bounty share - ${protocolFloorPct}%). Referrers are paid in ETH during each swap.`} />
--- a/ui/src/components/ReviewAndDeploy.tsx
+++ b/ui/src/components/ReviewAndDeploy.tsx
-            value={`${pct(form.pool.referralCapPercent, 3)} of volume (maximum for these fees ${pct(…, 3)}), claimed from the fee escrow`}
+            value={`${pct(form.pool.referralCapPercent, 3)} of volume (maximum for these fees ${pct(…, 3)}), paid to the referrer on each swap`}
```

UI-E2E-06, the renderer call on its own and honest placeholders:

```diff
--- a/ui/src/pages/TokenDetailPage.tsx
+++ b/ui/src/pages/TokenDetailPage.tsx
       { address: t, abi: tokenV1Abi, functionName: 'metadata' },
-      { address: t, abi: tokenV1Abi, functionName: 'contractURI' },
       { address: t, abi: tokenV1Abi, functionName: 'isVerified' },
       { address: t, abi: tokenV1Abi, functionName: 'metadataRenderer' },
@@
-  const contractURI = r(6) as string | undefined;
-  const creatorConfirmed = r(7) as boolean | undefined;
-  const metadataRenderer = r(8) as Address | undefined;
-  const skim = normalizeSkim(r(9));
+  const creatorConfirmed = r(6) as boolean | undefined;
+  const metadataRenderer = r(7) as Address | undefined;
+  const skim = normalizeSkim(r(8));
+  // an on chain renderer can cost ~180M gas and return hundreds of kB: never let it hold the token card,
+  // and expect rpcs with a 50M eth_call cap to refuse it (the card then falls back to imageUrl)
+  const { data: contractURI } = useReadContract({
+    address: record?.token,
+    abi: tokenV1Abi,
+    functionName: 'contractURI',
+    query: { enabled: !!record, staleTime: 300_000, retry: 1 },
+  });
@@
-            value={metadataRenderer && metadataRenderer !== ZERO ? <CopyableAddress … /> : <span className="text-zinc-500">default (on-chain)</span>}
+            value={
+              metadataRenderer === undefined
+                ? readsLoading ? '…' : '—'
+                : metadataRenderer !== ZERO ? <CopyableAddress … /> : <span className="text-zinc-500">default (on-chain)</span>
+            }
```

UI-E2E-07: keep an `imgFailed` state, set it in `onError`, render the symbol placeholder when it is set.

UI-E2E-01 needs a decision first (list legacy coins or not). if yes: have `script-js/gen-addresses.mjs` emit the
legacy and open stacks' lockers, add a discovery source that builds a `TokenRecord` for each registry coin of a
non current stack from `locker.tokenRewards(coin)` (pool key, hook) and its launch block, show "Pair" from
`classifyPool` instead of the hardcoded "native ETH", and skip the `skimConfig` rows when the hook has none. the
weth calldata is already proven on the fork (4b).

## other findings

| item | note |
|---|---|
| `DeployV2Stack.s.sol` does not compile with the whole tree | `src/v2/keepers/CollectFlushKeeperLayer.sol` (untracked, another package) fails natspec check 5856 at line 112. the deploy ran with `--skip "src/v2/keepers/CollectFlushKeeperLayer.sol"` |
| forge script side effects | it writes `cache/DeployV2Stack.s.sol/1/run-latest.json` ("sensitive values") and overwrites `tmp/v2-deploy-1.json`. this run sent the broadcast log to a scratch dir with `FOUNDRY_BROADCAST`, removed the cache files and restored `tmp/v2-deploy-1.json` afterwards. `broadcast/` untouched |
| anvil accounts on a mainnet fork | all default accounts carry an eip-7702 delegation to a sweeper; any test that receives eth on them reads wrong balances. the harness never uses them as traders |
| 111 referral ledger on the fork | 0.060669 eth owed to the default referrer at block 26130269 (0x41c3…A6A4 is a contract). a real mainnet claim is a payout decision, the fork claim only proves the button |

## rerun

```bash
source /tmp/claude-0/env.sh   # or any foundry install
anvil --fork-url "$MAINNET_RPC_URL" --fork-block-number 26130269 --port 8545 --compute-units-per-second 100 &
# optional v2 stack (project "v2"), from the repo root
cast rpc anvil_setCode 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 0x --rpc-url http://127.0.0.1:8545
FOUNDRY_PROFILE=ci FOUNDRY_BROADCAST=/tmp/e2e-broadcast OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  forge script script/v2/DeployV2Stack.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked \
  --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --skip test
#   (add --skip "src/v2/keepers/CollectFlushKeeperLayer.sol" while that file does not compile)
cd ui && npm ci
node e2e/v2-env.mjs ../tmp/v2-deploy-1.json e2e/.local/v2-env.json
PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers E2E_V2_JSON=$PWD/e2e/.local/v2-env.json npm run test:e2e
```

files: `ui/e2e/playwright.config.ts`, `vite.e2e.config.ts`, `global-setup.ts`, `fork.ts`, `wallet.ts`,
`fixtures.ts`, `widget.ts`, `decode.ts`, `constants.ts`, `v2-env.mjs`, specs `01` to `07` (`05-deploy-v2.spec.ts`
runs in project `v2`). `ui/package.json` gains `test:e2e` and `@playwright/test` 1.56.1 (pinned to the installed
browsers, lockfile updated). `ui/.gitignore` ignores `e2e/artifacts/` and `e2e/.local/`.
