# Le Blab — privacy and data handling

Checked against Mistral's published terms on 2026-10-21. Le Blab cannot see your Mistral account
settings, so it never claims zero retention.

## What leaves your Mac

| Data | Destination | When |
|---|---|---|
| Microphone audio | Mistral API (selected region), `voxtral-mini-transcribe-realtime-3-0` | Streamed live, only while the shortcut is active |
| Same audio again (accuracy mode only) | Mistral API, `voxtral-small-transcribe-3-0` | On release |
| Same audio (network-failure fallback / Retry only) | Mistral API, `voxtral-mini-transcribe-3-0` | Only if the stream failed |
| Your vocabulary terms | Mistral API (`context_bias`) | Start of each dictation |
| Transcript text (smart formatting only) | Mistral API, `mistral-small-2603` | Only when it needs cleanup (self-corrections, lists, spoken punctuation/URLs, spelled-out numbers, long dictation); clean transcripts are finished locally. To save time the live transcript may be sent a moment early (at key release or while you pause), but only text that would go to the model anyway |
| Nothing but a TLS handshake | `HEAD /v1/chat/completions`, no key, no body | Connection warm-up while recording |

Never sent: other apps' text (the single character next to the cursor is read locally for
spacing), app names, window titles, screenshots, analytics, telemetry, crash reports. Le Blab
contains no analytics or crash-reporting SDKs.

Turn off **Smart formatting** (Settings → Formatting or Privacy) and transcripts are not sent to
any additional model.

## On this Mac

- **API key**: macOS Keychain (generic password, service `local.leblab.LeBlab`). Never in
  UserDefaults, files, logs or Git.
- **Audio**: in memory only; buffers are zeroed after each dictation. If a dictation fails, its
  audio is kept in memory for one Retry until you dismiss it or start the next dictation. No audio
  file is ever written — batch uploads wrap the PCM in a WAV header in memory.
- **Transcripts**: in memory ("Copy Last Transcript"). Optional local history is **off by
  default**; when on, it's `~/Library/Application Support/Le Blab/history.json`, permissions 0600,
  excluded from Time Machine, auto-pruned (30 days default), and deleted when history is turned off.
  "Clear history" and "Delete all Le Blab data" are in Settings.
- **Clipboard**: when pasting, the dictated text is marked transient/concealed
  (nspasteboard.org conventions) so clipboard managers skip it, and your previous clipboard is
  restored. If insertion is impossible, the clipboard is *not* overwritten — the overlay offers Copy.
- **Logs**: unified logging, subsystem `local.leblab.LeBlab`; states, timings and error categories
  only — never transcript text, audio or keys.
- **Network**: TLS 1.2+, ephemeral `URLSession` (no disk cache, no cookies).

## At Mistral (remote processing)

- **Retention**: Mistral's privacy policy says API inputs and outputs are kept for 30 rolling days
  to monitor abuse, unless Zero Data Retention (ZDR) is activated. Audio is "input".
- **ZDR** is not on by default; it's granted on request for pay-as-you-go stateless API calls.
  Whether the realtime WebSocket path is covered isn't stated explicitly — ask Mistral.
- **Training** is a separate control from retention: it depends on your plan and the
  "Anonymous improvement data" privacy toggle in the Mistral admin console. Turning off training
  does not shorten retention.
- **Preview model**: Voxtral Mini Transcribe Realtime 3 is labelled *Public Preview*. Mistral's
  commercial terms set different data-use rules for preview models, and opt-outs (including ZDR)
  may not apply. Confirm with Mistral before dictating sensitive material.
- **Region**: Settings → Transcription → API region can pin `api.eu.mistral.ai` or
  `api.us.mistral.ai` (regional inference; Mistral notes control-plane data isn't fully regional).

## Mistral documents

- Privacy Policy — https://legal.mistral.ai/terms/privacy-policy
- Data Processing Addendum — https://legal.mistral.ai/terms/data-processing-addendum
- Commercial Terms of Service — https://legal.mistral.ai/terms/commercial-terms-of-service
- Zero Data Retention — https://docs.mistral.ai/admin/monitor-comply/zero-data-retention
- Training opt-out — https://help.mistral.ai/en/articles/455207-can-i-opt-out-of-my-input-or-output-data-being-used-for-training
- Regional inference — https://docs.mistral.ai/inference/regional-inference
