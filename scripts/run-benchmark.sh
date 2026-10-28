#!/bin/bash
# Black-box benchmark: Le Blab vs Wispr Flow (or any tool with a hold shortcut).
#
#   scripts/run-benchmark.sh <config.json> [path/to/Le Blab.app under test]
#
# Plays speech clips through the speakers (acoustic loopback into the mic), holds each tool's
# shortcut, and times key release → text in a throwaway TextEdit document via Accessibility.
# Needs: quiet room, speakers on (no headphones), hands off the keyboard, screen unlocked.
set -uo pipefail
cd "$(dirname "$0")/.."
CONFIG="$1"
UNDER_TEST="${2:-$PWD/build/Le Blab.app}"
HARNESS="$PWD/build/Le Blab.app"
OUT_DIR="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['output'])" "$CONFIG")"
LOG="$OUT_DIR.log"; rm -f "$LOG"; mkdir -p "$OUT_DIR"; rm -f "$OUT_DIR/summary.md"

KEY="${MISTRAL_API_KEY:-$(security find-generic-password -s local.murmur.Murmur -a mistral-api-key -w 2>/dev/null)}"
pkill -x LeBlab; sleep 1
# Le Blab under test, with the opt-in benchmark control channel (raw/smart switching).
open -g --env "MISTRAL_API_KEY=$KEY" "$UNDER_TEST" --args --bench-control
unset KEY
sleep 4
# Separate harness process (registers no hotkeys).
open -g -n "$HARNESS" --args --bench "$CONFIG" --bench-log "$LOG"
for _ in $(seq 1 1800); do
  [ -f "$OUT_DIR/summary.md" ] && break
  grep -q "BENCH FAIL\|BENCH ABORT" "$LOG" 2>/dev/null && break
  sleep 1
done
cat "$LOG" 2>/dev/null | tail -60
pkill -x LeBlab; sleep 1
open -g "$PWD/build/Le Blab.app"   # back to the normal instance
