#!/bin/bash
# End-to-end self-test: synthesized speech (in memory) → Voxtral realtime → formatter → insertion
# into a throwaway TextEdit document or a local Chrome test page. Verifies the inserted text via
# Accessibility read-back and that the clipboard is unchanged afterwards.
#
#   scripts/e2e-selftest.sh textedit "Phrase to speak"
#   scripts/e2e-selftest.sh chrome   "Phrase to speak"
#
# Quits the running Le Blab during the test and relaunches it afterwards.
set -uo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-textedit}"
PHRASE="${2:-Hey David, um, I just wanted to check if we can move the meeting to Friday at three, actually make that four.}"
VOICE="${3:-}"
REPEAT="${REPEAT:-1}"
WORK="${TMPDIR:-/tmp}/leblab-e2e"; mkdir -p "$WORK"
OUT="$WORK/result-$TARGET.txt"; rm -f "$OUT"
APP="$PWD/build/Le Blab.app"

pkill -x LeBlab; sleep 0.5
case "$TARGET" in
  textedit)
    BUNDLE=com.apple.TextEdit
    DOC="$WORK/leblab-e2e-$(date +%s).txt"; : > "$DOC"
    open -a TextEdit "$DOC"
    ;;
  chrome)
    BUNDLE=com.google.Chrome
    PAGE="$WORK/leblab-e2e.html"
    cat > "$PAGE" <<'HTML'
<!doctype html><title>Le Blab E2E</title><body style="font:16px system-ui;padding:24px">
<h3>Le Blab E2E target</h3><textarea id="t" autofocus rows="8" cols="80">Existing text.</textarea>
<script>const t=document.getElementById('t');t.focus();t.setSelectionRange(t.value.length,t.value.length);</script>
HTML
    open -a "Google Chrome" --new --args --new-window "file://$PAGE"
    ;;
  *) echo "unknown target $TARGET"; exit 2 ;;
esac
sleep 2.5
BEFORE=$(.build/pbhash)
ARGS=(--selftest "$PHRASE" --selftest-target "$BUNDLE" --selftest-output "$OUT" --selftest-readback)
[ -n "$VOICE" ] && ARGS+=(--selftest-voice "$VOICE")
ARGS+=(--selftest-repeat "$REPEAT")
[ -n "${FORMATTING:-}" ] && ARGS+=(--selftest-formatting "$FORMATTING")
# Key comes from the environment for test runs (rebuilt dev binaries would re-prompt for Keychain access).
KEY="${MISTRAL_API_KEY:-$(security find-generic-password -s local.leblab.LeBlab -a mistral-api-key -w 2>/dev/null)}"
open -g -n --env "MISTRAL_API_KEY=$KEY" "$APP" --args "${ARGS[@]}"
unset KEY
for _ in $(seq 1 $((80 * REPEAT))); do [ -s "$OUT" ] && break; sleep 0.25; done
sleep 1
AFTER=$(.build/pbhash)
cat "$OUT" 2>/dev/null || echo "no result"
echo "clipboard_unchanged: $([ "$BEFORE" = "$AFTER" ] && echo true || echo false)"
open -g "$APP"   # relaunch the normal instance
