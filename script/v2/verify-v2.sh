#!/usr/bin/env bash
# Source verification and provenance check for the v2 stack (DESIGN d7).
#
# Input: the json DeployV2Stack.s.sol writes (default tmp/v2-deploy-1.json). Its `verify` list
# holds, per contract, the address, the path qualified name and the abi encoded constructor args.
#
#   1. builds src with FOUNDRY_PROFILE=ci (the profile the stack is deployed with) into out/v2-ci
#   2. `forge verify-contract` for every contract (etherscan when ETHERSCAN_API_KEY is set,
#      blockscout otherwise). the hook is always `src/v2/hooks/ArtCoinsHookV2.sol:ArtCoinsHookV2`
#      (src/hooks/legacy/ArtCoinsHookV2.sol has the same contract name)
#   3. chain check: builds a one stack registry file from the json and runs
#      script-js/verify-registry.mjs on it: runtime code equals the local ci build modulo
#      immutables, owners, factory and hook state, escrow depositors, controller router link
#
# Usage:
#   script/v2/verify-v2.sh [--json tmp/v2-deploy-1.json] [--skip-source] [--skip-chain] [--dry-run]
#     --skip-source   only the chain check (no explorer calls)
#     --skip-chain    only the explorer verification
#     --dry-run       print the verify commands, send nothing
# Env: ETHERSCAN_API_KEY (optional, read by forge from foundry.toml, never on argv),
#      MAINNET_RPC_URL (default: tenderly public gateway).
# Exit: 0 all good, 1 a verification or a chain check failed.
# Run it after OWNER accepted ownership: owners are compared with OWNER, a pending hand over
# shows as owner() drift.

set -euo pipefail
cd "$(dirname "$0")/../.."

JSON=tmp/v2-deploy-1.json
SOURCE=1
CHAIN=1
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON="$2"; shift 2 ;;
    --skip-source) SOURCE=0; shift ;;
    --skip-chain) CHAIN=0; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done

export MAINNET_RPC_URL="${MAINNET_RPC_URL:-https://mainnet.gateway.tenderly.co}"
export FOUNDRY_PROFILE=ci
OUT=out/v2-ci

[ -f "$JSON" ] || { echo "no deploy json at $JSON (run script/v2/DeployV2Stack.s.sol first)" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
[ "$(jq -r .chainId "$JSON")" = "1" ] || { echo "$JSON is not a mainnet deploy" >&2; exit 2; }

echo "== build (profile ci) =="
forge build --skip 'test/**' --skip 'script/**' --out "$OUT" --cache-path cache/v2-ci

fail=0

if [ "$SOURCE" = 1 ]; then
  echo "== source verification =="
  if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
    VERIFIER=(--verifier etherscan)
  else
    echo "ETHERSCAN_API_KEY unset: using blockscout"
    VERIFIER=(--verifier blockscout --verifier-url https://eth.blockscout.com/api/)
  fi
  n=$(jq '.verify | length' "$JSON")
  for i in $(seq 0 $((n - 1))); do
    name=$(jq -r ".verify[$i].name" "$JSON")
    addr=$(jq -r ".verify[$i].address" "$JSON")
    target=$(jq -r ".verify[$i].contract" "$JSON")
    args=$(jq -r ".verify[$i].args" "$JSON")
    cmd=(forge verify-contract "$addr" "$target" --chain mainnet --watch
      --constructor-args "$args" "${VERIFIER[@]}")
    if [ "$DRY" = 1 ]; then
      printf 'FOUNDRY_PROFILE=ci'; printf ' %q' "${cmd[@]}"; echo
      continue
    fi
    echo "-- $name $addr"
    if ! "${cmd[@]}"; then
      echo "FAILED: $name $addr" >&2
      fail=1
    fi
  done
fi

if [ "$CHAIN" = 1 ] && [ "$DRY" = 0 ]; then
  echo "== chain check (runtime vs local ci build, wiring, owners) =="
  [ -d script-js/node_modules ] || (cd script-js && npm install --ignore-scripts --no-audit --no-fund)
  reg=$(mktemp -t v2-registry.XXXXXX.json)
  # one stack registry: verify-registry.mjs schema, every contract expected to match the build.
  # deployBlock: the block the deploy was simulated at, a lower bound for the factory log scan.
  jq --arg commit "$(git rev-parse HEAD)" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    . as $d
    | {chainId: 1, generatedAt: $now, repoCommit: $commit, owner: $d.owner, stacks: $d.stack,
       contracts: [$d.contracts[] | .deployBlock = $d.simulatedAtBlock
                   | .source.bytecodeMatch = "verified"],
       coins: []}' "$JSON" > "$reg"
  if ! node script-js/verify-registry.mjs --file "$reg" --artifacts "$OUT" --require-artifacts; then
    echo "chain check FAILED (registry file kept at $reg)" >&2
    fail=1
  else
    rm -f "$reg"
  fi
fi

if [ "$fail" != 0 ]; then echo "verify-v2: FAILED" >&2; exit 1; fi
echo "verify-v2: ok"
