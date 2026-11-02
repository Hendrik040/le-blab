# Le Blab architecture

## Pipeline

```
 HotkeyManager ──press/release/esc──▶ DictationController ──▶ overlay + menu state
   (event tap │ Carbon)                     │
                                            ├─ AudioCaptureManager  (AVAudioEngine → 16 kHz s16le, in memory)
                                            │
                                            ├─ TranscriptionSession (one dictation)
                                            │     ├─ StreamingTranscriber ── VoxtralRealtimeTranscriber ──WSS──▶ Mistral
                                            │     └─ BatchTranscriber     ── VoxtralBatchTranscriber   ──HTTPS─▶ Mistral
                                            │
                                            ├─ TranscriptFormatting ── RawFormatter | SmartFormatter ──HTTPS─▶ Mistral chat
                                            │
                                            └─ TextInserting ── TextInsertionService (AX → paste → typing)
```

| Module | File | Responsibility |
|---|---|---|
| AppCoordinator | `Sources/Le Blab/AppCoordinator.swift` | Wires modules, owns Keychain cache, implements `DictationEnvironment` |
| HotkeyManager | `Sources/LeBlabCore/Hotkey/HotkeyManager.swift` | Global push-to-talk; event tap (preferred) or Carbon fallback |
| AudioCaptureManager | `Sources/LeBlabCore/Audio/AudioCaptureManager.swift` | Mic capture, format conversion, level meter, energy VAD, device selection & hot-swap |
| VoxtralStreamingClient | `Sources/LeBlabCore/Transcription/VoxtralRealtimeClient.swift` | Realtime WebSocket session |
| — protocol | `Sources/LeBlabCore/Transcription/VoxtralRealtimeProtocol.swift` | Wire messages (from the official SDK) |
| TranscriptionSession | `Sources/LeBlabCore/Transcription/TranscriptionSession.swift` | Buffering, reconnect + replay, early finalization, batch fallback, retry |
| TranscriptFormatter | `Sources/LeBlabCore/Formatting/TranscriptFormatter.swift` | Raw vs. smart formatting, guardrails |
| VocabularyCorrector | `Sources/LeBlabCore/Formatting/VocabularyCorrector.swift` | Context-bias terms + conservative spelling fix-ups |
| TextInsertionService | `Sources/LeBlabCore/Insertion/TextInsertionService.swift` | AX insert with verification, clipboard paste with restore, typing |
| PermissionsManager | `Sources/LeBlabCore/Permissions/PermissionsManager.swift` | Microphone + Accessibility status and prompts |
| PrivacyManager | `Sources/LeBlabCore/Privacy/PrivacyManager.swift` | Data-flow disclosure, Mistral legal links |
| HistoryStore | `Sources/LeBlabCore/Privacy/HistoryStore.swift` | Optional local history (off by default) |
| SettingsStore | `Sources/LeBlabCore/Settings/SettingsStore.swift` | UserDefaults-backed preferences |
| KeychainStore | `Sources/LeBlabCore/Settings/KeychainStore.swift` | API key storage |
| DiagnosticsService | `Sources/LeBlabCore/Diagnostics/DiagnosticsService.swift` | Latency timeline and metrics, in memory only |
| DictationController | `Sources/LeBlabCore/Dictation/DictationController.swift` | State machine: start/stop/cancel/toggle, ordered insertion, retry |

Everything below the app target lives in `LeBlabCore` and is unit-tested with fakes.

## Swapping the speech model

