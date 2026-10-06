# artcoins

A token launcher for Ethereum mainnet built on Uniswap V4. Deploy ERC20s with automatic V4 liquidity, a swap-fee hook, anti-sniper protection, on-chain metadata rendering, and an optional venue-scoped transfer tax.

Originally forked from [Clanker v4.1](https://github.com/clanker-devco/v4-contracts) and substantially rewritten. Built for Ethereum mainnet, no cross-chain code (the contracts do not enforce the chain id).

This is the launcher that [permanent-collection](https://github.com/ripe0x/permanent-collection) deploys its `111` art coin on; permanent-collection embeds this repo as a pinned git submodule.

## Highlights

- **Not upgradeable tokens** — `ArtCoinsToken` is deployed directly via CREATE2 (no proxy). Supply, name, symbol and the tax cap are fixed at construction; the token admin can still change the image, metadata, renderer and admin, and move the tax rate within its cap.
- **On-chain metadata** — ERC-7572 `contractURI()` plus a pluggable `IMetadataRenderer` for fully on-chain SVG art.
- **Configurable supply** — default 1,000,000,000, minimum 1 token.
- **Anti-sniper** — pluggable MEV modules that ramp the early fee (or skim) down over a launch window (linear, descending, stepped, or time-delay).
- **Swap-fee hook** — a skim-based V4 hook that takes a configurable share of swap volume and splits it at swap time across recipients (bounty / protocol / referral); a static per-direction fee hook is also available.
- **Configurable protocol fee** — the protocol takes 20% of LP rewards by default (`defaultProtocolFeeBps = 2000`), hard-capped at 30% (`MAX_PROTOCOL_FEE_BPS = 3000`); the rest flows to LP-fee recipients. This is separate from the skim hook's protocol leg.
- **Optional transfer tax** — a dormant, venue-scoped buy-side transfer tax (default off, 20% hard cap) that a deployer can switch on at deploy time (`deployTokenWithProtocolBpsAndTax`); nothing on chain limits it to one deployment.

## Architecture

```
ArtCoinsFactory  — deploys + wires a token + V4 pool in one transaction
  ├─ ArtCoinsToken ............. immutable ERC20 (Solady) + Permit/Votes/Burnable,
  │                              optional venue-scoped transfer tax, pluggable renderer
  ├─ hooks/
  │   ├─ ArtCoinsHookSkimFee ... skims a % of swap volume → 3-leg split
  │   │                          (bounty / protocol / referral), flushed in-swap
  │   └─ ArtCoinsHookStaticFee . per-direction LP-fee variant
  ├─ lp-lockers/ArtCoinsLpLocker  collects V4 LP fees → up to 7 reward slots
  │                              (the factory fills one with the protocol slot)
  ├─ ArtCoinsFeeEscrow ......... pull-based per-(owner, token) balances (native ETH + ERC20)
  ├─ protocol-fee/ProtocolFeeController  fixed treasury / burn split
  ├─ mev-modules/ ............. anti-sniper: LinearFees, LinearSkim, DescendingFees,
  │                              TimeDelay, SniperSteppedFees
  ├─ extensions/ ............. Vault (vesting), Airdrop (merkle), Univ4EthDevBuy,
  │                              BurnExtension, AutoBurnPool, LiquidityLayer* …
  └─ renderer/ ............... DefaultMetadataRenderer, DynamicBlockRenderer
```

## Token features

| Feature | Details |
|---|---|
| Standard | ERC20 (Solady) + Permit + Votes + Burnable |
| Upgradeable | No — deployed via CREATE2, no proxy. The admin can still update image, metadata, renderer and admin |
| Metadata | ERC-7572 `contractURI()` / `tokenURI()`, admin-settable `IMetadataRenderer` |
| Supply | Configurable at deploy (default 1B, min 1 token) |
| Transfer tax | Optional, venue-scoped, buy-side; default off, 20% hard cap |

The token launches with built-in metadata (JSON from stored strings). The admin can deploy a custom renderer and set it post-launch via `setMetadataRenderer(...)`. Reference renderers: `DefaultMetadataRenderer` (JSON) and `DynamicBlockRenderer` (on-chain SVG).

## Fees

- **Swap-fee hook** — `ArtCoinsHookSkimFee` skims a configurable share of swap volume and splits it at swap time (bounty / protocol / referral). A static per-direction fee hook (`ArtCoinsHookStaticFee`) is available for pools that prefer a fixed LP fee.
- **Protocol fee** — default 20% of LP rewards, capped at 30%; set globally on the factory or overridden per deploy. The factory appends it as a reward slot.
- **LP rewards** — the remaining LP fees distribute to up to 6 project recipients (7 slots minus the protocol slot) via `ArtCoinsLpLocker`; recipients pull from `ArtCoinsFeeEscrow` (`claim(feeOwner, token)`; `token = address(0)` for native ETH).

## Anti-sniper (MEV modules)

Pick one per token; each ramps the early fee or skim down over a launch window:

| Module | Mechanism |
|---|---|
| `ArtCoinsMevLinearFees` | Linear LP-fee decay (default 69% → 1% over 69 minutes) |
| `ArtCoinsMevLinearSkim` | Linear skim decay at the hook level (share of volume) |
| `ArtCoinsMevDescendingFees` | Parabolic fee decay |
| `ArtCoinsMevSniperSteppedFees` | Stepped fee schedule |
| `ArtCoinsMevTimeDelay` | Blocks trading for N seconds |

The fee-decay approach is inspired by PunkStrategy's launch mechanics.

## Deployments

`deployments/mainnet.json` is the source of truth for every mainnet address, and `node script-js/verify-registry.mjs` checks it against the chain. The table is generated from it (`cd script-js && npm run gen:addresses`), do not edit it by hand. Forge scripts read `script/Addresses.sol` and the ui reads `ui/src/lib/deployments.generated.ts`, both generated from the same file.

<!-- deployments:start -->
| stack | status | factory | hook | locker | escrow | module | coins |
|---|---|---|---|---|---|---|---|
| legacy (2026-05-07) | legacy, owner only | [0xD159…92f9](https://etherscan.io/address/0xD1595A2742C392d1c109b616b4F08918D02292f9) | [0xA5eA…28cc](https://etherscan.io/address/0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc) | [0x75BE…1118](https://etherscan.io/address/0x75BE7E95745915fD0C1761B74F3f9650ad2d1118) | [0x1143…6b05](https://etherscan.io/address/0x1143db0913Ca5eCe8A42FC01b625fD81F9386b05) | 4 modules, see registry | `LAYER` |
| open (2026-05-19) | superseded, public | [0xF051…793e](https://etherscan.io/address/0xF051cd4C4F3F36F9f24d8a19d60Ee8F84FC6793e) | [0xAAd6…A8Cc](https://etherscan.io/address/0xAAd673ea3945dF5F7Ef328974d2c07c8BdcAA8Cc) | [0xd914…97b2](https://etherscan.io/address/0xd914c864D9AEf3D8E51370139300aC534FB497b2) | [0xDD1b…1C06](https://etherscan.io/address/0xDD1b8C9C99Be3C717B9A5eb3C84297C5bfca1C06) | none | none |
| current (2026-06-06) | current, owner only | [0x4959…4e0e](https://etherscan.io/address/0x49596c375c139E79bb937bcf826068a8F78D4e0e) | [0x636c…a9cc](https://etherscan.io/address/0x636c050296B5Cc528D8785169Bf8923716FCa9cc) | [0x866e…6aab](https://etherscan.io/address/0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab) | [0x7559…25F2](https://etherscan.io/address/0x7559689765aE86cBB38e68CD1294830CccB125F2) | [0xb038…8B83](https://etherscan.io/address/0xb038D597365FfD108D63C265Bb0621444a1D8B83) | `111` |
<!-- deployments:end -->

`current` is the only stack to build against. `open` is superseded (callable by anyone, no coin was ever launched on it) and `legacy` holds LAYER. The `escrow` of the legacy stack is its fee locker.

## v2 (branch `v2`, not deployed)

The `v2` branch carries the next stack: immutable coins, an owner changeable factory side, no recipient code during swaps, two fee dodge modes (venue tax or hard transfer restriction), locker only liquidity on taxed pools, a version tag per pool, and a verified deployment registry. Nothing from v2 is deployed yet.

| read | what |
|---|---|
| [docs/v2/STATUS.md](docs/v2/STATUS.md) | what is done, what is open |
| [docs/v2/SYSTEM-REVIEW.md](docs/v2/SYSTEM-REVIEW.md) | the full system review, findings by area, proofs, what was not verified (not a formal audit) |
| [docs/v2/DESIGN.md](docs/v2/DESIGN.md) and [docs/v2/DECISIONS.md](docs/v2/DECISIONS.md) | the design and every decision made with its alternatives |
| [docs/v2/RUNBOOK.md](docs/v2/RUNBOOK.md) | owner actions on the live stacks today, then the v2 rollout order and the public gate list |
| [docs/v2/CREDITS-ENGINE-INTERFACE.md](docs/v2/CREDITS-ENGINE-INTERFACE.md) | what a fee recipient contract must satisfy on v2 |
| [script/v2/README.md](script/v2/README.md) | deploy, launch and verify commands |

## Build & test

```bash
git clone https://github.com/ripe0x/artcoins.git
cd artcoins
git submodule update --init --recursive   # forge-std, OpenZeppelin, Uniswap v4, solady
forge build
forge test
```

## Deploy

The factory ships `deprecated = true`: only the owner can deploy until the owner flips it.

| path | script | state |
|---|---|---|
| v2 | `script/v2/DeployV2Stack.s.sol` | being written, not in the tree yet. It will land under `script/v2/` and is the path to use once it does |
| v1 (superseded) | `script/DeployV1Stack.s.sol`, run with `FOUNDRY_PROFILE=tune` | deploys and wires the skim stack (factory, hook, locker, escrow, mev modules). Superseded by v2 |
| older stacks | `Deploy.s.sol`, `DeployNativeEthStack.s.sol`, `DeployProtocolFeeStack.s.sol` | deploy the legacy and open stacks, history only. Do not use them for a new deployment |

Use `tune` (or `ci`, same optimizer settings) for any hook deploy: the skim hook only fits EIP-170 at 200 optimizer runs, not at the default 20000. Run `forge script` without `--broadcast` first, it simulates.

```bash
FOUNDRY_PROFILE=tune forge script script/DeployV1Stack.s.sol --rpc-url $MAINNET_RPC_URL
```

After a deployment, add it to `deployments/mainnet.json`, run `node script-js/verify-registry.mjs --fill`, then `npm run gen:addresses`.

## UI

`ui/` is a React 19 + Vite app (wagmi + RainbowKit + Tailwind) for deploying and managing tokens. Its mainnet addresses come from the registry through `ui/src/lib/deployments.generated.ts`.

```bash
cd ui && npm install && npm run dev
```

## License

MIT — see [LICENSE](LICENSE).
