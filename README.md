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

## Deployed addresses

Addresses for the stack that `ui/` targets (`script/Deploy.s.sol` — factory
`deployToken(...)`, legacy MEV modules, vault/airdrop/dev-buy extensions).
Source of truth: `ui/src/lib/config.ts`, derived from the Foundry broadcast
artifacts in `broadcast/Deploy.s.sol/1/`.

### Mainnet

| Contract | Address |
| --- | --- |
| Factory | [`0xD1595A2742C392d1c109b616b4F08918D02292f9`](https://etherscan.io/address/0xD1595A2742C392d1c109b616b4F08918D02292f9) |
| Hook | [`0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc`](https://etherscan.io/address/0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc) |
| LP Locker | [`0x75BE7E95745915fD0C1761B74F3f9650ad2d1118`](https://etherscan.io/address/0x75BE7E95745915fD0C1761B74F3f9650ad2d1118) |
| MEV Linear Fees | [`0xAe19E402420359062eE422a03589e04a52cD8C6F`](https://etherscan.io/address/0xAe19E402420359062eE422a03589e04a52cD8C6F) |
| MEV Descending Fees | [`0x7958DE7d8C857CdD37465FB920A961B1f8F74301`](https://etherscan.io/address/0x7958DE7d8C857CdD37465FB920A961B1f8F74301) |
| MEV Time Delay | [`0xf080D741D069B107D728B68F781843d83A0EA8Fb`](https://etherscan.io/address/0xf080D741D069B107D728B68F781843d83A0EA8Fb) |
| Vault | [`0x84732a79e4Ec8F03063a138c7ef866a9d222C661`](https://etherscan.io/address/0x84732a79e4Ec8F03063a138c7ef866a9d222C661) |
| Airdrop | [`0xF937dFf16a45E417951794758E77CbEd0A7F27eC`](https://etherscan.io/address/0xF937dFf16a45E417951794758E77CbEd0A7F27eC) |
| Dev Buy | [`0xfCB6a929dB98A1D69b5F33A2f7E073cB7449cF30`](https://etherscan.io/address/0xfCB6a929dB98A1D69b5F33A2f7E073cB7449cF30) |
| WETH | [`0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`](https://etherscan.io/address/0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2) |
| PoolManager (Uniswap V4) | [`0x000000000004444c5dc75cB358380D2e3dE08A90`](https://etherscan.io/address/0x000000000004444c5dc75cB358380D2e3dE08A90) |
| StateView (Uniswap V4) | not filled in yet — see `ui/src/lib/config.ts` |
| Quoter (Uniswap V4) | not filled in yet — see `ui/src/lib/config.ts` |
| Universal Router | [`0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af`](https://etherscan.io/address/0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af) |
| Permit2 | [`0x000000000022D473030F116dDEE9F6B43aC78BA3`](https://etherscan.io/address/0x000000000022D473030F116dDEE9F6B43aC78BA3) |

There is also a separate, newer "V3" native-ETH-pair stack
(`script/DeployNativeEthStack.s.sol`, deployed 2026-05-18) with its own
`deployTokenWithProtocolBps(...)` entrypoint and no MEV modules or
vault/airdrop/dev-buy extensions. `ui/` does not target it, so it is not
listed above.

### Sepolia

| Contract | Address |
| --- | --- |
| Factory | [`0x3c3aEfC8Fa374589D179D43cb03e29a6B350DF7A`](https://sepolia.etherscan.io/address/0x3c3aEfC8Fa374589D179D43cb03e29a6B350DF7A) |
| Hook | [`0x36EF2eC4c1DF5e0A07567306D721F2Bb5d4E68cc`](https://sepolia.etherscan.io/address/0x36EF2eC4c1DF5e0A07567306D721F2Bb5d4E68cc) |
| LP Locker | [`0x6e511f2321F82559E559ce1Da0EcFDBf0E4ace62`](https://sepolia.etherscan.io/address/0x6e511f2321F82559E559ce1Da0EcFDBf0E4ace62) |
| MEV Linear Fees | [`0x7f0AC1a505614CF21a78ed276710864C8b256b4e`](https://sepolia.etherscan.io/address/0x7f0AC1a505614CF21a78ed276710864C8b256b4e) |
| MEV Descending Fees | [`0xb42d19d3C4fCa696e59Ed2C6eEdD4a56752EDe12`](https://sepolia.etherscan.io/address/0xb42d19d3C4fCa696e59Ed2C6eEdD4a56752EDe12) |
| MEV Time Delay | [`0x562E8BEb37064b2A5A3f9D0Ab3AB9263ab1295ac`](https://sepolia.etherscan.io/address/0x562E8BEb37064b2A5A3f9D0Ab3AB9263ab1295ac) |
| Vault | [`0xaF57B58c208D0D846646350fAdBba3537861F19B`](https://sepolia.etherscan.io/address/0xaF57B58c208D0D846646350fAdBba3537861F19B) |
| Airdrop | [`0x9ad33BB054577d2b3a6B549Bf08D32814e0fBbF9`](https://sepolia.etherscan.io/address/0x9ad33BB054577d2b3a6B549Bf08D32814e0fBbF9) |
| Dev Buy | [`0x7Be49a9cB09E2FE7Dd5484ec94Fc8F70d226649B`](https://sepolia.etherscan.io/address/0x7Be49a9cB09E2FE7Dd5484ec94Fc8F70d226649B) |
| WETH | [`0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`](https://sepolia.etherscan.io/address/0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14) |
| PoolManager (Uniswap V4) | [`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) |
| StateView (Uniswap V4) | [`0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C`](https://sepolia.etherscan.io/address/0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C) |
| Quoter (Uniswap V4) | [`0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227`](https://sepolia.etherscan.io/address/0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227) |
| Universal Router | [`0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b`](https://sepolia.etherscan.io/address/0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b) |
| Permit2 | [`0x000000000022D473030F116dDEE9F6B43aC78BA3`](https://sepolia.etherscan.io/address/0x000000000022D473030F116dDEE9F6B43aC78BA3) |

## UI

`ui/` is a React 19 + Vite app (wagmi + RainbowKit + Tailwind) for deploying and managing tokens:

```bash
cd ui && npm install && npm run dev
```

Pages: deploy a new token, browse the token list, a token-detail page with
swap, the airdrop claim page, and referrals management. See
[ui/README.md](ui/README.md) for setup (including required/recommended env
vars) and runtime config.

Operator scripts for deploy math, address syncing, and airdrop-allowlist
generation live in [`script-js/`](script-js/README.md).

## License

MIT — see [LICENSE](LICENSE).
