#!/usr/bin/env bash
# Pre-broadcast sanity check before LaunchLayer.
#
# Wraps `forge script script/PreflightLaunch.s.sol` so operators can run it
# the same way as the deploy scripts. Uses MAINNET_RPC_URL by default —
# override via --rpc-url.
#
# Usage:
#   ./script/preflight-launch.sh                       # uses MAINNET_RPC_URL
#   ./script/preflight-launch.sh --rpc-url $SEPOLIA_RPC_URL
#
# targets superseded stack legacy (LAYER); current stack is 0x4959...
# On mainnet (chain id 1) this refuses to run unless ALLOW_SUPERSEDED=1, and any
# stack address missing from .env / the shell is filled from deployments/mainnet.json
# (the registry, stack "legacy"). Needs jq and cast.
#
# Requires .env (or shell env) with the non address inputs LaunchLayer reads
# (PRIVATE_KEY, ARTIST_TREASURY, STARTING_TICK, ...). Addresses may be omitted on mainnet.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

RPC_URL="${MAINNET_RPC_URL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --rpc-url) RPC_URL="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${RPC_URL:?Set MAINNET_RPC_URL in .env or pass --rpc-url}"

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [ "$CHAIN_ID" = "1" ]; then
  if [ "${ALLOW_SUPERSEDED:-0}" != "1" ]; then
    echo "preflight-launch targets superseded stack legacy; current stack is 0x4959... Set ALLOW_SUPERSEDED=1 to run on mainnet." >&2
    exit 2
  fi
  REG="deployments/mainnet.json"
  reg_addr() { # stack, contract name, optional index among same named contracts
    jq -r --arg s "$1" --arg n "$2" --argjson i "${3:-0}" \
      '[.contracts[] | select(.stack == $s and .name == $n)][$i].address // empty' "$REG"
  }
  default_env() { # VAR, address (never overrides a value the operator set)
    if [ -z "${!1:-}" ]; then
      [ -n "$2" ] || { echo "registry has no address for $1" >&2; exit 2; }
      export "$1=$2"
    fi
  }
  default_env FACTORY                 "$(reg_addr legacy ArtCoinsFactory)"
  default_env HOOK                    "$(reg_addr legacy ArtCoinsHookStaticFeeV2)"
  default_env LOCKER                  "$(reg_addr legacy ArtCoinsLpLockerMultiple)"
  default_env MEV_SNIPER_STEPPED      "$(reg_addr legacy ArtCoinsMevSniperSteppedFees)"
  default_env AIRDROP                 "$(reg_addr legacy ArtCoinsAirdropV2)"
  default_env BURN_EXTENSION          "$(reg_addr legacy BurnExtension)"
  default_env LL_COUNTER              "$(reg_addr legacy LiquidityLayerCounterPoolExtension)"
  default_env LL_RENDERER             "$(reg_addr legacy LiquidityLayerOnchainRenderer 1)"
  default_env PROTOCOL_FEE_CONTROLLER "$(reg_addr legacy ProtocolFeeController)"
  default_env BURN_ROUTER             "$(reg_addr legacy BurnRouter)"
fi

exec forge script script/PreflightLaunch.s.sol --rpc-url "$RPC_URL" -vv
