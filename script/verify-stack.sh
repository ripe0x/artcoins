#!/usr/bin/env bash
# One-shot Etherscan verification for a deployed stack.
#
# Mainnet (--chain 1, default): reads deployments/mainnet.json (the registry), and for every
# contract of the chosen stack whose source.bytecodeMatch is "verified" submits it to
# Etherscan at the registry address. Contracts with no repo source or a bytecode mismatch
# are listed and skipped. Idempotent: Etherscan answers "Already Verified" on retry.
# Constructor args are recovered with `forge verify-contract --guess-constructor-args`.
# Exits non zero if any verification failed.
#
# Sepolia (--chain 11155111): the registry is mainnet only, so this walks the broadcast
# records under broadcast/<script>/<chain>/run-latest.json as before.
#
# Usage:
#   ETHERSCAN_API_KEY=... ./script/verify-stack.sh [--chain <id>] [--stack current|open|legacy|all] [--dry-run]
#     --chain 1            mainnet (default)
#     --chain 11155111     sepolia
#     --stack <id>         registry stack to verify on mainnet (default: current)
#     --dry-run            print the forge commands, send nothing, no api key needed
# The api key is read from the environment by forge, it is never put on argv.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

CHAIN_ID=1
STACK=current
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --chain) CHAIN_ID="$2"; shift 2 ;;
    --stack) STACK="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "$DRY_RUN" = "0" ]; then
  : "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY must be set (in .env or environment)}"
fi

case "$CHAIN_ID" in
  1)         CHAIN_FLAG="--chain mainnet"; RPC_URL="${MAINNET_RPC_URL:-https://mainnet.gateway.tenderly.co}" ;;
  11155111)  CHAIN_FLAG="--chain sepolia"; RPC_URL="${SEPOLIA_RPC_URL:-}" ;;
  *) echo "unsupported chain id: $CHAIN_ID" >&2; exit 2 ;;
esac

: "${RPC_URL:?Set MAINNET_RPC_URL or SEPOLIA_RPC_URL in .env (needed for --guess-constructor-args)}"

FAILED=0

run_verify() { # addr, src:name, profile (empty = default), extra args...
  local addr="$1" target="$2" profile="$3"; shift 3
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] ${profile:+FOUNDRY_PROFILE=$profile }forge verify-contract $addr $target $CHAIN_FLAG --guess-constructor-args --watch $*"
    return
  fi
  if ! FOUNDRY_PROFILE="${profile:-${FOUNDRY_PROFILE:-default}}" forge verify-contract "$addr" "$target" $CHAIN_FLAG \
      --rpc-url "$RPC_URL" \
      --guess-constructor-args \
      --watch "$@"; then
    echo "  ! verification FAILED for $target @ $addr" >&2
    FAILED=$((FAILED + 1))
  fi
  echo
}

echo "=== verify-stack chain=$CHAIN_ID ==="
echo

verify_registry() {
  local reg="deployments/mainnet.json"
  [ -f "$reg" ] || { echo "missing $reg" >&2; exit 2; }
  local filter='.contracts[] | select($stack == "all" or .stack == $stack)'
  echo "registry $reg, stack: $STACK"
  jq -r --arg stack "$STACK" "$filter"' | select(.source.repoPath == null or .source.bytecodeMatch != "verified")
      | "  - skip \(.stack) \(.name) @ \(.address): \(if .source.repoPath == null then "no repo source" else "bytecode " + .source.bytecodeMatch end)"' "$reg"
  # process substitution (not a pipe) so FAILED counted inside the loop survives it
  while IFS=$'\t' read -r stack name addr src profile; do
      libs=()
      # external libraries linked into the factory and the skim hook (same stack)
      case "$name" in
        ArtCoinsFactory)     lib=ArtCoinsDeployer ;;
        ArtCoinsHookSkimFee) lib=SkimFeeInitLib ;;
        *)                   lib="" ;;
      esac
      if [ -n "$lib" ]; then
        read -r lsrc laddr < <(jq -r --arg s "$stack" --arg n "$lib" \
          '.contracts[] | select(.stack == $s and .name == $n) | [.source.repoPath, .address] | @tsv' "$reg" | head -n1)
        [ -n "${laddr:-}" ] && libs=(--libraries "$lsrc:$lib:$laddr")
      fi
      echo "-> $stack $name @ $addr"
      run_verify "$addr" "$src:$name" "$profile" ${libs[@]+"${libs[@]}"}
    done < <(jq -r --arg stack "$STACK" "$filter"' | select(.source.repoPath != null and .source.bytecodeMatch == "verified")
      | [.stack, .name, .address, .source.repoPath, (if (.notes | test("out/ci")) then "ci" else "" end)] | @tsv' "$reg")
}

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
  while IFS=$'\t' read -r name addr; do
      src="${SRC_PATH[$name]:-}"
      if [ -z "$src" ]; then
        echo "  ! skipping $name @ $addr — no SRC_PATH mapping (add it to this script)"
        continue
      fi
      echo "→ $name @ $addr"
      run_verify "$addr" "$src:$name" ""
    done < <(jq -r '.transactions[] | select(.transactionType=="CREATE" or .transactionType=="CREATE2") | "\(.contractName)\t\(.contractAddress)"' "$f")
}

if [ "$CHAIN_ID" = "1" ]; then
  verify_registry
else
  verify_broadcast Deploy.s.sol
  verify_broadcast DeployProtocolFeeStack.s.sol
fi

if [ "$FAILED" -gt 0 ]; then
  echo "=== verify-stack.sh: $FAILED verification(s) FAILED ===" >&2
  exit 1
fi
echo "=== verify-stack.sh complete ==="
