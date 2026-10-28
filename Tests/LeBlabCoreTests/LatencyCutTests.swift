import Foundation
import Testing
@testable import LeBlabCore

@Suite("Formatting router (skip the model for clean transcripts)")
struct FormattingRouterTests {
    @Test(arguments: [
        "Please send the quarterly report to Maria by Friday afternoon.",
        "Sounds good, see you tomorrow.",
        "Hallo zusammen, ich wollte nur kurz fragen, ob ihr morgen Zeit habt.",
        "Can we do the call at 3 PM?",
        "Let's meet in the main office.",
    ])
    func cleanTranscriptsStayLocal(text: String) {
        #expect(!FormattingRouter.decide(text).needsLanguageModel, "\(text)")
    }

    @Test(arguments: [
        ("Hey David, I just wanted to check if we can move the meeting to Friday at 3. Actually make that 4.", "self-correction"),
        ("Send it to Maria by Thursday. Sorry, I mean Friday.", "self-correction"),
        ("Ich wollte das Meeting auf Freitag verschieben. Nein, auf Donnerstag.", "self-correction"),
        ("The plan is first review the PR, second update the README.", "enumeration"),
        ("Check the config at docs dot mistral dot ai slash api", "spoken url/file"),
        ("Dear team new paragraph the release is ready", "spoken layout"),
        ("It costs about twenty five percent more", "number with unit"),
        ("We need to to fix the build.", "stutter"),
        ("Send it to Maria, uh, Marta.", "hesitation"),
        ("Can we do Tuesday? No, Wednesday.", "mid-sentence no"),
        ("Let's meet at four.", "spelled-out time"),
        ("It takes five minutes.", "number with unit"),
        ("Wir treffen uns um halb drei.", "german clock time"),
        ("Schick es an Anna, besser gesagt an Marta.", "self-correction"),
        ("so we should probably move the meeting because the team needs a little more time to prepare everything", "no punctuation"),
    ])
    func cuesNeedTheModel(text: String, reason: String) {
        #expect(FormattingRouter.decide(text) == .languageModel(reason: reason), "\(text)")
    }

    @Test func longDictationNeedsParagraphs() {
        let long = Array(repeating: "word", count: FormattingRouter.maxLocalWords + 1).joined(separator: " ") + "."
        #expect(FormattingRouter.decide(long) == .languageModel(reason: "long dictation"))
    }

    @Test func noCueInsideOtherWords() {
        // "dot" in "dotted", "first" in "firstname", "sorry" absent: stays local.
        #expect(!FormattingRouter.decide("The dotted line marks the firstname field.").needsLanguageModel)
    }

    @Test func smartFormatterSkipsNetworkForCleanText() async {
        let smart = SmartFormatter(client: MistralChatClient(region: { .global }, apiKey: { nil }), model: "x", vocabulary: VocabularyEntry.defaults)
        let result = await smart.format("Please ask code rabbit to review the PR before Friday.", language: "en")
        #expect(result.text == "Please ask CodeRabbit to review the PR before Friday.")
        #expect(!result.usedLanguageModel)
        #expect(result.fallbackReason == "clean transcript")
        #expect(smart.provisionalText(for: "Please ask code rabbit to review the PR before Friday.", language: "en") == nil, "instant, nothing to show early")
    }

    @Test func provisionalTextIsTheLocallyCleanedTranscript() {
        let smart = SmartFormatter(client: MistralChatClient(region: { .global }, apiKey: { nil }), model: "x", vocabulary: VocabularyEntry.defaults)
        #expect(smart.provisionalText(for: "Hey David, um, move it to 3. Actually make that 4.", language: nil) == "Hey David, move it to 3. Actually make that 4.")
    }

    @Test func routingCanBeTurnedOff() async {
        let smart = SmartFormatter(client: MistralChatClient(region: { .global }, apiKey: { nil }), model: "x", vocabulary: [],
                                   routeCleanTranscriptsLocally: false)
        let result = await smart.format("Please send the quarterly report to Maria by Friday afternoon.", language: "en")
        #expect(result.fallbackReason == "language model unavailable", "went to the (unavailable) model")
    }
}

@Suite("Optimistic insert and adaptive tail") @MainActor
struct OptimisticInsertTests {
    func rig(provisional: String?, final: String, delay: TimeInterval = 0.15, native: Bool) -> DictationControllerTests.Rig {
        let rig = DictationControllerTests.Rig()
        rig.env.optimisticInsertEnabled = true
        rig.env.formatter = FakeFormatter(provisional: provisional, final: final, delay: delay)
        rig.inserter.supportsProvisional = native
        return rig
    }

