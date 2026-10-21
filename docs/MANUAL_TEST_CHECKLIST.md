# Manual integration checklist

Build with `scripts/build-app.sh`, launch `build/Le Blab.app`, complete onboarding. Default
shortcut: hold **⌃⇧**. Status column: ✅ verified automatically (scripts/e2e-selftest.sh, probe or
unit tests) · 👤 needs a human at the keyboard/mic.

| # | Scenario | Steps | Expected | Status |
|---|---|---|---|---|
| 1 | Apple Notes | Open a note, place cursor mid-sentence, hold ⌃⇧, say a sentence, release | Text inserted at cursor; space added if needed; nothing else in the note changes; no Return pressed | 👤 (TextEdit verified ✅ via AX) |
| 2 | Chrome | Focus a textarea (e.g. Gmail compose), dictate | Text pasted at cursor, clipboard restored | ✅ textarea via e2e; 👤 Gmail/Docs |
| 3 | Slack | Focus the message box, dictate a long sentence | Text appears, **message is not sent** | 👤 |
| 4 | VS Code / Cursor | Focus an editor and the chat input, dictate code-ish text ("getUserById in user service dot ts") | Identifier and `user.service.ts` written correctly | 👤 (formatter ✅ via probe) |
| 5 | Mail | Compose body, dictate | Inserted (paste path, WebKit) | 👤 |
| 6 | English | Dictate the David example | "Hey David, I just wanted to check if we can move the meeting to Friday at 4 PM." | ✅ e2e TextEdit |
| 7 | German | Language = Automatic, dictate "Ähm, ich wollte nur kurz fragen, ob wir das Meeting auf Freitag verschieben können" | German text, filler removed, not translated | ✅ probe (realtime + formatter) |
| 8 | Switching languages | Dictate EN, then DE, then EN without touching settings | Each comes out in its own language | 👤 (auto-detect ✅ per clip) |
| 9 | Long dictation | Talk for 2–3 minutes | Live preview keeps up; final inserted; paragraphs if multi-topic | 👤 |
| 10 | Technical vocabulary | "Ask CodeRabbit to review the PR on GitHub, ping DevRel about the Voxtral demo from Mistral" | All five terms spelled exactly | ✅ e2e Chrome + probe |
| 11 | Clipboard preservation | Copy an image/rich text, dictate into Chrome, then paste | Original clipboard content pastes | ✅ e2e (hash of all types) |
| 12 | Shortcut cancellation | Hold ⌃⇧, speak, press Esc, release | Nothing inserted; "Dictation cancelled" hint; nothing sent after Esc | ✅ unit; 👤 live |
| 13 | ⌃⇧ used for another shortcut | In an editor press ⌃⇧→ (select word) | Selection works; no overlay, no sound, nothing inserted | ✅ unit; 👤 live |
| 14 | Rapid repeated dictations | Dictate three short phrases back to back without waiting | All three inserted in order | ✅ unit; 👤 live |
| 15 | API/network failure | Turn Wi-Fi off, dictate, release | Error with **Retry**; turn Wi-Fi on, Retry → text inserted | ✅ unit (reconnect, fallback, retry); 👤 live |
| 16 | Bad API key | Settings → Account, save an invalid key | Rejected before saving ("401") | ✅ unit (error mapping); 👤 live |
| 17 | Microphone permission denied | System Settings → Privacy → Microphone → off, dictate | Clear message + link to settings; nothing recorded | ✅ unit; 👤 live |
| 18 | Accessibility missing | Remove Le Blab from Accessibility, dictate | Overlay keeps the transcript with **Copy**; clipboard untouched | ✅ unit; 👤 live |
| 19 | Disabled history | Default settings, dictate, check `~/Library/Application Support/Le Blab/` | No `history.json` exists | ✅ unit |
| 20 | History on/off | Enable history, dictate, view in Settings → History, disable | Entry visible; file deleted on disable | ✅ unit; 👤 UI |
| 21 | Password field | Focus a password field, dictate | Not inserted ("password field / secure input") | 👤 |
| 22 | Mic unplugged | Use AirPods, dictate, take them out mid-sentence | Continues on built-in mic or finalizes what was captured | 👤 |
| 23 | App switch mid-dictation | Start in Notes, ⌘Tab to TextEdit, release | Inserted into the app focused at release | 👤 |
| 24 | Accuracy mode | Settings → Transcription → Accurate, dictate | Slightly slower, Small Transcribe 3 result | ✅ unit + probe batch |
| 25 | Toggle + auto-stop | Activation = toggle, auto-stop on; press once, talk, go quiet | Stops on its own after the pause and inserts | ✅ unit; 👤 live |
| 26 | Overlay focus | Dictate into Slack/Notes | Overlay never takes focus; typing continues in the target app afterwards | 👤 |
| 27 | Latency | Settings → Diagnostics after ~10 dictations | p50 release→insert ≈ 1.2 s smart / ≈ 0.7 s raw | ✅ e2e measured |

## Measuring latency
Settings → Diagnostics shows p50/p90 for key press → first partial, release → final,
release → insertion and Mistral API time, per dictation (timings only, no content), plus a
"Run with synthesized speech" self-test.
