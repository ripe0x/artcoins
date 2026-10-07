#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || { echo "run this script with bash: script/v2/deploy.sh <local|mainnet>" >&2; exit 2; }
# One deploy path for the v2 stack (D66). The environment is a values file, script/v2/env/<env>.env
# (envs: local, mainnet). Every step below runs for every env.
#
# Usage:
#   script/v2/deploy.sh <local|mainnet>                simulation only (DRY_RUN defaults to 1)
#   DRY_RUN=0 script/v2/deploy.sh <local|mainnet>      broadcast
#
# Order: required values, rpc chain id, wallet and git guards, warm ci build, dry run, signer check and typed
# confirmation (WALLET_MODE=account), broadcast (--slow), readback, record at $RECORD, verify-v2.sh (VERIFY=full|chain).
#
# Env file values: CHAIN_ID RPC_DEFAULT FOUNDRY_PROFILE WALLET_MODE (account|unlocked) KEYSTORE OWNER
#   TREASURY TREASURY_BPS DEPLOY_FEE (wei) PROTOCOL_BPS MIN_PROTOCOL_SKIM_SHARE_BPS MIN_LP_FEE
#   REFERRAL_PAYOUT (optional, empty = the v2 escrow) VERIFY (full|chain|none) REQUIRE_CLEAN_GIT
#   BROADCAST_DIR DEPLOY_JSON RECORD.
# Shell:
#   RPC_URL            rpc endpoint, overrides RPC_DEFAULT. Cast and forge read it from the environment, messages show scheme and host
#   DRY_RUN            exactly 1 (default) or 0. 1 runs every guard (git guards warn) and the simulation
#   ETHERSCAN_API_KEY  read by forge for VERIFY=full
# The record is a registry fragment ({stacks, contracts}). Merge it with
#   node script-js/merge-v2.mjs <record>

set -euo pipefail

ENV_NAME="${1:-}"
case "$ENV_NAME" in
  local | mainnet) ;;
  *) echo "usage: script/v2/deploy.sh <local|mainnet>" >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
for t in forge cast jq node git; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done

DRY_RUN="${DRY_RUN:-1}"
case "$DRY_RUN" in 0 | 1) ;; *) echo "refusing: DRY_RUN must be 0 or 1, got '$DRY_RUN'" >&2; exit 1 ;; esac
RPC_OVERRIDE="${RPC_URL:-}"
ENV_FILE="script/v2/env/${ENV_NAME}.env"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 2; }
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

die() { echo "refusing: $*" >&2; exit 1; }
soft() { # enforced on a real run, reported on a dry run
  if [ "$DRY_RUN" = 1 ]; then echo "warn (dry run): $*" >&2; else die "$*"; fi
}

for v in CHAIN_ID RPC_DEFAULT FOUNDRY_PROFILE WALLET_MODE OWNER TREASURY TREASURY_BPS DEPLOY_FEE PROTOCOL_BPS \
  MIN_PROTOCOL_SKIM_SHARE_BPS MIN_LP_FEE VERIFY REQUIRE_CLEAN_GIT BROADCAST_DIR DEPLOY_JSON RECORD; do
  [ -n "${!v:-}" ] || die "$ENV_FILE has no $v. Set it before deploying."
done
[ "$FOUNDRY_PROFILE" = ci ] || die "FOUNDRY_PROFILE must be ci (D45)"
case "$WALLET_MODE" in
  account) [ -n "${KEYSTORE:-}" ] || die "$ENV_FILE has no KEYSTORE" ;;
  unlocked) ;;
  *) die "WALLET_MODE must be account or unlocked" ;;
esac
case "$VERIFY" in full | chain | none) ;; *) die "VERIFY must be full, chain or none" ;; esac
[ -n "${REFERRAL_PAYOUT:-}" ] || unset REFERRAL_PAYOUT
export FOUNDRY_PROFILE FOUNDRY_BROADCAST="$BROADCAST_DIR"

