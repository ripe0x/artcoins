#!/usr/bin/env bash
# One deploy path for the v2 stack (D66). The environment is a values file, script/v2/env/<env>.env
# (envs: local, mainnet). Every step below runs for every env.
#
# Usage:
#   script/v2/deploy.sh <local|mainnet>
#
# Order: required values, rpc chain id, wallet and git guards, warm ci build, dry run, broadcast
# (--slow), readback, record at $RECORD, verify-v2.sh (VERIFY=full|chain).
#
# Env file values: CHAIN_ID RPC_DEFAULT FOUNDRY_PROFILE WALLET_MODE (account|unlocked) KEYSTORE OWNER
#   TREASURY TREASURY_BPS DEPLOY_FEE (wei) PROTOCOL_BPS MIN_PROTOCOL_SKIM_SHARE_BPS MIN_LP_FEE
#   REFERRAL_PAYOUT (optional, empty = the v2 escrow) VERIFY (full|chain|none) REQUIRE_CLEAN_GIT
#   BROADCAST_DIR DEPLOY_JSON RECORD.
# Shell:
#   RPC_URL            rpc endpoint, overrides RPC_DEFAULT
#   DRY_RUN=1          runs every guard (git guards warn) and the simulation, no wallet, no broadcast
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
for t in forge cast jq node; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done

DRY_RUN="${DRY_RUN:-0}"
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

RPC="${RPC_OVERRIDE:-$RPC_DEFAULT}"
echo "== deploy.sh $ENV_NAME =="
echo "  rpc      $RPC"
echo "  profile  $FOUNDRY_PROFILE"
echo "  owner    $OWNER"
echo "  wallet   $WALLET_MODE${KEYSTORE:+ ($KEYSTORE)}"
echo "  dry run  $DRY_RUN"

# --- guards
got=$(cast chain-id --rpc-url "$RPC") || die "rpc $RPC unreachable"
[ "$got" = "$CHAIN_ID" ] || die "rpc chain id $got, $ENV_FILE says $CHAIN_ID"
echo "ok   rpc chain id $got"

if [ "$WALLET_MODE" = unlocked ]; then
  case "$RPC" in
    http://127.0.0.1:* | http://localhost:* | http://\[::1\]:*) ;;
    *) die "unlocked signing needs a loopback rpc, got $RPC" ;;
  esac
  [ "$(cast code "$OWNER" --rpc-url "$RPC")" = 0x ] \
    || die "$OWNER has code on this rpc (a mainnet 7702 delegation on a fork). Run: cast rpc anvil_setCode $OWNER 0x --rpc-url $RPC"
  echo "ok   unlocked owner has no code"
fi

if [ "$REQUIRE_CLEAN_GIT" = true ]; then
  branch=$(git rev-parse --abbrev-ref HEAD)
  tag=$(git describe --exact-match --tags HEAD 2>/dev/null || true)
  if [ "$branch" != v2 ] && [ -z "$tag" ]; then soft "HEAD is on $branch, deploy from branch v2 or a tag"; fi
  if [ "$branch" = v2 ] && [ -z "$tag" ]; then
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/v2 2>/dev/null || echo none)" ] \
      || soft "local v2 is not the fetched origin/v2 commit (git fetch origin first)"
  fi
  [ -z "$(git status --porcelain)" ] || soft "working tree is not clean"
  echo "ok   git ${tag:-$branch} $(git rev-parse --short HEAD)"
else
  echo "skip git guard (REQUIRE_CLEAN_GIT=false)"
fi

# --- warm build, then the dry run (the hook CREATE2 salt depends on the sender)
echo "== build (profile $FOUNDRY_PROFILE) =="
forge build --skip 'test/**'

SCRIPT=script/v2/DeployV2Stack.s.sol
echo "== dry run =="
SIM=$(mktemp -t v2-sim.XXXXXX)
forge script "$SCRIPT" --rpc-url "$RPC" --sender "$OWNER" | tee "$SIM"
grep -q 'post deploy asserts: ok' "$SIM" || die "dry run did not reach the post deploy asserts (see $SIM)"
rm -f "$SIM"
if [ "$DRY_RUN" = 1 ]; then echo "DRY_RUN=1: stopping after the simulation"; exit 0; fi

# --- broadcast
wallet=(--unlocked)
[ "$WALLET_MODE" = account ] && wallet=(--account "$KEYSTORE")
echo "== broadcast =="
LOG=$(mktemp -t v2-deploy.XXXXXX)
forge script "$SCRIPT" --rpc-url "$RPC" --sender "$OWNER" "${wallet[@]}" --broadcast --slow | tee "$LOG"
grep -q 'post deploy asserts: ok' "$LOG" || die "broadcast output has no 'post deploy asserts: ok' (see $LOG)"
rm -f "$LOG"
echo "ok   post deploy asserts"

# --- readback
echo "== readback =="
J="$DEPLOY_JSON"
[ "$(jq -r .chainId "$J")" = "$CHAIN_ID" ] || die "$J is for another chain"
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
for k in escrow allowlist hook locker mev factory tokenDeployer burnRouter controller keeper; do
  a=$(jq -r ".addresses.$k" "$J")
  [ "$(cast code "$a" --rpc-url "$RPC")" != 0x ] || die "no code at $k $a"
done
echo "ok   code at all 10 contracts"
F=$(jq -r .addresses.factory "$J")
[ "$(cast call "$F" 'deprecated()(bool)' --rpc-url "$RPC")" = true ] || die "factory is not deprecated"
fee=$(cast call "$F" 'deployFee()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
[ "$fee" = "$DEPLOY_FEE" ] || die "factory deployFee $fee, expected $DEPLOY_FEE"
for k in escrow hook locker factory; do
  a=$(jq -r ".addresses.$k" "$J")
  o=$(cast call "$a" 'owner()(address)' --rpc-url "$RPC")
  p=$(cast call "$a" 'pendingOwner()(address)' --rpc-url "$RPC")
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
  if [ "$(jq -r .ownershipPending "$J")" = true ]; then
    echo "skip verify: ownership is pending. After the acceptOwnership calls run: script/v2/verify-v2.sh --json $J"
  else
    flags=(--json "$J")
    [ "$VERIFY" = chain ] && flags+=(--skip-source)
    MAINNET_RPC_URL="$RPC" script/v2/verify-v2.sh "${flags[@]}"
    node script-js/v2-record.mjs "$J" "$BCAST" "$RECORD" --verified
  fi
fi
echo "deploy.sh $ENV_NAME: ok. next: node script-js/merge-v2.mjs $RECORD"
