# Le Blab learning dictionary: research and options

*2 Nov 2026. Sources: Wispr Flow's help center and changelog, community reports, competitor code, and Le Blab at `5ffcafd` plus the working tree.*

## TL;DR
- **Wispr's auto-learn is narrow.** It runs on desktop only, fires when you re-spell a word Flow just pasted, skips common words, and announces learned words in a batch.
- **Its output is noisy.** An importer kept only 36 words from one user's Wispr data ([bispr-blow #6](https://github.com/khicken/bispr-blow/pull/6)).
- **Le Blab already has the core:** a list of terms with "sounds like" spellings, sent as Voxtral `context_bias` and applied as regex fixes. **It has no entry metadata, no correction observer and no UI for learned words.**
- **Reading edits back is reliable only in native AppKit apps.** Chrome, Slack, VS Code/Cursor and terminals all go through the paste path, where read-back is partial, unknown or impossible.
- **Recommendation, in order:**
  1. Explicit learning: "Fix last dictation", "Add selection", CSV import/export (S–M, no false positives).
  2. A ranked, capped bias list.
  3. An **opt-in** watcher that adds terms on its own but asks before creating rewrite rules (L).
- **Copy next from Flow:** Snippets, a paste-last-transcript shortcut, Undo AI edit, casing that matches the surrounding text, then per-app Styles.

## 1. How Wispr Flow's dictionary works

