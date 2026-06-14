#!/usr/bin/env bash
# One-shot Etherscan verification for any deployed stack.
#
# Reads the latest broadcast files for the chain you specify, submits every
# CREATE/CREATE2 contract to Etherscan, and is idempotent — Etherscan returns
# "Already Verified" on retry. Constructor args are recovered automatically
# via `forge verify-contract --guess-constructor-args`.
#
# Use this after a `forge script ... --broadcast` run that didn't include
# `--verify`, or to retry a transient verification failure (e.g. the
# binaries.soliditylang.org timeouts that hit during the Sepolia rehearsal).
#
# Usage:
#   ETHERSCAN_API_KEY=... ./script/verify-stack.sh [--chain <id>]
#     --chain 1            mainnet (default)
#     --chain 11155111     sepolia

set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

: "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY must be set (in .env or environment)}"

CHAIN_ID=1
while [ $# -gt 0 ]; do
  case "$1" in
    --chain) CHAIN_ID="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$CHAIN_ID" in
  1)         CHAIN_FLAG="--chain mainnet"; RPC_URL="${MAINNET_RPC_URL:-}" ;;
  11155111)  CHAIN_FLAG="--chain sepolia"; RPC_URL="${SEPOLIA_RPC_URL:-}" ;;
  *) echo "unsupported chain id: $CHAIN_ID" >&2; exit 2 ;;
esac

: "${RPC_URL:?Set MAINNET_RPC_URL or SEPOLIA_RPC_URL in .env (needed for --guess-constructor-args)}"

echo "=== verify-stack chain=$CHAIN_ID ==="
echo

# Map contract name → src path. Mirrors src/ layout. Add new contracts here.
declare -A SRC_PATH=(
  [ArtCoinsFeeLocker]="src/ArtCoinsFeeLocker.sol"
  [ArtCoinsFactory]="src/ArtCoinsFactory.sol"
  [ArtCoinsToken]="src/ArtCoinsToken.sol"
  [ArtCoinsDeployer]="src/utils/ArtCoinsDeployer.sol"
  [ArtCoinsHookStaticFeeV2]="src/hooks/ArtCoinsHookStaticFeeV2.sol"
  [ArtCoinsPoolExtensionAllowlist]="src/hooks/ArtCoinsPoolExtensionAllowlist.sol"
  [ArtCoinsLpLockerMultiple]="src/lp-lockers/ArtCoinsLpLockerMultiple.sol"
  [ArtCoinsMevTimeDelay]="src/mev-modules/ArtCoinsMevTimeDelay.sol"
  [ArtCoinsMevDescendingFees]="src/mev-modules/ArtCoinsMevDescendingFees.sol"
  [ArtCoinsMevLinearFees]="src/mev-modules/ArtCoinsMevLinearFees.sol"
  [ArtCoinsMevSniperSteppedFees]="src/mev-modules/ArtCoinsMevSniperSteppedFees.sol"
  [ArtCoinsVault]="src/extensions/ArtCoinsVault.sol"
  [ArtCoinsAirdrop]="src/extensions/ArtCoinsAirdrop.sol"
  [BurnExtension]="src/extensions/BurnExtension.sol"
  [ArtCoinsUniv4EthDevBuy]="src/extensions/ArtCoinsUniv4EthDevBuy.sol"
  [DefaultMetadataRenderer]="src/renderer/DefaultMetadataRenderer.sol"
  [LiquidityLayerCounterPoolExtension]="src/extensions/LiquidityLayerCounterPoolExtension.sol"
  [LiquidityLayerOnchainRenderer]="src/extensions/LiquidityLayerOnchainRenderer.sol"
  [BurnRouter]="src/protocol-fee/BurnRouter.sol"
  [ProtocolFeeController]="src/protocol-fee/ProtocolFeeController.sol"
  [LiquiditySupportReceiver]="src/protocol-fee/LiquiditySupportReceiver.sol"
)

verify_broadcast() {
  local script="$1"
  local f="broadcast/$script/$CHAIN_ID/run-latest.json"
  if [ ! -f "$f" ]; then
    echo "(no broadcast for $script on chain $CHAIN_ID — skipping)"
    return
  fi
  echo "--- $script ---"
  jq -r '.transactions[] | select(.transactionType=="CREATE" or .transactionType=="CREATE2") | "\(.contractName)\t\(.contractAddress)"' "$f" \
  | while IFS=$'\t' read -r name addr; do
      src="${SRC_PATH[$name]:-}"
      if [ -z "$src" ]; then
        echo "  ! skipping $name @ $addr — no SRC_PATH mapping (add it to this script)"
        continue
      fi
      echo "→ $name @ $addr"
      forge verify-contract "$addr" "$src:$name" $CHAIN_FLAG \
        --rpc-url "$RPC_URL" \
        --etherscan-api-key "$ETHERSCAN_API_KEY" \
        --guess-constructor-args \
        --watch || true
      echo
    done
}

verify_broadcast Deploy.s.sol
verify_broadcast DeployProtocolFeeStack.s.sol

echo "=== verify-stack.sh complete ==="
