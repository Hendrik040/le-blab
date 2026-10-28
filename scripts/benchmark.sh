#!/bin/bash
# Black-box latency/accuracy benchmark: Le Blab builds (smart + raw) vs Wispr Flow.
#
#   scripts/benchmark.sh probe [new|baseline]   # warm-up trials only: checks every trigger works
#   REPS=3 scripts/benchmark.sh run both        # session A (new) then session B (baseline)
#   WISPR_TRIGGER=human-fn scripts/benchmark.sh run new   # if Wispr ignores synthetic Fn
#
# Each session interleaves one Le Blab build (smart, raw) with Wispr Flow as the shared reference
# (two Le Blab builds can't run at once — both own ⌃⇧). Speech clips are rendered with macOS voices
# and played through the speakers; the harness times key release → text in a throwaway TextEdit
# document via Accessibility. Needs: AC power, quiet room, built-in speakers + mic (no headsets),
# screen unlocked, hands off. Approx. 18 min and ~450 Wispr words per session at REPS=3.
set -uo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-probe}"
WHICH="${2:-new}"
REPS="${REPS:-3}"
WISPR_TRIGGER="${WISPR_TRIGGER:-fn}"
WORK="${BENCH_DIR:-$HOME/Library/Caches/LeBlabBench}"
AUDIO="$WORK/audio"
STAMP="$(date +%Y%m%d-%H%M%S)"
HARNESS="$PWD/build/Le Blab.app"
NEW_APP="$PWD/build/Le Blab.app"
BASELINE_APP="$PWD/build/baseline/Le Blab.app"
mkdir -p "$AUDIO"

clip() { [ -f "$AUDIO/$2.aiff" ] || say -v "$1" ${4:+-r "$4"} -o "$AUDIO/$2.aiff" "$3"; }
clip Samantha en-s1     "Can you send me the latest numbers before lunch?"
clip Samantha en-anchor "Fast speech to text should feel instant." 175
clip Samantha en-fix    "Hey David, um, I just wanted to check if we can move the meeting to Friday at three, actually make that four."
clip Daniel   en-vocab  "Please ask CodeRabbit to review the pull request on GitHub, then ping the DevRel team about the Voxtral demo from Mistral."
clip Samantha en-l1     "Quick update on the launch. The new onboarding flow is finished and tested in both browsers. We still need final copy for the pricing page, and legal wants one more review of the privacy section. If everything goes well, we can ship on Thursday morning and send the announcement email in the afternoon."
clip Anna     de-m1     "Hallo zusammen, ich wollte nur kurz fragen, ob wir das Meeting auf Donnerstag verschieben können, weil das Team noch etwas Zeit braucht."
clip Anna     de-fix    "Lass uns das Meeting auf Dienstag legen, äh, nein, Mittwoch um zehn."

phrases_json() {
  cat <<JSON
  [
    {"id": "en-s1", "lang": "en", "audio": "$AUDIO/en-s1.aiff", "text": "Can you send me the latest numbers before lunch?"},
    {"id": "en-anchor", "lang": "en", "audio": "$AUDIO/en-anchor.aiff", "text": "Fast speech to text should feel instant."},
    {"id": "en-fix", "lang": "en", "kind": "fix", "audio": "$AUDIO/en-fix.aiff",
     "text": "Hey David, um, I just wanted to check if we can move the meeting to Friday at three, actually make that four.",
     "intended": "Hey David, I just wanted to check if we can move the meeting to Friday at four.",
     "variants": ["Hey David, I just wanted to check if we can move the meeting to Friday at four PM."],
     "mustContain": ["four"], "mustNotContain": ["three"]},
    {"id": "en-vocab", "lang": "en", "kind": "vocab", "audio": "$AUDIO/en-vocab.aiff",
     "text": "Please ask CodeRabbit to review the pull request on GitHub, then ping the DevRel team about the Voxtral demo from Mistral.",
     "vocab": ["CodeRabbit", "GitHub", "DevRel", "Voxtral", "Mistral"]},
    {"id": "en-l1", "lang": "en", "audio": "$AUDIO/en-l1.aiff",
     "text": "Quick update on the launch. The new onboarding flow is finished and tested in both browsers. We still need final copy for the pricing page, and legal wants one more review of the privacy section. If everything goes well, we can ship on Thursday morning and send the announcement email in the afternoon."},
    {"id": "de-m1", "lang": "de", "audio": "$AUDIO/de-m1.aiff",
     "text": "Hallo zusammen, ich wollte nur kurz fragen, ob wir das Meeting auf Donnerstag verschieben können, weil das Team noch etwas Zeit braucht."},
    {"id": "de-fix", "lang": "de", "kind": "fix", "audio": "$AUDIO/de-fix.aiff",
     "text": "Lass uns das Meeting auf Dienstag legen, äh, nein, Mittwoch um zehn.",
     "intended": "Lass uns das Meeting auf Mittwoch um zehn legen.",
     "mustContain": ["Mittwoch"], "mustNotContain": ["Dienstag"]}
  ]
JSON
}

run_session() {   # $1 = label (new|baseline), $2 = app under test
  local label="$1" app="$2" ack=true
  [ "$label" = "baseline" ] && ack=false
  [ -d "$app" ] || { echo "missing $app"; return 1; }
  local out="$WORK/results-$STAMP-$label"; mkdir -p "$out"
  local probe=false; [ "$MODE" = "probe" ] && probe=true
  cat > "$out/config.json" <<JSON
{
  "tools": [
    {"name": "leblab-$label-smart", "trigger": "ctrl-shift", "leblabFormatting": "smart", "requireAck": $ack},
    {"name": "leblab-$label-raw",   "trigger": "ctrl-shift", "leblabFormatting": "raw",   "requireAck": $ack},
    {"name": "wispr-flow",          "trigger": "$WISPR_TRIGGER"}
  ],
  "phrases": $(phrases_json),
  "repetitions": $REPS,
  "warmupPerTool": 1,
  "probeOnly": $probe,
  "seed": $([ "$label" = new ] && echo 42 || echo 43),
  "document": "$WORK/bench-$label.txt",
  "output": "$out"
}
JSON
  # The Le Blab build under test, with the opt-in bench control channel.
  pkill -x LeBlab; sleep 1
  local key; key="${MISTRAL_API_KEY:-$(security find-generic-password -s local.murmur.Murmur -a mistral-api-key -w 2>/dev/null)}"
  open -g --env "MISTRAL_API_KEY=$key" "$app" --args --bench-control
  key=""
  sleep 5
  # Separate harness process (no hotkeys of its own).
  local log="$out/run.log"; : > "$log"
  open -g -n "$HARNESS" --args --bench "$out/config.json" --bench-log "$log"
  echo "[$label] running — log: $log"
  for _ in $(seq 1 3600); do grep -qE "BENCH (DONE|FAIL|ABORT)" "$log" 2>/dev/null && break; sleep 2; done
  cat "$log"
  echo "[$label] results: $out"
}

case "$WHICH" in
  new) run_session new "$NEW_APP" ;;
  baseline) run_session baseline "$BASELINE_APP" ;;
  both) run_session new "$NEW_APP"; run_session baseline "$BASELINE_APP" ;;
  *) echo "usage: $0 probe|run new|baseline|both"; exit 2 ;;
esac
# Back to a normal Le Blab instance.
pkill -x LeBlab; sleep 1; open -g "$NEW_APP"