`StreamingTranscriber` / `StreamingTranscriptionSession` and `BatchTranscriber`
(`SpeechTranscription.swift`) are the only contracts the rest of the app sees. A local model
(e.g. an on-device Whisper/Parakeet port, or Apple's SpeechAnalyzer on macOS 26) implements them
and is passed to `DictationController` in `AppCoordinator.init` — nothing else changes. The
format contract is fixed: 16 kHz mono s16le PCM in, text deltas + a final text out.

## Voxtral 3 integration — what was verified and why it's direct WebSocket

Verified on 2026-10-21 against:
- docs.mistral.ai audio pages (model table, Voxtral 2 → 3 migration guide)
- the official `mistralai` Python SDK **3.3.0** source (`mistralai/extra/realtime/connection.py`,
  `transcription.py`, generated models `realtimetranscription*.py`, `turndetection*.py`)
- the live `GET /v1/models` list for the account in use

| Purpose | Model id | Endpoint |
|---|---|---|
| Default streaming | `voxtral-mini-transcribe-realtime-3-0` | `wss://api.mistral.ai/v1/audio/transcriptions/realtime?model=…` |
| Accuracy mode (batch) | `voxtral-small-transcribe-3-0` | `POST /v1/audio/transcriptions` (multipart) |
| Network fallback (batch) | `voxtral-mini-transcribe-3-0` | `POST /v1/audio/transcriptions` |
| Smart formatting | `mistral-small-2603` (Mistral Small 4) | `POST /v1/chat/completions` |

Realtime wire protocol (client → server): `session.update` (all settings, before any audio —
settings lock on the first audio chunk), `input_audio.append` (base64 PCM, ≤ 262 144 bytes
decoded), `input_audio.flush`, `input_audio.end`. Server → client: `session.created`,
`session.updated`, `transcription.text.delta`, `transcription.language`, `transcription.segment`,
`transcription.done`, `turn.start|eager_end|resume|end`, `error`. Auth: `Authorization: Bearer`.

**Why not the LiveKit-based voice-agent SDK?** It is built for conversational agents
(STT → LLM → TTS over WebRTC/SIP, with a server minting sessions) and ships for Python and
Node.js only. Its STT stage is the same realtime transcription endpoint used here — the
`livekit-plugins-mistralai` 1.8.8 STT plugin literally wraps `mistralai.extra.realtime` (and
still lists only Voxtral 2 model ids). For dictation, the agent stack would add a Python/Node
helper process, a LiveKit room hop, Silero VAD, and TTS/LLM pieces we don't use — more latency,
more moving parts, more data paths. Talking to the documented WebSocket from Swift
(`URLSessionWebSocketTask`) gives the same model with the shortest path and no local server.

## Latency design (measured, not assumed)

Measured with `leblab-probe` against the live API (6.4 s English clip, 480 ms streaming delay):

| Step | Measured |
|---|---|
| WebSocket connect → `session.created` | 250–370 ms (overlaps with speaking; audio is buffered meanwhile) |
| Key press → first partial | ~1.0–1.3 s at 480 ms delay (~0.75 s at 240 ms) |
| Release → last text delta | 250–450 ms |
| Release → `transcription.done` | 560–1270 ms (done trails the last delta by ~400–500 ms) |
| **Release → final with early finalization** | **~600–690 ms** |
| Smart formatting (Mistral Small 4) | 310–750 ms typical |
| Voxtral Small Transcribe 3 batch (accuracy mode) | ~680–760 ms for 6–7 s audio |

End-to-end inside the app (`scripts/e2e-selftest.sh`, synthesized speech → TextEdit/Chrome):

| Run | connect | first partial | release → final | formatting | **release → inserted** |
|---|---|---|---|---|---|
| TextEdit, AX insert, cold process | 289 ms | 1016 ms | 605 ms | 1574 ms* | 2224 ms* |
| Chrome, paste + clipboard restore, cold | 371 ms | 1099 ms | 613 ms | 1165 ms* | 1804 ms* |
| TextEdit, shared session + warm-up | 279 ms | — | 609 ms | 552 ms | **1210 ms** |

\* before the shared `URLSession` + connection warm-up fix (each dictation was paying a fresh TLS handshake).

Techniques:
1. **Connect in parallel with recording.** Audio captured before `session.created` is queued and
   flushed in order right after `session.update`.
2. **Early finalization.** After release we send `flush` + `end`, then use the streamed text as soon
   as the stream has settled (look-ahead window — streaming delay + 60 ms — elapsed since the audio
   ended, no delta for 100 ms, text ends a sentence) instead of waiting ~500 ms more for
   `transcription.done`. If you were still talking when the audio ended, the words in the look-ahead
   are still coming, so it also waits for a delta that clearly comes from the flush (more than half a
   look-ahead after the audio ended), or 250 ms past the look-ahead without one: a sentence streamed
   while talking ("Sounds good.") is never taken without the words after it. If you had spoken and the
   audio then ended in at least a look-ahead of silence, every word is already in and that extra wait
   is skipped. Never after a reconnect (the replay re-transcribes from the start). The `done` text is
   still received and compared; mismatches are logged (no content). Unfinished sentences always wait
   for `done`.
3. **Pinned, non-reasoning formatter** with `prediction` (predicted outputs) and
   `reasoning_effort: "none"` where supported (Ministral rejects it; learned per model).
4. **Skip the LLM for ≤ 3-word utterances** (local filler/capitalization cleanup instead).
5. **One shared ephemeral `URLSession`** so TLS/HTTP connections are reused, plus a body-less,
   key-less `HEAD` warm-up of the HTTPS connection when recording starts (smart/accuracy modes).
   Measured effect: formatting 1.2–1.6 s → ~0.55 s.
6. Streaming delay is configurable (240 ms faster / 480 ms default / up to 2400 ms). 480 ms was
   chosen because 240 ms misheard a German "ähm" as "Jim" in testing.

## Reliability

- Transient stream failures (network drop, timeout, 5xx, rate limit) → reconnect (×2) and replay
  the whole utterance from memory on a fresh session; preview keeps the best text meanwhile.
- No final from the stream → batch fallback (`voxtral-mini-transcribe-3-0`) with the same audio.
- Everything failed (offline) → overlay shows the error with **Retry**; audio stays in memory
  until retry/dismiss/next dictation, then is zeroed.
- Insertion blocked (no Accessibility, secure input, password field) → transcript kept in the
  overlay (**Copy**) and in "Copy Last Transcript". The clipboard is not overwritten silently.
- Microphone unplugged mid-dictation → engine restarts on the new default device; if that fails
  the dictation is finalized with the audio captured so far.
- Rapid repeated dictations → each reserves its insertion slot at release, so text lands in order.
  Pressing again while the previous one is still capturing its release tail ends that tail at once;
  its delayed stop can't touch the new recording, and chunks queued from the old capture are dropped.

## Shortcut

Default: **hold ⌃⇧ (Control+Shift)**. A modifier chord types nothing, doesn't collide with
Spotlight/input-source shortcuts, and is easy to hold. Because ⌃⇧ is also the start of other apps'
shortcuts (⌃⇧Tab, ⌃⇧→), recording starts immediately (no lost words) but the overlay and sound
appear after 200 ms; if another key joins the chord, the dictation is discarded silently and the
key event passes through untouched. Presets: Fn⇧, ⌥Space, Fn, right ⌥, right ⌘, or any recorded
key combo. ⇧Space was rejected as a default: Shift is held before spaces constantly while typing.

Event tap (preferred, under the Accessibility grant) vs Carbon `RegisterEventHotKey` (fallback for
key combos before Accessibility is granted): see `HotkeyManager.swift`. Input Monitoring is never
requested.

## The duck

`DuckSprite` (in core, unit-tested) rasterizes the mascot from shapes onto a 36×32 grid each frame
and outlines it automatically, so every pose is a parameter set: beak opening follows the mic
level, "sound bits" leave the beak above speech thresholds, it bobs and blinks while listening,
shows "…" dots and a shimmering Mistral-gradient headband while transcribing, hops with ^ ^ eyes
when text lands, and goes ✕ ✕ on errors. The same sprite renders the app icon
(`--render-assets`), and a separate 18×16 silhouette is the menu bar template icon. The overlay is
a non-activating panel; the duck pops up from behind the pill (spring) when dictation starts.

## Latency cuts (v1.1)

Measured clock now starts at the **actual key release** (earlier figures started after the 120 ms
capture tail and were ~120 ms optimistic).

| Cut | What it does | Risk control |
|---|---|---|
| Skip the model for clean transcripts | `FormattingRouter` sends text to the LLM only for self-corrections, enumerations, spoken punctuation/URLs, spelled-out numbers, stutters, fillers like "you know", or > 60 words. Simple fillers ("um,", "äh") are removed locally. | Ambiguous → model. English "um/uh" are only fillers when set off by punctuation, because German "um" means "at". Toggle: Settings → Formatting → Speed. |
| Optimistic insert (native apps) | Locally cleaned text is inserted at once via Accessibility; the polished text replaces exactly that range when it arrives. | Replaced only if the same field is focused, the caret is right after our text and the text is unchanged; otherwise the user's document is left alone (polished text stays copyable). Browsers/Electron/terminals keep the wait-then-paste path. |
| Adaptive release tail | The 120 ms post-release capture is skipped when the last ~150 ms before release were silent. | Any voiced chunk in that window keeps the tail. |
| No modifier wait for AX inserts | Found while measuring: insertion waited up to 400 ms for held modifiers (⌃⇧ release order). Only synthetic-key paths (paste, typing) need that wait. | Paste/typing still wait. |

## Latency v1.2 — "split second" pass

Goal: text in place in well under a second after key release, never twice.

| Change | Effect (measured, in-memory speech, M4 Max) |
|---|---|
| Streaming delay 480 → **240 ms**, tighter settle (look-ahead + 60 ms, 100 ms quiet) | Release → final transcript ~600–830 ms → ~400–500 ms. 240 ms matched 480 ms accuracy on the test clips; 160 ms did not ("maria", German "ähm" → "dem"). |
| Speculative formatting | The live text goes to the formatter at release and when you pause while holding, in parallel with transcription. Reused only if the final words match (a trailing period may differ). |
| Full ⌘V chord when pasting | Le Blab posted only V-with-Command, leaving macOS's combined keyboard state thinking ⌘ was still held: the next insertion waited ~435 ms and its paste could get lost. Now ⌘↓ V↓ V↑ ⌘↑. |
| AX write confirmation window 30 → 250 ms (polling), per-app paste fallback | Apps that apply Accessibility writes late no longer get a second copy via paste — the cause of duplicate text. Apps whose writes don't confirm switch to paste for the session. |
| Replace safety | If a field ignores the selection and appends the polished text, the provisional copy is removed. |
| Pre-warmed audio engine | Engine prepared (not started — mic not live) after each dictation and at launch: start 44 → ~12 ms. |
| Always-on bubble | Reacts the instant the shortcut goes down (pixel bars follow your voice during the 200 ms chord debounce); the full overlay fades in in 60 ms with the duck already up. |
| Speed first in paste apps (on by default) | Browsers/Slack/Electron can't be polished in place; this pastes the locally cleaned text immediately instead of waiting ~0.6 s for the model. Trade-off: self-corrections aren't applied there. Settings → Formatting → Speed. |

Measured (release → text visible, p50): TextEdit clean 523–554 ms, raw ~525–580 ms, correction-sentence first
text 508 ms (polished in place at ~1.15–1.4 s), Chrome clean ~530–540 ms, Chrome correction sentence 573 ms with
Speed first (~1.2 s when waiting for the model). No duplicate insertions in any undisturbed run.
