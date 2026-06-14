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
# Requires .env (or shell env) with all the addresses LaunchLayer reads.

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

exec forge script script/PreflightLaunch.s.sol --rpc-url "$RPC_URL" -vv