# the rpc url can carry an api key: it travels in ETH_RPC_URL (cast) and FOUNDRY_ETH_RPC_URL (forge) and messages show scheme and host
RPC="${RPC_OVERRIDE:-$RPC_DEFAULT}"
export ETH_RPC_URL="$RPC" FOUNDRY_ETH_RPC_URL="$RPC"
RPC_HOST="${RPC#*://}"; RPC_HOST="${RPC_HOST%%[/?#]*}"; RPC_HOST="${RPC_HOST##*@}"
RPC_SHOWN="${RPC%%://*}://$RPC_HOST"
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

echo "== deploy.sh $ENV_NAME =="
echo "  rpc      $RPC_SHOWN"
echo "  profile  $FOUNDRY_PROFILE"
echo "  owner    $OWNER"
echo "  wallet   $WALLET_MODE${KEYSTORE:+ ($KEYSTORE)}"
echo "  dry run  $DRY_RUN"

# --- guards
got=$(cast chain-id) || die "rpc $RPC_SHOWN unreachable"
[ "$got" = "$CHAIN_ID" ] || die "rpc chain id $got, $ENV_FILE says $CHAIN_ID"
echo "ok   rpc chain id $got"

if [ "$WALLET_MODE" = unlocked ]; then
  case "$RPC_HOST" in
    127.0.0.1 | 127.0.0.1:[0-9]* | localhost | localhost:[0-9]* | \[::1\] | \[::1\]:[0-9]*) ;;
    *) die "unlocked signing needs a loopback rpc, got $RPC_SHOWN" ;;
  esac
  cast rpc anvil_nodeInfo >/dev/null 2>&1 || die "$RPC_SHOWN does not answer anvil_nodeInfo: not an anvil node"
  code=$(cast code "$OWNER") || die "cast code failed for $OWNER"
  [ "$code" = 0x ] || die "$OWNER has code on this rpc (a mainnet 7702 delegation on a fork). Run: cast rpc anvil_setCode $OWNER 0x"
  echo "ok   anvil node, unlocked owner has no code"
fi

if [ "$REQUIRE_CLEAN_GIT" = true ]; then
  branch=$(git rev-parse --abbrev-ref HEAD)
  head=$(git rev-parse HEAD)
  tag=$(git describe --exact-match --tags HEAD 2>/dev/null || true)
  if [ -n "$tag" ]; then
    remote=$(git ls-remote --tags origin "refs/tags/$tag^{}" "refs/tags/$tag" | awk 'NR==1{c=$1} /\^\{\}$/{c=$1} END{print c}') \
      || soft "git ls-remote origin failed"
    [ "${remote:-}" = "$head" ] || soft "tag $tag is not on origin at HEAD $head"
  elif [ "$branch" = v2 ]; then
    git fetch --quiet origin v2 || soft "git fetch origin v2 failed"
    [ "$head" = "$(git rev-parse origin/v2 2>/dev/null || echo none)" ] || soft "HEAD is not origin/v2"
  else
    soft "HEAD is on $branch, deploy from branch v2 or a tag"
  fi
  [ -z "$(git status --porcelain)" ] || soft "working tree is not clean"
  echo "ok   git ${tag:-$branch} ${head:0:8}"
else
  echo "skip git guard (REQUIRE_CLEAN_GIT=false)"
fi

# --- warm build, then the dry run (the hook CREATE2 salt depends on the sender)
echo "== build (profile $FOUNDRY_PROFILE) =="
forge build --skip 'test/**'

SCRIPT=script/v2/DeployV2Stack.s.sol
echo "== dry run =="
SIM=$(mktemp -t v2-sim.XXXXXX)
forge script "$SCRIPT" --sender "$OWNER" | tee "$SIM"
grep -q 'post deploy asserts: ok' "$SIM" || die "dry run did not reach the post deploy asserts (see $SIM)"
rm -f "$SIM"
if [ "$DRY_RUN" = 1 ]; then echo "DRY_RUN=1: simulation complete"; exit 0; fi

