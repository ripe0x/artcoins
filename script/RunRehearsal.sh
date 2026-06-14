#!/usr/bin/env bash
# Mainnet launch-day rehearsal runner.
#
# Runs MainnetLaunchRehearsalForkTest end-to-end against a real mainnet RPC
# fork. Captures the per-scenario console output to tmp/ for review.
#
# Usage:
#   MAINNET_RPC_URL=...  ./script/RunRehearsal.sh
#   (or source ./.env first)

set -euo pipefail

if [ -z "${MAINNET_RPC_URL:-}" ] && [ -f .env ]; then
    set -a; . ./.env; set +a
fi
: "${MAINNET_RPC_URL:?MAINNET_RPC_URL must be set (or in .env)}"

mkdir -p tmp
LOG="tmp/rehearsal-$(date -u +%Y%m%dT%H%M%SZ).log"
SUMMARY="${LOG%.log}.summary.txt"

echo "Running mainnet launch rehearsal..."
echo "Log: $LOG"
echo "Summary: $SUMMARY"

forge test \
    --match-contract MainnetLaunchRehearsalForkTest \
    --fork-url "$MAINNET_RPC_URL" \
    -vv 2>&1 | tee "$LOG"

awk '
BEGIN {
    current = ""
    in_logs = 0
}
/^\[PASS\] test_rehearsal_/ {
    current = $0
    sub(/^\[PASS\] /, "", current)
    sub(/ \(gas:.*$/, "", current)
    print current
    in_logs = 0
    next
}
/^Logs:$/ {
    if (current != "") in_logs = 1
    next
}
in_logs {
    if ($0 ~ /^  /) {
        line = $0
        sub(/^  /, "", line)
        print line
        next
    }
    if ($0 ~ /^$/) next
    in_logs = 0
}
/^Suite result:/ || /^Ran [0-9]+ tests? for / || /^Ran [0-9]+ test suites? in / {
    print $0
}
' "$LOG" > "$SUMMARY"

echo
echo "Done."
echo "Raw log: $LOG"
echo "Summary: $SUMMARY"
echo
cat "$SUMMARY"