    @Test func nativeAppGetsTextImmediatelyThenPolishedInPlace() async {
        let rig = rig(provisional: "Move it to 3. Actually make that 4.", final: "Move it to 4 PM.", native: true)
        rig.streaming.onCreate = { $0.autoDone = "move it to 3, actually make that 4" }
        rig.controller.handle(.pressed); rig.audio.speak(); rig.controller.handle(.released)
        #expect(await waitUntil { rig.env.metrics.count == 1 })
        #expect(rig.inserter.provisional == ["Move it to 3. Actually make that 4."])
        #expect(rig.inserter.document == ["Move it to 4 PM."], "replaced in place, not appended")
        #expect(rig.inserter.inserted.isEmpty, "no second insertion")
        let m = rig.env.metrics[0]
        #expect((m.releaseToFirstText ?? 9) < (m.releaseToInsert ?? 0), "first text arrives before the polished text")
        #expect(m.formatting.contains("optimistic"))
        #expect(rig.controller.lastTranscript == "Move it to 4 PM.")
    }

    @Test func editedProvisionalTextIsLeftAlone() async {
        let rig = rig(provisional: "Raw text.", final: "Polished text.", native: true)
        rig.inserter.replaceSucceeds = false
        rig.streaming.onCreate = { $0.autoDone = "raw text" }
        rig.controller.handle(.pressed); rig.audio.speak(); rig.controller.handle(.released)
        #expect(await waitUntil { rig.env.metrics.count == 1 })
        #expect(rig.inserter.document == ["Raw text."], "user's edits win")
        #expect(rig.controller.lastTranscript == "Polished text.", "polished version still copyable")
        #expect(rig.env.metrics[0].formatting.contains("kept provisional"))
    }

    @Test func pasteAppsWaitForTheFormattedText() async {
        let rig = rig(provisional: "Raw text.", final: "Polished text.", native: false)
        rig.streaming.onCreate = { $0.autoDone = "raw text" }
        rig.controller.handle(.pressed); rig.audio.speak(); rig.controller.handle(.released)
        #expect(await waitUntil { rig.inserter.inserted == ["Polished text."] })
        #expect(rig.inserter.provisional.isEmpty)
    }

    @Test func speedFirstPastesTheCleanedTextWithoutWaitingForTheModel() async {
        let rig = rig(provisional: "Raw text.", final: "Polished text.", delay: 2.0, native: false)
        rig.env.speedFirstInPasteApps = true
        rig.streaming.onCreate = { $0.autoDone = "raw text" }
        let start = Date()
        rig.controller.handle(.pressed); rig.audio.speak(); rig.controller.handle(.released)
        #expect(await waitUntil { rig.inserter.inserted == ["Raw text."] })
        #expect(Date().timeIntervalSince(start) < 1.0, "doesn't wait for the 2 s model")
        #expect(rig.env.metrics.first?.formatting == "local (speed first)")
    }

    @Test func cleanTranscriptsSkipTheProvisionalStep() async {
        let rig = rig(provisional: nil, final: "Already clean.", delay: 0, native: true)
        rig.streaming.onCreate = { $0.autoDone = "Already clean." }
        rig.controller.handle(.pressed); rig.audio.speak(); rig.controller.handle(.released)
        #expect(await waitUntil { rig.inserter.inserted == ["Already clean."] })
        #expect(rig.inserter.provisional.isEmpty)
    }

    @Test func rapidDictationsStayInOrderWithOptimisticInsert() async {
        let rig = rig(provisional: "first raw", final: "first polished", delay: 0.3, native: true)
        rig.streaming.onCreate = { $0.autoDone = "first" }
        rig.controller.handle(.pressed); rig.audio.speak(); rig.controller.handle(.released)
        await settle(0.05)
        rig.env.formatter = FakeFormatter(provisional: nil, final: "second", delay: 0)
        rig.streaming.onCreate = { $0.autoDone = "second" }
        rig.controller.handle(.pressed); rig.audio.speak(); rig.controller.handle(.released)
        #expect(await waitUntil { rig.env.metrics.count == 2 })
        #expect(rig.inserter.document == ["first polished", "second"], "second waits until the first is polished")
    }

    @Test func tailIsSkippedWhenSpeechAlreadyEnded() async {
        let rig = DictationControllerTests.Rig()
        rig.controller.releaseTail = 0.6
        rig.controller.inFlightBufferWait = 0.05
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.audio.silence(7)   // 350 ms of quiet
        #expect(rig.controller.speechEndedBeforeRelease)
        rig.controller.handle(.released)
        #expect(await waitUntil(timeout: 0.3) { !rig.audio.running }, "stopped without the 600 ms tail")
    }

    @Test func shortPauseKeepsTheTail() async {
        let rig = DictationControllerTests.Rig()
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.audio.silence(3)   // 150 ms: a pause between words, not the end
        #expect(!rig.controller.speechEndedBeforeRelease)
    }

    @Test func lastWordInTheInFlightBufferKeepsTheTail() async {
        let rig = DictationControllerTests.Rig()
        rig.controller.releaseTail = 0.4
        rig.controller.inFlightBufferWait = 0.2
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.audio.silence(7)
        rig.controller.handle(.released)
        await settle(0.02)
        rig.audio.speak()      // "…Thanks" right at release, delivered after the key went up
        await settle(0.15)
        #expect(rig.audio.running, "tail kept for the late word")
        #expect(await waitUntil { !rig.audio.running })
    }

