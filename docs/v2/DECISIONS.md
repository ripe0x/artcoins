# artcoins v2 — decisions made unattended

each entry: what was decided, the alternatives, why. review and overrule as you like.

| # | decision | alternatives | why |
|---|---|---|---|
| D1 | tests in this session run against uniswap v4 deployed from the pinned `lib/v4-core` / `lib/v4-periphery` source on a local anvil/forge evm, not a mainnet fork. fork suites are kept and gated on `MAINNET_RPC_URL`. | wait for an rpc; mock v4 | the sandbox denies every rpc host. v4 from source is the real code, not a mock; fork runs are a one command re-run once an rpc is set. |
| D2 | registry fields that need chain reads (bytecode match, owner, deprecated flag, deploy block) are filled from broadcast records and the brief, and tagged `chainVerified: false` until `script-js/verify-registry.mjs` is run with an rpc. | leave the registry empty | a registry with provenance tags is more useful than none; the verifier is the source of truth. |
| D3 | work on branch `v2`, mirrored to the session branch `claude/gallant-dirac-3dezg7`. | only the session branch | the brief names `v2`; the harness names the session branch; pushing both costs nothing. |
| D4 | `docs/` was gitignored; `docs/v2/` is now un-ignored so the v2 docs ship with the pr. | keep docs out of git | the brief asks for docs in the repo. |
| D5 | `MAINNET_RPC_URL` defaults to tenderly's public gateway (https://mainnet.gateway.tenderly.co) in .env.example, foundry rpc_endpoints, ci, verify-registry and the fork test docs. | require a keyed provider | owner's instruction; keyless, rate limited but enough for verification and fork tests. |
