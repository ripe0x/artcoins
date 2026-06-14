# NewMaterial Token Launcher

A token launcher for Ethereum mainnet built on Uniswap V4. Deploy ERC20 tokens with automatic liquidity pools, configurable trading fees, anti-sniper protection, and on-chain metadata rendering.

Forked from [Clanker v4.1](https://github.com/clanker-devco/v4-contracts) with significant additions:

- **Upgradeable tokens** — UUPS proxy pattern, token admin controls upgrades
- **On-chain metadata** — `contractURI()` + `tokenURI()` with pluggable renderer contracts for on-chain SVG art
- **Configurable supply** — deployers choose their own total supply (default 1B)
- **Anti-sniper protection** — linear fee decay (99% to 1% over 69 minutes) inspired by PunkStrategy
- **Configurable protocol fee** — factory owner can adjust the protocol fee (default 20%, max 50%)
- **ETH mainnet only** — no superchain/cross-chain code

## Architecture

```
NewMaterialFactory (deploys tokens)
  |-- NewMaterialToken (UUPS upgradeable ERC20 proxy)
  |     \-- IMetadataRenderer (optional on-chain art)
  |-- NewMaterialHookStaticFeeV2 (Uniswap V4 hook)
  |-- NewMaterialLpLockerMultiple (LP fee distribution)
  |-- MEV Modules
  |     |-- NewMaterialMevLinearFees (anti-sniper, recommended)
  |     |-- NewMaterialMevDescendingFees (parabolic decay)
  |     \-- NewMaterialMevTimeDelay (block trading)
  \-- Extensions
        |-- NewMaterialVault (token lockup/vesting)
        |-- NewMaterialAirdropV2 (merkle airdrop)
        \-- NewMaterialUniv4EthDevBuy (initial token purchase)
```

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 18+ (for UI)

### Build and Test

```bash
git clone <repo-url>
cd new-material-coin-launcher

# Build contracts
forge build

# Run tests
forge test -vv

# Run fork tests (requires RPC)
forge test --match-contract IntegrationForkTest --fork-url $SEPOLIA_RPC_URL -vvv
```

### Deploy

```bash
cp .env.example .env
# Fill in your RPC URL, private key, and etherscan key

source .env

# Deploy to Sepolia (full stack)
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv

# Deploy to mainnet
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify -vvv
```

The deploy script deploys the entire stack (12+ contracts), mines the V4 hook address, wires everything together, and activates the factory.

### Launch UI

```bash
cd ui
npm install
npm run dev
```

Update contract addresses in `ui/src/lib/config.ts` after deployment.

## Token Features

Every token deployed through the factory is an ERC20 with:

| Feature | Details |
|---------|---------|
| Standard | ERC20 + ERC20Permit + ERC20Votes + ERC20Burnable |
| Upgradeable | UUPS proxy, admin can upgrade implementation |
| Metadata | `contractURI()` and `tokenURI()` per ERC-7572 |
| Renderer | Admin can set a custom IMetadataRenderer for on-chain art |
| Supply | Configurable at deployment (default 1B, min 1 token) |

### Metadata Renderers

Tokens launch with built-in metadata (JSON from stored strings). The token admin can deploy a custom renderer contract and set it post-launch:

```solidity
MyCustomRenderer renderer = new MyCustomRenderer();
NewMaterialToken(myToken).setMetadataRenderer(address(renderer));
```

Two reference implementations are included:

- **DefaultMetadataRenderer** — Returns JSON with name, symbol, description, image URL
- **ExampleOnChainRenderer** — Generates on-chain SVG art with unique colors derived from the token address. No external hosting needed.

### Implementing a Custom Renderer

```solidity
import {IMetadataRenderer} from "./interfaces/IMetadataRenderer.sol";

contract MyRenderer is IMetadataRenderer {
    function contractURI(address token) external view returns (string memory) {
        // Read token properties, generate SVG/JSON, return data URI
    }
}
```

## Anti-Sniper Protection

Three MEV modules available. Deployers choose one per token:

| Module | Mechanism | Default |
|--------|-----------|---------|
| Linear Fees (recommended) | 99% fee decays linearly to 1% | 69 min duration |
| Descending Fees | Parabolic fee decay | 80% to 5%, 30s |
| Time Delay | Blocks all trading for N seconds | 120s |

## Fee Structure

- **Trading fees**: Configurable per token (0-10% buy, 0-10% sell)
- **Protocol fee**: 20% of LP fees to factory owner (configurable 0-50%)
- **LP rewards**: Remaining fees distributed to up to 7 recipients

## Asset Hosting

Token images and metadata can be handled two ways:

1. **External hosting** — Store images on IPFS, Arweave, or your own server. Set the URL in `TokenConfig.image`. The token's built-in `contractURI()` references this URL.

2. **Fully on-chain** — Deploy a metadata renderer contract that generates SVG art directly in Solidity. No hosting needed. See `ExampleOnChainRenderer.sol` for a working example.

## Project Structure

```
src/
  NewMaterialToken.sol            Upgradeable ERC20 token
  NewMaterialFactory.sol          Token launcher factory
  NewMaterialFeeLocker.sol        Fee collection
  interfaces/                     All interfaces
  hooks/                          Uniswap V4 hooks
  lp-lockers/                     LP fee distribution
  mev-modules/                    Anti-sniper modules
  extensions/                     Vault, airdrop, dev buy
  renderer/
    DefaultMetadataRenderer.sol   Basic JSON renderer
    ExampleOnChainRenderer.sol    On-chain SVG art example
  utils/                          Deployer, access control
test/                             Forge tests
script/
  Deploy.s.sol                    Full stack deployment
ui/                               React deployment UI
  src/
    components/                   Form components
    lib/                          ABI, encoding, config
```

## License

MIT