# --- signer check and typed confirmation
wallet=(--unlocked)
if [ "$WALLET_MODE" = account ]; then
  wallet=(--account "$KEYSTORE")
  signer=$(cast wallet address --account "$KEYSTORE") || die "cannot read the address of keystore $KEYSTORE"
  [ "$(lc "$signer")" = "$(lc "$OWNER")" ] || die "keystore $KEYSTORE is $signer, OWNER is $OWNER"
  echo "ok   keystore $KEYSTORE is OWNER"
  suffix="${OWNER: -6}"
  [ -r /dev/tty ] || die "no terminal for the confirmation"
  printf 'broadcast on chain %s from %s. type the last 6 hex digits of OWNER to continue: ' "$CHAIN_ID" "$OWNER" >/dev/tty
  read -r answer </dev/tty
  [ "$(lc "$answer")" = "$(lc "$suffix")" ] || die "confirmation does not match"
fi

# --- broadcast
echo "== broadcast =="
LOG=$(mktemp -t v2-deploy.XXXXXX)
forge script "$SCRIPT" --sender "$OWNER" "${wallet[@]}" --broadcast --slow | tee "$LOG"
grep -q 'post deploy asserts: ok' "$LOG" || die "broadcast output has no 'post deploy asserts: ok' (see $LOG)"
rm -f "$LOG"
echo "ok   post deploy asserts"

# --- readback
echo "== readback =="
J="$DEPLOY_JSON"
[ "$(jq -r '.chainId // empty' "$J")" = "$CHAIN_ID" ] || die "$J is for another chain"
addr_of() { local a; a=$(jq -r ".addresses.$1 // empty" "$J"); [ -n "$a" ] || die "no $1 address in $J"; printf '%s' "$a"; }
code_at() { local c; c=$(cast code "$2") || die "cast code failed for $1 $2"; { [ -n "$c" ] && [ "$c" != 0x ]; } || die "no code at $1 $2"; }
for k in escrow allowlist hook locker mev factory tokenDeployer burnRouter controller keeper; do
  code_at "$k" "$(addr_of "$k")"
done
echo "ok   code at all 10 contracts"
F=$(addr_of factory)
[ "$(cast call "$F" 'deprecated()(bool)')" = true ] || die "factory is not deprecated"
fee=$(cast call "$F" 'deployFee()(uint256)' | awk '{print $1}')
[ "$fee" = "$DEPLOY_FEE" ] || die "factory deployFee $fee, expected $DEPLOY_FEE"
for k in escrow hook locker factory; do
  a=$(addr_of "$k")
  o=$(cast call "$a" 'owner()(address)')
  p=$(cast call "$a" 'pendingOwner()(address)')
  if [ "$(lc "$o")" = "$(lc "$OWNER")" ]; then :
  elif [ "$(lc "$p")" = "$(lc "$OWNER")" ]; then echo "note $k: ownership pending, OWNER must acceptOwnership()"
  else die "$k owner $o pending $p, expected $OWNER"; fi
done
echo "ok   factory deprecated, deployFee $DEPLOY_FEE, owners"

# --- record, then verify
BCAST="$BROADCAST_DIR/DeployV2Stack.s.sol/$CHAIN_ID/run-latest.json"
[ -f "$BCAST" ] || die "no broadcast record at $BCAST"
mkdir -p "$(dirname "$RECORD")"
node script-js/v2-record.mjs "$J" "$BCAST" "$RECORD"
echo "ok   record $RECORD"

if [ "$VERIFY" != none ]; then
  if [ "$(jq -r '.ownershipPending // empty' "$J")" = true ]; then
    echo "skip verify: ownership is pending. After the acceptOwnership calls run: script/v2/verify-v2.sh --json $J && node script-js/v2-record.mjs $J $BCAST $RECORD --verified"
  else
    flags=(--json "$J")
    [ "$VERIFY" = chain ] && flags+=(--skip-source)
    MAINNET_RPC_URL="$RPC" script/v2/verify-v2.sh "${flags[@]}"
    node script-js/v2-record.mjs "$J" "$BCAST" "$RECORD" --verified
  fi
fi
echo "deploy.sh $ENV_NAME: ok. next: node script-js/merge-v2.mjs $RECORD"