**Manual adds**
- **Add words on the Dictionary page** ("Add new" on desktop, "+" on mobile). Wispr suggests dictating a test sentence and adding a correction if the wrong spelling comes back ([Teach Flow your words](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)).
- **Bulk import is a desktop-only CSV with no header row.** One column means a word; two columns mean `misspelling,correction`. Limits are 3 MB and 1,000 entries per file, with a preview of skipped duplicates ([bulk import](https://docs.wisprflow.ai/articles/8955301725-how-do-i-bulk-import-for-dictionary-and-snippets)). **No export is documented.**
- **Starred words get priority.** The Mar 31, 2026 changelog says starred (then called "pinned") terms are prioritized in transcription; no help article repeats this ([What's new](https://wisprflow.ai/whats-new)).

**Automatic learning**
- **Trigger: you change the spelling of a word Flow just pasted, in the field it pasted into.** The setting is "Auto-add to Dictionary" under Settings → Personalization ([Data Controls](https://wisprflow.ai/data-controls)). The 2025 beta was opt-out; the current default isn't documented ([Smart Dictionary changelog](https://wisprflow.featurebase.app/changelog/with-smart-dictionary-beta-flow-now-learns-your-words)).
- **Mac and Windows only.** iOS and Android have the dictionary but don't auto-learn ([Teach Flow your words](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)).
- **Wispr publishes no app list, time window or threshold.** Apps that expose no accessibility text are blind spots: a plugin exists because Flow never sees edits in Sublime Text ([WisprLearn](https://github.com/dimitriusssBR/WisprLearn)).
- **Never learned:**
  - file names, paths, URLs and partial emails
  - code symbols, keys, hashes and IDs
  - numbers, dates, markdown and emoji
  - everyday words, very common first names (John, Sarah) and famous names
  - everyday acronyms (PDF, CEO)

  Apostrophe variants are de-duplicated since Mar 31, 2026.
- **Other automatic sources:** Flow also adds words from the app you're in and from meeting summaries. Every automatically added entry gets a sparkle badge ([dictionary list](https://docs.wisprflow.ai/articles/9639977157-view-shared-dictionary-words-and-snippets-in-the-admin-portal)).
- **Learned words are announced in a batch.** The wording, the word list and any Undo button are undocumented, and the notification category can be muted ([notifications](https://docs.wisprflow.ai/articles/2250194357-customize-notification-preferences-by-category)).
- **Undo means editing or deleting the entry.** Deleting asks for confirmation and is permanent, and **auto-learn never re-adds a deleted word**. Adding it by hand or re-importing it still works.
- **Wispr's stated goal is that a mistake you've corrected twice never comes back** ([Master Plan](https://wisprflow.ai/post/the-master-plan)). Separately, its in-house speech model Canto is trained on edits from users who opted in; that is not the desktop trigger ([Canto](https://wisprflow.ai/canto)).

**Replacements ("Correct a misspelling")**
- **Each entry holds one wrong → right rule.** Matching is whole-word and case-insensitive, output keeps your saved casing, and the longest phrase wins. Rules are literal, not language-aware, so mapping common words is discouraged.
- **Contractions are safe:** `n't` forms are never changed (a Don → Dawn rule leaves "don't" alone), but possessives are (John's → Bob's). A personal rule beats a shared one, and Android can't create rules.

**How entries are used**
- **Canto reads dictionary terms as runtime context and is trained against sound-alike decoys.** An early training run picked a wrong similar-sounding term about 5× as often as the baseline ("Barry" for "berry") ([Canto](https://wisprflow.ai/canto)).
- **Wispr warns that hundreds or thousands of terms lower accuracy** (odd name swaps, over-corrections) and recommends keeping only key terms ([transcription quality](https://wisprflow.ai/post/transcription-quality)).
- **An entry can stop Flow from capitalizing a word, but can't force a capital mid-sentence** ([capitalization](https://docs.wisprflow.ai/articles/4518230910-why-flow-capitalizes-words-mid-sentence-and-how-to-control-it)). Insights counts dictionary fixes ([Your usage](https://docs.wisprflow.ai/articles/8760230576-your-usage-tab-track-your-dictation-stats-in-wispr-flow)), and the Your Voice profile shows your most-corrected word ([Voice Profile](https://docs.wisprflow.ai/articles/7470830521-voice-profile-updates-when-the-update-your-voice-profile-notification-appears)).

**Team sharing and limits**
- **"Share with team" moves an entry into a team library** (org-wide since Sep 4, 2026). Admins can restrict sharing or turn the dictionary off ([sharing policy](https://docs.wisprflow.ai/articles/7133384604-restrict-org-wide-snippet-and-dictionary-sharing-snippet-sharing-policy)). Not relevant for a single user.
- **Limits:**
  - 60 characters per field (59 on iOS); CSV corrections can be up to 4,000.
  - **No maximum entry count is documented.**
  - Empty or punctuation-only entries are rejected, and duplicates are blocked.

## 2. What users report

**What works**
- **For one r/ClaudeAI poster, vocabulary learning was the deciding feature.** They compared Claude Code `/voice`, ElevenLabs and Flow ([Reddit mirror](https://reddit.sentinel-team.org/posts/1rsptwg/snapshots/2026-03-14T00%3A11%3A38.395735Z)).
- **Learning takes repetition.** A 90-day review logged 3,155 corrections and 446 dictionary entries. MCP and Claude Code were learned within a week; brand names and jargon took one to two weeks ([mrktcorrect](https://mrktcorrect.com/blog/wispr-flow-review)).

**What goes wrong**
- **Learned lists are noisy.** Replaying one user's Wispr words against 7,018 dictations kept 36 of them. Without that filter, 52 imports respelled real dictations ("Ronnie merged" → "Ronniel Markdown") ([bispr-blow #6](https://github.com/khicken/bispr-blow/pull/6)).
- **Learned terms still miss.** After 450 logged dictionary fixes, Flow still wrote "the Cloud" for a quickly spoken "Claude" ([technovice](https://www.technovice.net/post/wispr-flow-review)).
- **Edits that change meaning destroy trust.** Users report DON'T turned into DO, and "not" or "never" dropped ([HN](https://news.ycombinator.com/item?id=50042333), [Theo via Digg](https://digg.com/ai/ve5pkh0s)). That comes from cleanup, not the dictionary, but a bad learned rule fails the same way.
- **Learners in clone apps fail in both directions.**
  - EnviousWispr learned junk within ten minutes (random words → randomwords, Duke → King) because it treated a pause or app switch as "edit finished" ([#3101](https://github.com/saurabhav88/EnviousWispr/issues/3101)).
  - Its fix then blocked real corrections such as Whisper → Wispr ([#3949](https://github.com/saurabhav88/EnviousWispr/issues/3949)).
- **Coverage gaps are common.**
  - VoiceInk missed edits in Electron apps such as Claude Desktop ([#977](https://github.com/Beingpax/VoiceInk/issues/977)).
  - In one mode VoiceInk learned nothing in TextEdit or Notes ([#985](https://github.com/Beingpax/VoiceInk/issues/985)).
  - Willow had to tone down its auto-dictionary within two months ([changelog](https://willowvoice.featurebase.app/changelog)).

**Privacy**
- **Reading context is the flashpoint.** An r/privacy post alleged Flow sent screenshots of the active window ([mirror](https://reddit.sentinel-team.org/posts/1u0fpaq/snapshots/2026-06-09T22%3A23%3A55.474306Z)). Wispr's docs now say context is text only, with no screenshots ([Context Awareness](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)). Reviewers advise turning it off for NDA work ([tldv](https://tldv.io/blog/wisprflow/)).
- **The dictionary syncs as account settings whatever the privacy toggles say,** so one explainer advises keeping client names out of it ([KINTAL](https://kintal.co/thinking/what-wispr-flow-actually-does)).
- **A separate r/macapps backlash** covered login-item registration, idle CPU use, background traffic and the training policy. The CTO apologized after the user who raised it had been banned ([eesel](https://www.eesel.ai/blog/wispr-flow-review)).

**Requests**
- **Pairs of heard → correct spellings, not just a term list** ([FreeFlow #125](https://github.com/zachlatta/freeflow/issues/125)).
- **Auto-learn plus bulk import.** Users called a 50-word cap too small ([Vowen](https://vowen.featurebase.app/p/auto-learn-from-corrections-bulk-dictionary-import)).
- **Export as well as import.** One user retyped 100+ words from screenshots when switching machines ([Superwhisper board](https://superwhisper.userjot.com/board/p/allow-import-export-of-vocabulary)).

## 3. How other apps do it

- **VoiceInk (Swift, GPLv3, so reimplement rather than copy) watches the paste.**
  - It waits 120 ms after a paste and finds the pasted range.
  - It watches until focus leaves (AXObserver with a 250 ms grace period) or 60 s pass.
  - It then compares only the text between unique 16-character anchors, at most 5 words on each side.
  - Code: [`AutoLearn/`](https://github.com/Beingpax/VoiceInk/tree/main/VoiceInk/Features/Dictionary/AutoLearn), mainly `AutoLearnService.swift`, `AutoLearnTypes.swift`, `FinalSnapshotDiffEngine.swift` and `CorrectionDiffEngine.swift`; [docs](https://tryvoiceink.com/docs/auto-learn-dictionary).
- **VoiceInk's review UI shows one suggestion at a time in a non-activating panel** (`AutoLearnSuggestionController.swift`). No answer within 10 s counts as a rejection, and dismissed pairs never come back. **Its LLM reviewer was replaced by local rules** after rate limits and unparsable replies ([PR #1029](https://github.com/Beingpax/VoiceInk/pull/1029)).
- **VoiceInk also matches sounds toward saved terms** ([`PhoneticVocabularyMatcher.swift`](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Features/Dictionary/Workflows/PhoneticVocabularyMatcher.swift)).
  - It combines a Metaphone-style sound key with edit distance.
  - It accepts a match only if the cost is under 0.19, the runner-up is at least 0.04 worse, and the first letter is the same.
  - It skips words under 4 characters and tokens containing digits.
- **VoiceInk sends names it finds on screen to Mistral `context_bias` for each dictation,** using OCR plus NLTagger, and never saves them ([`RecordingVocabulary.swift`](https://github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Features/Dictionary/Workflows/RecordingVocabulary.swift)).
- **xflow learns vocabulary only, never rewrite rules.** It switched after a reviewer caught it creating a global `deploy → deployed` rule ([PR #47](https://github.com/itsmrad/xflow/pull/47), `crates/xflow-core/src/learn.rs`).
  - At least half the words must survive.
  - Only 1–3 word edits that look or sound alike count, at most 4 per dictation.
  - Removed words go on a `never_learn` list.
- **dyktando-x checks at the next dictation (within 30 min).** It learns only if at least 2/3 of the words are unchanged and the edit is at most 3 words shaped like a name (a capital mid-sentence, or letters plus digits like H264). It saves a plain term, and creates a rule only for a name split across several words ([PR #17](https://github.com/jash90/dyktando-x/pull/17)).
- **bispr-blow runs a replay test before keeping a word.** It applies each candidate to all past dictations and drops it if it would change or recase anything the user didn't say. Result: 0 of 3,000 sampled dictations newly altered, in about 11 s ([PR #6](https://github.com/khicken/bispr-blow/pull/6)).
- **EnviousWispr grades how sure it is that an edit is finished.**
  - Strong signals: sending, an emptied field, or the next dictation.
  - Weak signals: a focus change or a timeout. These need a much higher judge-model score (0.95 vs 0.68).
  - It shows a 4 s "Added · Undo" pill and blocks a correction after two rejections ([help](https://enviouswispr.com/help/self-learning-dictionary/)).
- **EnviousWispr measures on a labeled set.** After its fix it learned 59 of 71 cases it should learn and 0 of 22 it shouldn't ([#3949](https://github.com/saurabhav88/EnviousWispr/issues/3949)).
- **AI-Productivity-Flow stopped learning from raw-vs-polished differences** because those rules kept rewriting ordinary words. It now refuses the 2,000 most common English words as terms and never chains rules ([PR #19](https://github.com/uzerkayat2004-gif/AI-Productivity-Flow/pull/19)).
- **WisprLearn waits about 12 s of idle time,** rejects rewrites, numbers, case-only and very short edits, and logs what it learned or ignored and why. It also has a dry-run mode and "undo last learned word" ([repo](https://github.com/dimitriusssBR/WisprLearn)).
- **Dragon learns from your own documents and sent mail.** It shows unknown words in Included and Excluded columns before adding anything ([Vocabulary Training](https://nuance.com/products/help/dragon/dragon-for-mac6/enx/Content/Accuracy/VocabularyTraining.html)). Monologue imports dictionaries from Wispr, Aqua, Superwhisper and Willow ([docs](https://www.monologue.to/docs/personalize/dictionary)).
- **Everyone keeps the list short:**
  - Superwhisper lists an oversized vocabulary as a cause of hallucinations ([docs](https://superwhisper.com/docs/common-issues/hallucinations)).
  - OpenWhispr says 50 words you actually miss beat 500 ([docs](https://docs.openwhispr.com/help/customise/custom-dictionary)).
  - Spokenly applies only the first 50 terms live ([docs](https://spokenly.app/docs/custom-dictionary)).
  - Apple allows at most 100 `contextualStrings` ([docs](https://developer.apple.com/tutorials/data/documentation/speech/sfspeechrecognitionrequest/contextualstrings.md)).

## 4. What Le Blab can do today
The repo is `/Users/hendrikkrack/Desktop/demos/wispr-clone`, and references are `File.swift:line` under `Sources/`. `DictationController.swift` line numbers are from the working tree, which another session is editing.

**Vocabulary pipeline**
- **Each entry is `{id, term, aliases}` with no source, count or date** (`VocabularyCorrector.swift:4-13`). The defaults are CodeRabbit, DevRel, GitHub, Mistral and Voxtral, plus 5 aliases (`:15-21`).
- **The list is one JSON blob in UserDefaults under `leblab.vocabulary`, saved again on every change** (`SettingsStore.swift:51`). This Mac has no saved key, so the defaults are in use and nothing needs migrating yet.
- **Only terms are sent for biasing, de-duplicated and with no cap** (`VocabularyCorrector.swift:63-67`). Aliases never leave the Mac.
  - Realtime: sent in `session.update` before any audio (`VoxtralRealtimeProtocol.swift:20-21`, `VoxtralRealtimeClient.swift:219-229`).
  - Accuracy mode and the batch fallback: sent as repeated form fields (`VoxtralBatchClient.swift:27-30`).
- **Every alias, and every term of 3 or more characters, becomes a case-insensitive rewrite rule** (`VocabularyCorrector.swift:39-40`). Rules apply longest first and skip URLs, emails and paths (`:92-99`). **So adding any term also forces its casing everywhere.**
- **`apply()` doesn't report which rule fired** (`:52-60`), and it runs several times per dictation, so usage counts must be taken once, after insertion.
- **Smart mode fixes the raw Voxtral text before the LLM sees it** (`TranscriptFormatter.swift:83`) and again afterwards (`:102`). The vocabulary sits in the system prompt ahead of the few-shot examples (`:232`), so any change to it invalidates the cached prompt prefix (`prompt_cache_key`, `:298`).
- **The corrector is rebuilt for every dictation** (`AppCoordinator.swift:255-265`). `docs/AUDIT-2026-11-02.md:126` already flags this.

**Read-back by app type** (`:line` means `TextInsertionService.swift`)

| App type | Can read edits back? | Why |
|---|---|---|
| Native AppKit (TextEdit, Notes) | **Yes** | Range reads exist (`:515-522`), and the provisional path already re-reads its own text (`:204-209`) |
| Safari/WebKit, Mail compose | Partly | Routed to paste (`:290`, `:296`), and `paste()` keeps no target (`:314-332`); plain inputs are probably readable but untested. Settings text claims Mail is polished in place (`SettingsView.swift:216`), which contradicts this routing |
| Chrome/Chromium | Partly | Paste-first (`:286`, `:295`). The end-to-end self-test reads a plain textarea's value (`SelfTest.swift:119-124`); range reads, Gmail and Docs are unproven |
| Electron (Slack, Discord, Notion, Obsidian, Linear) | Unknown | Paste-first (`:297-310`). `AXManualAccessibility` is never set, so the web accessibility tree may not exist |
| VS Code / Cursor | Partly | The Monaco editor exposes only a window of lines, and only with accessibility support on ([vscode#41423](https://github.com/microsoft/vscode/issues/41423)) |
| Terminals | Treat as no | Paste-first (`:299`); the shell's line editor owns the text |
| JetBrains | Unknown | Paste-first (`:286`) |
| Secure fields | No, by design | Guarded at `:128-130` and `:140-142`; check again at read time |
| Typing method, `.notInserted` | No | No target is kept (`:147-151`) |

**Where corrections could be observed**
- **Only the optimistic path keeps a handle today.** That path covers smart mode with an LLM-bound transcript in a native app, and the handle is dropped after `replaceProvisional`.
  - `insert()` would need to return `{element, range, text, bundleID}` for every accessibility and paste insert (`TextInsertionService.swift:43-51`, `:118-170`).
  - `FakeInserter` would need the same change.
- **`.keptProvisional` is not an edit signal.** It also fires when focus or the caret moves and when an accessibility write fails (`TextInsertionService.swift:215-231`). Use it only to start watching.
- **The best checkpoint is the next hotkey press** (`DictationController.start()`, `:140`). Read after audio has started and off the main thread, since each accessibility call can block for 0.25 s (`TextInsertionService.swift:419`, `:424`).
- **No other end-of-edit signals exist yet.** There is no app-switch observer and no AXObserver; the only observer is Le Blab's own activation (`AppCoordinator.swift:135-137`).
- **Hook it in with one `didInsert` call per insertion exit in `complete()`** (`DictationController.swift:369`).
  - There are 5 exits; one (unconfirmed provisional) records no history.
  - Skip `.notInserted`.
- **Learn aliases from the raw Voxtral text, not the polished output,** because the corrector sees the raw text next time (`TranscriptFormatter.swift:83`). If the raw text was right and only the LLM changed it, the problem is formatting, not vocabulary.
- **Paths that need no accessibility read-back:**
  - Edit `lastTranscript` inside Le Blab (`DictationController.swift:56`, `AppCoordinator.swift:295-304`).
  - Read the selection once from an explicit menu action (`BubbleController.swift:154-167`, `MenuBarContent.swift:41-45`).
  - Suggest terms from opt-in history, which keeps `rawText` when the LLM ran (`HistoryStore.swift:3-15`).
- **A new word aligner is needed.** `WordErrorRate` only counts edits and lowercases everything (`WordErrorRate.swift:24-55`); learning needs case-preserving alignment to catch github → GitHub and code rabbit → CodeRabbit.

**Storage**
- **There is a migration trap (reproduced).**
  - Adding a non-optional field with a default makes old JSON fail to decode.
  - `try? … ?? defaults` (`SettingsStore.swift:79`, `:123-126`) then silently reverts the list to the defaults.
  - The next edit overwrites the saved blob for good.
  - Fix: use Optional fields or `decodeIfPresent` (as in `BenchHarness.swift:73-80`), and a v2 key with v1 kept for rollback.
- **Default entries get a new UUID on every launch until first saved** (`VocabularyCorrector.swift:5`), so key stats and the never-learn list by the lowercased term.
- **Keep counters out of the `@Published` array.** Each change triggers a UserDefaults write, `applySettings` and a re-render (`AppCoordinator.swift:165-168`).
  - Use a separate file with 0600 permissions, excluded from backups, like history (`HistoryStore.swift:75-91`).
  - Add it to `deleteAllLocalData` (`AppCoordinator.swift:319-324`), because the `leblab.` sweep covers only UserDefaults (`SettingsStore.swift:107`).
- **Case duplicates already conflict.** With both "GitHub" and "Github", biasing sends GitHub but the later rule rewrites every occurrence to Github. `addTerm` never de-duplicates (`SettingsView.swift:171-178`).
- **Test hygiene:** `StorageTests` never delete their UserDefaults suites, and `~/Library/Preferences` now holds 3,400+ `leblab-test-*.plist` files.

**UI surfaces**
- **Today the vocabulary is a flat list with "Term" and "Sounds like" fields** under Settings → Transcription, with no search, source, counts or undo (`SettingsView.swift:136-178`).
- **A Dictionary tab is one new `SettingsTab` case** (`WindowManager.swift:5-20`) that can reuse History's searchable list (`SettingsView.swift:375-420`).
- **A clickable "Learned X · Undo" notice needs a new overlay state.** The overlay ignores clicks except in `.notInserted` and `.failed` (`OverlayController.swift:84-85`). Learning resolves at the next press, when the overlay is busy, so show the notice after it closes.
- **The bubble and the menu bar can hold the new commands:** "Add selection to dictionary", "Fix last dictation…", "Undo learned X" and "Dictionary…" (`BubbleController.swift:46-57`, `MenuBarContent.swift:41-45`).

**Privacy**
- **Reading edits back would break three promises Le Blab makes today:**
  - Onboarding says Le Blab never reads other apps' content beyond the character next to the cursor (`OnboardingView.swift:65`).
  - The "never sent" list says the same (`PrivacyManager.swift:53`, `docs/PRIVACY.md:17-19`).
  - Accessibility read-back is documented as test-only (`TextInsertionService.swift:539-540`).
- **The code is already a little looser than that text.** `characterCount` reads a field's whole value when `AXNumberOfCharacters` is missing (`TextInsertionService.swift:437-440`), though it only counts it and never stores or sends it.
- **Learned names would reach Mistral twice per dictation:** in `context_bias` and in the formatter prompt. `docs/PRIVACY.md:13` lists only `context_bias`, and Mistral keeps API inputs for 30 days without Zero Data Retention (`PrivacyManager.swift:66-71`).
- **Rules for any read-back:**
  - Read only the inserted range plus a small margin, only in the element Le Blab wrote to, for a limited time.
  - Check secure input again at read time.
  - Store only terms and aliases, and log only counts (`Log.swift:3`).
- **Never reuse the hotkey event tap to capture typed characters** (`HotkeyManager.swift:118-121`). That would be keylogging and would contradict "Input Monitoring not required".

**Voxtral `context_bias` limits**
- **Voxtral 3 has no fixed entry cap, but terms share a 65,536-token window with the audio.** A file request that overflows fails with HTTP 400 `invalid_request_prompt_too_long`; Mistral doesn't trim the list ([migration](https://docs.mistral.ai/studio/audio/migrate-from-voxtral-2), [limits](https://docs.mistral.ai/studio/audio/specs-and-limits/limits), [bias guide](https://docs.mistral.ai/studio/audio/speech-to-text/bias-context-and-vocabulary)).
- **Realtime sessions lock the list once audio starts,** and changing it later returns an error. Learned terms therefore apply from the next dictation ([realtime](https://docs.mistral.ai/studio/audio/speech-to-text/transcribe-in-realtime)).
- **Phrases with spaces are allowed; list each term that must be right as its own phrase.** Transcription has no "sounds like" hints (those exist only for text-to-speech), so keeping Le Blab's aliases local is the right design ([custom vocabulary](https://docs.mistral.ai/studio/audio/concepts/custom-vocabulary)).
- **Biasing favors the listed terms but doesn't force them.** Mistral doesn't document over-biasing, but every competitor warns about it.
- **The older Voxtral 2 doc recommends at most 100 terms and says biasing is tuned for English;** other languages are experimental and **German is unverified** ([offline doc](https://docs.mistral.ai/capabilities/audio/speech_to_text/offline_transcription)).
- **Tokens aren't the real limit.** A 15-minute dictation (`DictationController.swift:77`) is about 11k audio tokens at Voxtral 1's 12.5 tokens/s ([paper](https://arxiv.org/html/2507.13264v1)); Voxtral 3's rate is unconfirmed. The latency cost is undocumented, so measure 5 vs 100+ terms with the bench harness.
- **Errors from an oversized list aren't handled well.**
  - Realtime overflow behavior is undocumented.
  - An error message containing "too many" is retried as a rate limit (`VoxtralRealtimeProtocol.swift:99`).
  - The batch fallback sends the same list and would also get a 400 (`MistralAPI.swift:102`).
- **The server confirms the applied settings, but Le Blab ignores the reply.** `session.updated` echoes the settings (`VoxtralRealtimeClient.swift:231`).

## 5. Learning dictionary: options
Effort: S ≈ 1 day, M ≈ 2–4 days, L ≈ 1–2 weeks.

**Groundwork for any option (S–M):** a v2 dictionary with:
- Optional fields: `source` (manual, learned or imported), `createdAt`, `lastUsedAt`, `hitCount`, `starred`.
- A `rewrite` flag that separates bias-only terms from terms that also fix text.
- A never-learn list, merging of case-only duplicates, and a separate stats file.
- A cached corrector, and migration tests.

**A. Explicit learning: import, quick-add, fix last dictation**
- **How it works:** "Fix last dictation…" (in the bubble and menu bar) opens the last transcript for editing.
  - Le Blab aligns your edit with the inserted text.
  - It finds the replaced words in the raw transcript to get what Voxtral heard.
  - It proposes a term plus alias for one-click confirmation.
- **Also:** "Add selection to dictionary" (one selection read when you click it), and CSV/JSON import and export in Wispr's format.
- **Precision:** **the highest of the three, because every entry is a deliberate action.** Still refuse aliases that are common English or German words, or shorter than 3 characters.
- **Privacy:** no background reading, so today's promises hold with a one-line wording change for the selection read.
- **Coverage and effort:** **works in every app, including Slack, Cursor and terminals; S–M.** It never learns on its own.

**B. Automatic learning from corrections made in place (like Wispr)**
- **How it works:**
  - After each insert into an app Le Blab can read, keep a handle.
  - On the next hotkey press (a strong signal), or on an app switch, focus change or 60 s timeout (weak signals), re-read only the inserted range between unique 16-character anchors.
  - Compare it word by word with what Le Blab inserted.
- **Filter (local and deterministic):**
  - Accept only changes of 1–3 words where at least 2/3 of the words are unchanged.
  - The new word must look like a name (capital mid-sentence, CamelCase, letters plus digits) or sound or look like the old one.
  - Reject Wispr's never-learn categories plus common English and German words.
  - Learn at most 4 words per dictation, and require weak signals to repeat in a second dictation.
- **What gets saved:**
  - **Learned terms are bias-only**, unlike today's rule that every term of 3+ characters also rewrites text.
  - Create heard → term rewrite rules only after your approval or a second identical correction.
  - Put anything you undo on the never-learn list.
  - Replay each candidate over local history when history is on.
- **UI:** a "Learned Granola · Undo" line in the bubble after the overlay closes, plus source badges and a Learned filter in the Dictionary tab.
- **Precision risks:**
  - Rewording looks like a misrecognition.
  - Half-typed edits get learned (EnviousWispr's failure).
  - Case-only fixes recase common words such as Linear or Cursor everywhere.
  - Chat fields empty themselves on send, so there is nothing to read back.
  - Repeated text breaks the anchors.
- **Privacy:** it reads other apps' text locally and sends learned names to Mistral with every dictation, so **it must be opt-in and the three promises must be rewritten.**
- **Coverage and effort:** **native apps, maybe plain web fields; L.**
  - Chrome and Electron would need `AXManualAccessibility` turned on and back off, as VoiceInk does.
  - The work covers the inserter API and test fakes, observers, the aligner, filters, UI, privacy text and a labeled test set.

**C. Learning from words you use outside dictation**
- **The catch:** **your transcripts only contain words Voxtral already produced,** so mining dictation history mostly finds words it already got right.
- **How it works:** opt-in scans, with Dragon-style Included and Excluded columns to review before anything is added. Sources:
  - Proper nouns and CamelCase tokens (via NLTagger) from a repo or docs folder you choose.
  - Contacts names.
  - Wispr Flow's local `flow.sqlite`, read-only, as bispr-blow does (unofficial; Wispr has no export).
- **Possible later addition:** names visible on screen at hotkey-down, used for that dictation and never saved (as Wispr Context Awareness and VoiceInk do). They must be ready before the first audio chunk.
- **Precision:** medium. Willow's add-by-usage approach backfired, so **always review before adding.**
- **Privacy and effort:** scans stay local, Contacts needs a permission, and on-screen names need a new disclosure; **M**, or L with on-screen names.

**Recommendation**
1. **Now: the groundwork plus A (S–M).** No false positives, works in all your apps, and no privacy promise changes.
2. **Next: a ranked, capped bias list (S–M).**
   - Manual and starred terms go first, then learned terms by recent use.
   - Cap the list at about 100 and keep the order stable.
   - Move the vocabulary out of the cached prompt prefix.
   - Retry without biasing after a 400.
   - In the bench harness, compare 5 vs 100 terms for word error rate (WER) and latency.
3. **Then: B as an opt-in (L).** Start with native apps, add learned terms as bias-only, ask before creating rewrite rules, and ship only when a labeled test set shows no false learns (EnviousWispr reached 0 of 22).
4. **Optional: C as a one-time "seed my dictionary" scan (M),** not continuous mining.
- **Why this order:**
  - Wispr's own learner is narrow and noisy, and clone apps show both junk learning and missed learning.
  - **Most of Le Blab's target apps use the paste path, where B can't see edits yet.**
  - A gets most of the value at a fraction of the risk, and B reuses A's storage, aligner and UI.

## 6. Other Wispr Flow features worth copying
Ranked by value for a single-user Mac app on Mistral. Effort uses the scale from section 5. † marks a partly verified feature.

| # | Feature | What it does in Flow | Le Blab today | Value | Effort | Note |
|---|---|---|---|---|---|---|
| 1 | Snippets | A spoken trigger expands to saved text (links, addresses, prompts), even mid-sentence; the longest trigger wins ([docs](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets)) | No | High | S | Reuse the `VocabularyCorrector` matcher; plain static text, as in Flow |
| 2 | Paste/copy last transcript | ⌃⌘V pastes the latest result again; ⌃⌘C copies it ([docs](https://docs.wisprflow.ai/articles/4841123325-longer-dictation-sessions-now-up-to-20-minutes)) | Partial | High | S | Copy is in the menu bar and bubble. `pasteLastTranscript()` exists but nothing calls it (`AppCoordinator.swift:301`) |
| 3 | Undo AI edit | Restores the raw transcript; ⌘Z right after the paste reverts the cleanup ([docs](https://docs.wisprflow.ai/articles/4283510616-auto-cleanup-control-how-much-flow-edits-your-dictation-beta)) | Partial | High | S | Raw text is saved only in opt-in history and is never shown (`HistoryStore.swift:7`) |
| 4 | Casing that matches surrounding text | Matches the case of the text around the cursor and drops the final period when the sentence continues ([docs](https://docs.wisprflow.ai/articles/4518230910-why-flow-capitalizes-words-mid-sentence-and-how-to-control-it)) | Partial | High | S–M | Le Blab already reads one character on each side, but only for spacing (`SpacingRules.swift:9`) |
| 5 | Styles per app category | Formal, Casual, Very casual or Excited for Personal, Work, Email and Other apps; changes casing and punctuation only ([docs](https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles)) | No | Med–High | M | Map the bundle ID to a category locally and send only the style rule. Flow's Styles are English-only |
| 6 | Command Mode | Hold a second shortcut and speak an instruction to rewrite the selection or the field ([docs](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode)) | No | Med–High | M | Sends other apps' text to Mistral, so it needs opt-in and new privacy text (Flow ships it off by default too) |
| 7 | Hands-free lock | Double-tap the push-to-talk key or click the Flow Bar to keep recording ([docs](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)) | Partial | Med | S | Toggle mode and clicking the bubble exist; there is no double-tap in hold mode |
| 8 | Cleanup levels | None, Light (default) or Medium rewriting ([docs](https://docs.wisprflow.ai/articles/4283510616-auto-cleanup-control-how-much-flow-edits-your-dictation-beta)) | Partial | Med | S | Le Blab has Raw and Smart; Medium would be one more prompt variant |
| 9 | "Press enter" voice command | Saying "press enter" at the very end presses Enter after a successful paste; experimental, off by default ([docs](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)) | No (by design) | Med | S | Conflicts with the README's rule that Le Blab never presses Return |
| 10 | Mic fallback and no-sound warning | Ranks mics and falls back mid-dictation; warns right away when the mic hears nothing (Oct 9, 2026) ([What's new](https://wisprflow.ai/whats-new)) | Partial | Med | S–M | A device picker exists (`SettingsView.swift:54`); add the silence warning first |
| 11 | Long dictations into Claude Code or Codex | Long dictations stay visible and editable instead of collapsing to "[Pasted N lines]" ([What's new](https://wisprflow.ai/whats-new)) | No (untested) | Med | S–M | Wispr doesn't say how. First check whether Claude Code collapses Le Blab's pastes |
| 12 | Transforms | A shortcut rewrites selected text: Polish, Prompt Engineer, up to 8 custom prompts, optionally applied after each dictation ([docs](https://docs.wisprflow.ai/articles/8068950331-how-to-use-transforms-beta)) | No | Med | M | Prompt Engineer suits Claude Code prompts; same privacy caveat as #6 |
| 13 | Context Awareness | Reads the app, nearby text and names on screen to spell names; text only ([docs](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)) | No | Med | M–L | Must be ready before the first audio chunk to reach `context_bias`; needs a new disclosure |
| 14 | IDE variable names and file tagging | Reads the identifiers visible in Cursor, Windsurf or VS Code; spoken file names become @-tags in Cursor/Windsurf chat ([docs](https://docs.wisprflow.ai/articles/6434410694-use-flow-with-cursor-vs-code-and-other-ides)) | No | Med | L | Needs the IDE's screen-reader mode. Smart mode already writes "main dot py" as `main.py` |
| 15 | Mute media while dictating | Mutes the default output (or pauses players) and restores it afterwards; off by default on Mac ([docs](https://docs.wisprflow.ai/articles/7231650589-auto-mute-music-while-dictating-on-macos-how-audio-detection-works)) | No | Low–Med | S | — |
| 16 | Insights | Words, words per minute, fixes Flow made (including dictionary fixes), most-corrected word ([docs](https://docs.wisprflow.ai/articles/8760230576-your-usage-tab-track-your-dictation-stats-in-wispr-flow)) | Partial | Low–Med | S | Diagnostics shows latency only; usage counts come with the v2 dictionary |
| 17 | Long-session warning | 20-minute cap with a warning at 19 minutes and a "Recover text" button ([docs](https://docs.wisprflow.ai/articles/4841123325-longer-dictation-sessions-now-up-to-20-minutes)) | Partial | Low | S | Le Blab caps at 15 minutes (`DictationController.swift:77`) and never drops transcripts, but gives no warning |
| 18 | Flow Bar extras † | Dock to a screen edge, "Hide for 1 hour", language picker ([docs](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop)) | Partial | Low | S | The always-on bubble and its right-click menu cover the basics |

- **Already on par:**
  - Push-to-talk with Esc to cancel.
  - Smart formatting with spoken self-corrections, lists and spoken layout commands.
  - Language detection per dictation, with a language picker.
  - A sounds toggle and opt-in local history.
- **Skip for a single-user app:** team dictionary, admin portal, cross-device sync, Notetaker, MCP server, Scratchpad.
- † Partly verified: Wispr's languages article says the Flow Bar has no language picker, while the Flow Bar article and the Mar 31 changelog say it does.

## 7. Open questions for Hendrik
1. **Read-back:** may Le Blab read back the text it just inserted, opt-in, locally and for a limited time, in order to learn? If not, build the groundwork plus A (and C), and keep today's privacy text.
2. **Silent or confirmed:** should learned terms be added silently with an Undo line, as in Wispr, or wait for one-click approval? And may Le Blab ever create rewrite rules without asking?
3. **Your apps:** where do you correct dictation most: Notes/Mail, Chrome/Gmail, Slack, Cursor/VS Code, or Claude Code in a terminal? This decides whether B is worth L effort, and which read-back path to prove first.
4. **Names sent to Mistral:** is it fine for learned client and colleague names to go to Mistral with every dictation? Or do you want a per-entry "local only" option that fixes spelling on the Mac and never sends the term?
5. **German:** should the filters, common-word lists and tests cover German as well as English?
6. **History:** may learning use local history (off by default) for replay tests and suggestions, or must it work with history off?
7. **Seeding:** do you have a Wispr Flow or other dictionary to import, and should a repo or Contacts scan be in the first version?
8. **After the dictionary:** quick wins first (Snippets, paste-last shortcut, Undo AI edit, casing), or Command Mode and Transforms, which send selected text to Mistral?