    @Test func tailIsKeptWhileStillTalking() async {
        let rig = DictationControllerTests.Rig()
        rig.controller.releaseTail = 0.4
        rig.controller.handle(.pressed)
        rig.audio.silence(7)
        rig.audio.speak()
        #expect(!rig.controller.speechEndedBeforeRelease)
        rig.controller.handle(.released)
        await settle(0.15)
        #expect(rig.audio.running, "still capturing the last syllable")
        #expect(await waitUntil { !rig.audio.running })
    }

    @Test func notReplaceableFieldFinishesImmediately() async {
        let rig = rig(provisional: "Raw text.", final: "Polished text.", delay: 2.0, native: true)
        rig.inserter.provisionalReplaceable = false
        rig.streaming.onCreate = { $0.autoDone = "raw text" }
        let start = Date()
        rig.controller.handle(.pressed); rig.audio.speak(); rig.controller.handle(.released)
        #expect(await waitUntil { rig.env.metrics.count == 1 })
        #expect(Date().timeIntervalSince(start) < 1.5, "does not wait for the 2 s formatter")
        #expect(rig.env.metrics[0].formatting.contains("field not replaceable"))
        #expect(rig.inserter.document == ["Raw text."])
    }

    @Test func formattingAlreadyDoneSkipsTheProvisionalStep() async {
        let rig = rig(provisional: "Raw text.", final: "Polished text.", delay: 0, native: true)
        rig.streaming.onCreate = { $0.autoDone = "raw text" }
        rig.controller.handle(.pressed); rig.audio.speak(); rig.controller.handle(.released)
        #expect(await waitUntil { rig.env.metrics.count == 1 })
        // Either path is fine, but the document must hold exactly the polished text once.
        #expect(rig.inserter.document == ["Polished text."])
    }
}

@Suite("Speculative formatting") @MainActor
struct SpeculativeFormattingTests {
    /// Counts calls; answers after `delay`.
    final class CountingFormatter: TranscriptFormatting, @unchecked Sendable {
        var calls: [String] = []
        let delay: TimeInterval
        init(delay: TimeInterval) { self.delay = delay }
        func provisionalText(for transcript: String, language: String?) -> String? { transcript }   // always model-bound
        func format(_ transcript: String, language: String?) async -> FormattedText {
            calls.append(transcript)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            return FormattedText(text: "Polished: " + transcript, usedLanguageModel: true, fallbackReason: nil)
        }
    }

    @Test func keyIgnoresTrailingPunctuationAndCase() {
        #expect(SpeculativeFormatting.key("Move it to Friday") == SpeculativeFormatting.key("move it to friday."))
        #expect(SpeculativeFormatting.key("Move it to Friday") != SpeculativeFormatting.key("Move it to Friday at four."))
    }

    @Test func releaseSpeculationIsReusedWhenTheFinalOnlyAddsAPeriod() async {
        let rig = DictationControllerTests.Rig()
        let formatter = CountingFormatter(delay: 0.2)
        rig.env.formatter = formatter
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.streaming.sessions[0].emit(.textDelta("Move it to Friday"))   // live text at release
        rig.streaming.sessions[0].autoDone = "Move it to Friday."
        rig.controller.handle(.released)
        #expect(await waitUntil { rig.inserter.inserted.count == 1 })
        #expect(formatter.calls == ["Move it to Friday"], "one request, started at release with the live text")
        #expect(rig.env.metrics.first?.formatting.contains("speculative") == true)
    }

    @Test func mismatchStartsAFreshRequest() async {
        let rig = DictationControllerTests.Rig()
        let formatter = CountingFormatter(delay: 0.05)
        rig.env.formatter = formatter
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.streaming.sessions[0].emit(.textDelta("Move it to"))
        rig.streaming.sessions[0].autoDone = "Move it to Friday at four."
        rig.controller.handle(.released)
        #expect(await waitUntil { rig.inserter.inserted.count == 1 })
        #expect(formatter.calls == ["Move it to", "Move it to Friday at four."])
        #expect(rig.inserter.inserted == ["Polished: Move it to Friday at four."], "never uses the stale answer")
    }

    @Test func pauseWhileHoldingStartsFormattingEarly() async {
        let rig = DictationControllerTests.Rig()
        let formatter = CountingFormatter(delay: 0.05)
        rig.env.formatter = formatter
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.streaming.sessions[0].emit(.textDelta("See you tomorrow, actually Friday."))
        rig.audio.silence(8)   // 400 ms pause, key still held
        #expect(await waitUntil(timeout: 0.5) { formatter.calls == ["See you tomorrow, actually Friday."] })
        #expect(rig.controller.isRecording, "started before release")
    }
}
