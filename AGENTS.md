# new-material-coin-launcher — context for AI coding agents

## What this is

The "artcoins" token launcher: a factory + V4 hook + LP locker for
deploying ERC20s on Ethereum mainnet with automatic Uniswap V4 pools,
anti-sniper fees, and on-chain renderer integration. Forked from
Clanker v4.1; see [README.md](README.md) for the architecture diagram.

## Downstream consumer: permanent-collection

[ripe0x/permanent-collection](https://github.com/ripe0x/permanent-collection)
embeds this repo as a **git submodule** at `contracts/lib/artcoins`,
pinned to a specific commit. Changes you make here only affect
permanent-collection when:

1. The change is **committed and pushed to GitHub** here (CI in
   permanent-collection clones the submodule via GitHub), AND
2. Someone in permanent-collection **bumps the submodule pin** to the
   new commit.

You can ignore this 99% of the time — you only need to think about it
when (a) you're working on artcoins specifically to support a
permanent-collection feature, OR (b) someone in permanent-collection
asks you to "bump artcoins."

## When permanent-collection needs your changes (the bump recipe)

Assuming the local sibling layout (both repos checked out as siblings
at `/Users/dd/CascadeProjects/`):

```bash
# 1. In artcoins (this repo): make your changes, commit, push
git add -A && git commit -m "..."
git push origin master   # CI in permanent-collection can now resolve the pin

# 2. In permanent-collection: bump the pin
cd /Users/dd/CascadeProjects/permanent-collection/contracts/lib/artcoins
git fetch sibling && git checkout sibling/master
# (`sibling` is a pre-configured remote pointing at this repo on local
#  disk — avoids a GitHub roundtrip; the `origin` remote is GitHub.)

cd ../../.. && git add contracts/lib/artcoins
git commit -m "bump artcoins to <short-hash>"
```

If you skip step 1's push, CI for permanent-collection will fail with
"object not found" — the pinned commit only exists on the local disk,
not on GitHub.

## Repo notes

- **Fresh clones need the submodules.** This repo's `lib/` dependencies
  (forge-std, OpenZeppelin, Uniswap v4-core/v4-periphery/permit2/universal-router,
  solady) are git submodules — run `git submodule update --init --recursive`
  after cloning, before building.
- **Public mirror**: `master` is published to the public `ripe0x/artcoins`
  repo, which permanent-collection's submodule resolves from (anonymously
  clonable; the `SUBMODULE_TOKEN` secret in permanent-collection is only a
  fallback). This working repo stays private — write commit messages for a
  public audience.
- **`broadcast/` directory**: deploy-script artifacts that change every
  time a deploy is run. Don't commit them unless you mean to.
- **Mainnet live**: factory deployed 2026-05-18; see README for the
  current addresses.
