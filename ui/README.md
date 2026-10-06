# artcoins launcher ui

Static single page app (vite, react, wagmi, rainbowkit). Mainnet only. It reads the deployment registry,
lists tokens, trades them against their native eth pools, and launches new coins through the v2 factory.

## commands

| command | what |
|---|---|
| `npm ci` | install (lockfile pinned) |
| `npm run build` | `tsc -b` then `vite build` |
| `npm run lint` | eslint |
| `npm test` | unit tests (`node --test` through tsx): encoder units and struct layout, swap commands, curve math, url and referrer validation |
| `npm run smoke` | server renders every page with no wallet, catches render time errors |
| `npm run gen:abi` / `npm run check:abi` | regenerate or verify `src/lib/abi/{v1,v2}/*.ts` from the forge artifacts (`forge build` at the repo root first) |
| `npx tsx scripts/fork-swap-sim.ts` | buy then sell coin 111 through the universal router on a mainnet fork (see the file header) |
| `npx tsx scripts/check-discovery.ts` | live token discovery against the mainnet rpc |

## where things come from

| item | source |
|---|---|
| current stack addresses, deploy blocks | `src/lib/deployments.generated.ts`, generated from `deployments/mainnet.json` (`cd script-js && npm run gen:addresses`). Never edit it |
| v2 stack | a `V2` export of that file once the generator emits one, else `VITE_V2_*` env (see `.env.example`). With neither, the deploy page is closed and only the current stack is listed |
| contract abis | `src/lib/abi/v1` (current stack contracts) and `src/lib/abi/v2` (the frozen v2 interfaces), generated. `src/lib/abi.ts` keeps only hand written abis for contracts this repo does not compile (uniswap, permit2, erc20, ReferralPayout, v1 airdrop) |
| fee numbers on the deploy page | read from the factory (`deprecated`, `deployFee`, `defaultProtocolFeeBps`, `minProtocolSkimShareBps`), never hardcoded |
| constants | `src/lib/constants.ts` mirrors `src/Constants.sol`, pinned by tests |

## secrets and privacy

Everything prefixed `VITE_` is compiled into the public bundle.

| variable | policy |
|---|---|
| `VITE_WALLETCONNECT_PROJECT_ID` | public by design, restrict the allowed domains in the WalletConnect dashboard |
| `VITE_MAINNET_RPC_URL` | optional read rpc with no key in the url, preferred |
| `VITE_ALCHEMY_API_KEY` | ignored unless `VITE_ALCHEMY_KEY_RESTRICTED=1`, which asserts the key is restricted to this site's domains. An unrestricted key in a public bundle can be used by anyone |
| default | the tenderly public gateway the rest of the repo uses (rate limited) |

Reads go to the configured rpc, so it sees the visitor's ip and addresses. Run your own proxy if that matters.

## trust model of what the ui shows

| signal | meaning |
|---|---|
| "artcoins factory v1 / v2" badge | the token was announced by a factory in the registry. Says nothing about the creator or the token |
| "creator flag" | the token's own `isVerified()`, set by its admin. Not a trust signal |
| "similar name" | another listed token has the same normalised name or symbol |
| images | only `https:`, `ipfs:`, `ar:` and `data:image/` urls are loaded, with no referrer. Names and text are stripped of control and bidi characters and clamped |

## e2e (browser, mainnet fork)

Playwright drives the real ui (vite dev server) in chromium against a local anvil fork. The wallet is an EIP-1193
provider injected before load (`e2e/wallet.ts`): rainbowkit lists it as "E2E Wallet" (EIP-6963), every request
crosses to node where a local key signs (viem) or, for live addresses, anvil impersonation sends. Each run
snapshots the fork and reverts it at the end (`E2E_KEEP_STATE=1` keeps the state). Results:
`docs/v2/review/ui-e2e.md`.

| step | command |
|---|---|
| fork | `anvil --fork-url "$MAINNET_RPC_URL" --fork-block-number 26130269 --port 8545 --compute-units-per-second 100` |
| v2 stack (optional, project `v2`) | from the repo root: `cast rpc anvil_setCode 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 0x --rpc-url http://127.0.0.1:8545` (drops the mainnet 7702 delegation on anvil account 0), then `FOUNDRY_PROFILE=ci FOUNDRY_BROADCAST=/tmp/e2e-broadcast OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 forge script script/v2/DeployV2Stack.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`, then in `ui/`: `node e2e/v2-env.mjs ../tmp/v2-deploy-1.json e2e/.local/v2-env.json` |
| run | `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers E2E_V2_JSON=$PWD/e2e/.local/v2-env.json npm run test:e2e` (leave `E2E_V2_JSON` unset to run the fork project only) |
| one file | `npm run test:e2e -- 03` |

| env | default | meaning |
|---|---|---|
| `E2E_FORK_RPC` | `http://127.0.0.1:8545` | the fork, also the ui's `VITE_MAINNET_RPC_URL` |
| `E2E_V2_JSON` | unset | `VITE_V2_*` for the second dev server (port 5182), written by `e2e/v2-env.mjs` |
| `E2E_CHROMIUM` | unset | chromium binary, when the installed playwright browsers do not match `@playwright/test` |
| `E2E_KEEP_STATE` | unset | `1` skips the end of run `evm_revert` |

Dev servers run on 5181 (no v2) and 5182 (v2) through `e2e/vite.e2e.config.ts` (own dep cache per port, no
reload on artifact writes). No `ui/.env` is written: the `VITE_*` values come from the process env. Failures
leave a screenshot, a trace and the console and wallet logs in `e2e/artifacts/` (gitignored). Tests marked
`test.fail` are known ui bugs: they report "expected to fail" until the bug is fixed, then fail the run.
