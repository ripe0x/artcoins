# hygiene fixes: what changed and why

source: findings in `repo-hygiene.md` (ids H1 to H25). this file lists only what was changed. nothing was committed by the author of this change; no secret values appear below.

## changes

| finding | file | change | why |
|---|---|---|---|
| H5 | `test/**/*.t.sol` (24 files with an `onlyFork` modifier) | the vacuous `if (!_onFork) return;` modifier body is now `vm.skip(true)` | a test that returns early reports as passed. a skip shows in the summary, so a run without a fork can no longer read as green coverage |
| H5, H6 | `.github/workflows/test.yml` | `check` job has no network: `SKIP_FORK_TESTS=true`, `MAINNET_RPC_URL=http://127.0.0.1:9`, regex excludes the two suites that fork unconditionally (`AutoBurnOpenTab`, `DeployConversionLockerAndWire`) | ci results no longer depend on a public rpc being up or rate limiting |
| H5, H6 | `.github/workflows/test.yml` | new `fork-tests` job: `MAINNET_RPC_URL` from secrets, falling back to `https://mainnet.gateway.tenderly.co`; block read from `ForkBase.FORK_BLOCK` (26130269) and passed as `--fork-block-number`; `--fork-retries 8 --fork-retry-backoff 2000`; runs every fork gated suite and `test/v2` | fork proofs actually run, at a fixed block, and ride out 429s |
| H9, H23 | `.github/workflows/test.yml` | size gate step under the `ci` profile: fails when `ArtCoinsHookV2` has under 1,024 bytes of runtime headroom; prints a notice and passes when the artifact is not in the build | an edit that eats the EIP-170 margin fails in review, not at deploy. tolerant because the contract may be absent from a partial build |
| H10 | `.github/workflows/test.yml` | `FOUNDRY_VERSION: v1.7.1` for every job (toolchain action input) | one version for ci and local dev, so `forge fmt --check` is stable. the tree was formatted with 1.7.1 in this change |
| H11 | `.github/workflows/test.yml` | `permissions: {}` at top, `contents: read` per job, `persist-credentials: false`, `timeout-minutes`, concurrency group with cancel for non master refs | least privilege, bounded runtime, no duplicate runs |
| H15 | `.github/workflows/test.yml` | new `ui` job: `npm ci --ignore-scripts`, `npm run build`, `npm run lint`, plus informational `npm audit --omit=dev --audit-level=high`. `continue-on-error: true` with a comment pointing at `docs/v2/review/ui.md` UI-03 | the ui had no ci. it does not build clean today, so the job stays non blocking until it does. remove `continue-on-error` then |
| H1 | `.github/workflows/mirror.yml` | no `--tags`: an explicit refspec list of only the tags whose commit is an ancestor of `origin/master`; others get a warning and are not pushed | a tag on a wip or review commit would upload that commit and its whole ancestry to the public repo |
| H24 | `.github/workflows/mirror.yml` | push stays fast forward only (no `+`, no `--force`); comment says so | a diverged or moved ref fails the job loudly instead of rewriting public history |
| H2 | `.github/workflows/mirror.yml` | header note: merging v2 to master publishes `docs/v2/**` and `test/v2/**` (incl. `test/v2/review` PoC tests) and all commit messages; the workflow does not filter paths | the owner must decide what v2 carries before the merge. a note does not enforce anything |
| H7 | `foundry.lock` | rewritten to the checked out gitlink shas (all 8 libs). `tag` entries kept only where the sha is exactly that tag: solady `v0.1.26`, universal-router `2.0.0`. forge-std, openzeppelin, v4-core, v4-periphery, permit2 and the upgradeable lib are plain `rev` | the gitlinks are what ci, fresh clones and permanent-collection resolve. the old lock named a v4-periphery rev that no longer has `BaseHook.sol` and `HookMiner.sol` |
| H14 | `.gitignore`, `script-js/package-lock.json` | lockfile un-ignored and added | reproducible installs for `script-js` |
| H8 | `.env.example` | comment on `PRIVATE_KEY`: the all zero value is a placeholder, never replace it in a committed file, use an untracked `.env` or `--account` keystore. stale contract names fixed; points at `deployments/mainnet.json` and `sync-addresses.mjs` for addresses | the value trips secret scanners and invites pasting a real key. it is not a real key, so no history rewrite |
| H5, H9 | `foundry.toml` | new `[profile.fork]`: `eth_rpc_url = "${MAINNET_RPC_URL}"`, `fork_block_number = 26130269` (keep equal to `ForkBase.FORK_BLOCK`), storage caching on | one command for a local pinned fork run. forge 1.7.1 has no config key for retries, so retries stay as cli flags |
| fmt | `src/`, `test/`, `script/` | `forge fmt` at 1.7.1 over the tree. `script-js/gen-addresses.mjs` now writes block numbers with `_` separators so the generated `script/Addresses.sol` stays fmt clean | `forge fmt --check` is part of ci and was failing |

## not changed (open)

| item | why |
|---|---|
| `test/FeeAutoSwapper.invariants.t.sol` (7 `if (!onFork) return;` in `invariant_*` view functions) | not the `onlyFork` modifier pattern, and `vm.skip` is not allowed in a `view` function. these still pass vacuously without a fork. fix: make them non view and skip, or move the check into `setUp` |
| H3 `origin` is the public url | owner confirmation needed. nothing in the repo can fix it |
| H2 enforcement | only a note was added. a curated merge (squash, strip `docs/v2/review` and `test/v2/review`) is a process decision |
| H4 deployments record | covered by `deployments/mainnet.json` and the registry tooling, not by this change |
| H16 unused `openzeppelin-contracts-upgradeable` submodule | removing a submodule is out of scope here. it is kept in `foundry.lock` to match the gitlink |
| H12, H13, H17 to H22 | not in this change |
| ci actions pinned by full commit sha (H11) | still major tags (`actions/checkout@v5`, `foundry-rs/foundry-toolchain@v1`, `actions/setup-node@v4`). shas cannot be looked up from this environment. toolchain binary is pinned (`v1.7.1`) |
| `ssh-keyscan` host key in mirror (H24) | still trust on first use |

## how to run

| goal | command |
|---|---|
| no network suite, as ci | `SKIP_FORK_TESTS=true MAINNET_RPC_URL=http://127.0.0.1:9 forge test --no-match-contract "AutoBurnOpenTab\|DeployConversionLockerAndWire"` |
| fork suite, as ci | `forge test --no-match-contract "AutoBurnOpenTab\|DeployConversionLockerAndWire" --fork-url $MAINNET_RPC_URL --fork-block-number 26130269 --fork-retries 8 --fork-retry-backoff 2000` |
| size headroom | `FOUNDRY_PROFILE=ci forge build --sizes` |
| fmt | `forge fmt --check` (forge 1.7.1) |
