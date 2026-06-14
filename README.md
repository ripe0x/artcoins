# artcoins

A token launcher for Ethereum mainnet built on Uniswap V4. Deploy ERC20s with automatic V4 liquidity, a swap-fee hook, anti-sniper protection, on-chain metadata rendering, and an optional venue-scoped transfer tax.

Originally forked from [Clanker v4.1](https://github.com/clanker-devco/v4-contracts) and substantially rewritten. ETH mainnet only — no cross-chain code.

This is the launcher that [permanent-collection](https://github.com/ripe0x/permanent-collection) deploys its `111` art coin on; permanent-collection embeds this repo as a pinned git submodule.

## Highlights

- **Immutable tokens** — `ArtCoinsToken` is deployed directly via CREATE2 (no proxy, not upgradeable); construction-time configuration is fixed for the life of the token.
- **On-chain metadata** — ERC-7572 `contractURI()` plus a pluggable `IMetadataRenderer` for fully on-chain SVG art.
- **Configurable supply** — default 1,000,000,000, minimum 1 token.
- **Anti-sniper** — pluggable MEV modules that ramp the early fee (or skim) down over a launch window (linear, descending, stepped, or time-delay).
- **Swap-fee hook** — a skim-based V4 hook that takes a configurable share of swap volume and splits it at swap time across recipients (bounty / protocol / referral); a static per-direction fee hook is also available.
- **Configurable protocol fee** — default 20% of the protocol slice, hard-capped at 30% (`MAX_PROTOCOL_FEE_BPS = 3000`); the rest flows to LP-fee recipients.
- **Optional transfer tax** — a dormant, venue-scoped buy-side transfer tax (default off, 20% hard cap) that a single deployment can switch on at deploy time.

## Architecture

```
ArtCoinsFactory  — deploys + wires a token + V4 pool in one transaction
  ├─ ArtCoinsToken ............. immutable ERC20 (Solady) + Permit/Votes/Burnable,
  │                              optional venue-scoped transfer tax, pluggable renderer
  ├─ hooks/
  │   ├─ ArtCoinsHookSkimFee ... skims a % of swap volume → 3-leg split
  │   │                          (bounty / protocol / referral), flushed in-swap
  │   └─ ArtCoinsHookStaticFee . per-direction LP-fee variant
  ├─ lp-lockers/ArtCoinsLpLocker  collects V4 LP fees → up to 7 recipients
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
| Upgradeable | No — deployed via CREATE2, immutable for the token's life |
| Metadata | ERC-7572 `contractURI()` / `tokenURI()`, admin-settable `IMetadataRenderer` |
| Supply | Configurable at deploy (default 1B, min 1 token) |
| Transfer tax | Optional, venue-scoped, buy-side; default off, 20% hard cap |

The token launches with built-in metadata (JSON from stored strings). The admin can deploy a custom renderer and set it post-launch via `setMetadataRenderer(...)`. Reference renderers: `DefaultMetadataRenderer` (JSON) and `DynamicBlockRenderer` (on-chain SVG).

## Fees

- **Swap-fee hook** — `ArtCoinsHookSkimFee` skims a configurable share of swap volume and splits it at swap time (bounty / protocol / referral). A static per-direction fee hook (`ArtCoinsHookStaticFee`) is available for pools that prefer a fixed LP fee.
- **Protocol fee** — default 20% of the protocol slice, capped at 30%; set globally on the factory or overridden per deploy.
- **LP rewards** — the remaining LP fees distribute to up to 7 recipients via `ArtCoinsLpLocker`; recipients pull from `ArtCoinsFeeEscrow` (`claim(feeOwner, token)`; `token = address(0)` for native ETH).

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

## Build & test

```bash
git clone https://github.com/ripe0x/artcoins.git
cd artcoins
git submodule update --init --recursive   # forge-std, OpenZeppelin, Uniswap v4, solady
forge build
forge test
```

## Deploy

The factory ships `deprecated = true`; the owner flips it active before public deploys. The scripts in `script/` deploy and wire the full stack (token, V4 pool, hook, LP locker, MEV module) in one broadcast — e.g. `Deploy.s.sol`, `DeployNativeEthStack.s.sol`, `DeployProtocolFeeStack.s.sol`.

```bash
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

## UI

`ui/` is a React 19 + Vite app (wagmi + RainbowKit + Tailwind) for deploying and managing tokens:

```bash
cd ui && npm install && npm run dev
```

## License

MIT — see [LICENSE](LICENSE).
