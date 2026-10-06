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
