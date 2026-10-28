import AppKit
import Foundation
import Testing
@testable import LeBlabCore

@Suite("Transcription session: partials, final, reconnect, fallback") @MainActor
struct TranscriptionSessionTests {
    func options(accuracy: Bool = false, finalTimeout: TimeInterval = 0.3) -> SessionOptions {
        SessionOptions(realtime: TranscriptionConfig(model: MistralAPI.Models.realtime, targetStreamingDelayMs: 480),
                       accuracyModel: accuracy ? MistralAPI.Models.smallBatch : nil, maxReconnects: 2, finalTimeout: finalTimeout)
    }
    func chunk(_ n: Int = 3200) -> AudioChunk { AudioChunk(pcm: Data(repeating: 7, count: n), level: 0.5, voiced: true) }

    @Test func finalTextComesFromDoneNotFromConcatenatedPartials() async throws {
        let streaming = FakeStreaming(), batch = FakeBatch()
        let session = TranscriptionSession(options: options(), streaming: streaming, batch: batch)
        var previews: [String] = []
        session.onPartial = { previews.append($0) }
        session.start()
        session.append(chunk())
        let s = streaming.sessions[0]
        s.emit(.ready)
        s.emit(.textDelta("Move the"))
        s.emit(.textDelta(" meeting"))
        s.autoDone = "Move the meeting to Friday."
        let result = await session.finish()
        #expect(previews == ["Move the", "Move the meeting"])
        #expect(try result.get().text == "Move the meeting to Friday.")
        #expect(try result.get().source == .realtime)
        #expect(batch.calls.isEmpty)
    }

    @Test func dropMidStreamReconnectsAndReplaysTheWholeUtterance() async throws {
        let streaming = FakeStreaming(), batch = FakeBatch()
        let session = TranscriptionSession(options: options(), streaming: streaming, batch: batch)
        var reconnects: [Int] = []
        session.onReconnect = { reconnects.append($0) }
        session.start()
        session.append(chunk(1000))
        session.append(chunk(1000))
        streaming.sessions[0].emit(.textDelta("hello"))
        streaming.sessions[0].emit(.failed(.network("lost")))
        #expect(reconnects == [1])
        #expect(streaming.sessions.count == 2)
        #expect(streaming.sessions[1].audio.count == 2000, "replacement session gets all audio so far")
        session.append(chunk(500))
        #expect(streaming.sessions[1].audio.count == 2500)
        #expect(session.assembler.displayText == "hello", "preview keeps the best text while the new stream catches up")
        streaming.sessions[1].autoDone = "hello there"
        #expect(try await session.finish().get().text == "hello there")
    }

    @Test func fallsBackToBatchWhenTheStreamCannotFinish() async throws {
        let streaming = FakeStreaming(), batch = FakeBatch()
        streaming.onCreate = { s in s.emit(.failed(.network("offline"))) }
        let session = TranscriptionSession(options: options(), streaming: streaming, batch: batch)
        session.start()
        session.append(chunk())
        let result = await session.finish()
        #expect(try result.get().source == .batchFallback)
        #expect(try result.get().text == "batch text")
        #expect(batch.calls.first?.model == MistralAPI.Models.miniBatch)
        #expect(batch.calls.first?.bytes == 3200)
    }

    @Test func timeoutWaitingForFinalUsesBatchFallback() async throws {
        let streaming = FakeStreaming(), batch = FakeBatch()
        let session = TranscriptionSession(options: options(finalTimeout: 0.1), streaming: streaming, batch: batch)
        session.start()
        session.append(chunk())
        streaming.sessions[0].emit(.ready)
        let result = await session.finish()   // fake never sends done
        #expect(try result.get().source == .batchFallback)
    }

    @Test func badKeyDoesNotTryTheBatchEndpoint() async {
        let streaming = FakeStreaming(), batch = FakeBatch()
        streaming.onCreate = { s in s.emit(.failed(.unauthorized)) }
        let session = TranscriptionSession(options: options(), streaming: streaming, batch: batch)
        session.start()
        session.append(chunk())
        #expect(await session.finish() == .failure(.unauthorized))
        #expect(batch.calls.isEmpty)
    }

    @Test func accuracyModeUsesSmallTranscribe3ForTheFinalText() async throws {
        let streaming = FakeStreaming(), batch = FakeBatch(result: .success(BatchTranscript(text: "accurate text", language: "de")))
        let session = TranscriptionSession(options: options(accuracy: true), streaming: streaming, batch: batch)
        session.start()
        session.append(chunk())
        streaming.sessions[0].emit(.textDelta("preview"))
        let result = await session.finish()
        #expect(try result.get().text == "accurate text")
        #expect(try result.get().source == .batchAccuracy)
        #expect(batch.calls.first?.model == MistralAPI.Models.smallBatch)
    }

    @Test func accuracyFailureFallsBackToRealtimeResult() async throws {
        let streaming = FakeStreaming(), batch = FakeBatch(result: .failure(.server(status: 500, message: "")))
        streaming.onCreate = { $0.autoDone = "realtime text" }
        let session = TranscriptionSession(options: options(accuracy: true), streaming: streaming, batch: batch)
        session.start()
        session.append(chunk())
        let result = await session.finish()
        #expect(try result.get().text == "realtime text")
        #expect(try result.get().source == .realtime)
    }

    @Test func failedDictationKeepsAudioForOneRetry() async throws {
        let streaming = FakeStreaming(), batch = FakeBatch(result: .failure(.network("offline")))
        streaming.onCreate = { s in s.emit(.failed(.network("offline"))) }
        let session = TranscriptionSession(options: options(), streaming: streaming, batch: batch)
        session.start()
        session.append(chunk())
        #expect(await session.finish() == .failure(.network("offline")))
        #expect(session.canRetry)
        batch.result = .success(BatchTranscript(text: "recovered", language: nil))
        #expect(try await session.retry().get().text == "recovered")
        #expect(!session.canRetry, "audio released after success")
    }

    @Test func cancelStopsEverything() async {
        let streaming = FakeStreaming(), batch = FakeBatch()
        let session = TranscriptionSession(options: options(), streaming: streaming, batch: batch)
        session.start()
        session.append(chunk())
        session.cancel()
        #expect(streaming.sessions[0].cancelled)
        #expect(session.phase == .cancelled)
        #expect(session.audioDuration == 0, "audio buffer wiped")
        session.append(chunk())
        #expect(streaming.sessions[0].audio.count == 3200, "no audio after cancel")
    }

    @Test func earlyFinalizationUsesSettledStreamWithoutWaitingForDone() async throws {
        let streaming = FakeStreaming(), batch = FakeBatch()
        var o = options(finalTimeout: 3)
        o.realtime.targetStreamingDelayMs = 80
        let session = TranscriptionSession(options: o, streaming: streaming, batch: batch)
        var verified: [Bool] = []
        session.onLateVerification = { verified.append($0) }
        session.start()
        session.append(chunk())
        streaming.sessions[0].emit(.textDelta("Move it to Friday."))
        let started = Date()
        let result = try await session.finish().get()
        #expect(result.text == "Move it to Friday.")
        #expect(session.finalizedEarly)
        #expect(Date().timeIntervalSince(started) < 1.0, "must not wait for the 3 s final timeout")
        #expect(batch.calls.isEmpty)
        streaming.sessions[0].emit(.done(text: "Move it to Friday.", language: nil))
        #expect(verified == [true])
    }

    @Test func noEarlyFinalizationMidSentence() async throws {
        let streaming = FakeStreaming(), batch = FakeBatch()
        var o = options(finalTimeout: 0.6)
        o.realtime.targetStreamingDelayMs = 80
        let session = TranscriptionSession(options: o, streaming: streaming, batch: batch)
        session.start()
        session.append(chunk())
        streaming.sessions[0].emit(.textDelta("Move it to"))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            streaming.sessions[0].emit(.done(text: "Move it to Friday.", language: nil))
        }
        let result = try await session.finish().get()
        #expect(result.text == "Move it to Friday.", "unfinished sentence waits for the server's final text")
        #expect(!session.finalizedEarly)
    }

    @Test func assemblerNormalizesWhitespace() {
        var a = TranscriptAssembler()
        a.append(" Hello")
        a.append("  world ")
        #expect(a.displayText == "Hello world")
    }
}

@Suite("Dictation controller: shortcut flows") @MainActor
struct DictationControllerTests {
    @MainActor final class Rig {
        let audio: FakeAudio
        let streaming: FakeStreaming
        let batch: FakeBatch
        let inserter: FakeInserter
        let env: FakeEnvironment
        let controller: DictationController

        init() {
            audio = FakeAudio()
            streaming = FakeStreaming()
            batch = FakeBatch()
            inserter = FakeInserter()
            env = FakeEnvironment()
            controller = DictationController(audio: audio, streaming: streaming, batch: batch, inserter: inserter)
            controller.environment = env
            controller.releaseTail = 0
            controller.minimumHold = 0
        }
    }

    @Test func holdSpeakReleaseInsertsFormattedText() async {
        let rig = Rig()
        rig.streaming.onCreate = { $0.autoDone = "ask code rabbit to review" }
        rig.controller.handle(.pressed)
        #expect(rig.controller.isRecording)
        #expect(rig.audio.running)
        rig.audio.speak()
        rig.controller.handle(.released)
        #expect(await waitUntil { !rig.inserter.inserted.isEmpty })
        #expect(rig.inserter.inserted == ["ask CodeRabbit to review"])
        #expect(rig.controller.lastTranscript == "ask CodeRabbit to review")
        #expect(!rig.audio.running)
        if case .inserted = rig.controller.state {} else { Issue.record("expected inserted, got \(rig.controller.state)") }
        #expect(rig.env.metrics.first?.outcome == "inserted")
        #expect(rig.env.metrics.first?.releaseToInsert != nil)
    }

    @Test func releaseClockStartsAtKeyReleaseNotAfterTheTail() async {
        let rig = Rig()
        rig.controller.releaseTail = 0.15
        rig.streaming.onCreate = { $0.autoDone = "timed" }
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.controller.handle(.released)
        #expect(await waitUntil { rig.env.metrics.count == 1 })
        let m = try! #require(rig.env.metrics.first)
        #expect((m.releaseToFinal ?? 0) >= 0.15, "the 150 ms tail is part of what the user waits for")
        #expect((m.releaseToInsert ?? 0) >= 0.15)
    }

    @Test func escapeCancelsAndNothingIsInserted() async {
        let rig = Rig()
        rig.streaming.onCreate = { $0.autoDone = "secret" }
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.controller.handle(.cancel)
        rig.controller.handle(.released)
        await settle(0.2)
        #expect(rig.inserter.inserted.isEmpty)
        #expect(rig.streaming.sessions[0].cancelled)
        #expect(!rig.streaming.sessions[0].finished)
        #expect(rig.env.stopped == [true])
    }

    @Test func quickTapInHoldModeShowsHintInsteadOfDictating() async {
        let rig = Rig()
        rig.controller.minimumHold = 10
        rig.controller.handle(.pressed)
        rig.controller.handle(.released)
        await settle(0.1)
        #expect(rig.inserter.inserted.isEmpty)
        if case .hint(let text) = rig.controller.state { #expect(text.contains("⌥Space")) } else { Issue.record("expected hint") }
    }

    @Test func toggleModeStartsAndStopsOnPresses() async {
        let rig = Rig()
        rig.env.activationMode = .toggle
        rig.streaming.onCreate = { $0.autoDone = "toggled" }
        rig.controller.handle(.pressed)
        rig.controller.handle(.released)   // ignored in toggle mode
        #expect(rig.controller.isRecording)
        rig.audio.speak()
        rig.controller.handle(.pressed)
        #expect(await waitUntil { rig.inserter.inserted == ["toggled"] })
    }

    @Test func autoStopOnTurnEndInToggleMode() async {
        let rig = Rig()
        rig.env.activationMode = .toggle
        rig.env.autoStopOnSilence = true
        rig.controller.handle(.pressed)
        #expect(rig.streaming.configs.first?.turnDetection == true)
        rig.streaming.sessions[0].autoDone = "auto stopped"
        rig.audio.speak()
        rig.streaming.sessions[0].emit(.turnEnded)
        #expect(await waitUntil { rig.inserter.inserted == ["auto stopped"] })
    }

    @Test func rapidDictationsInsertInOrderEvenIfTheFirstIsSlower() async {
        let rig = Rig()
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.controller.handle(.released)          // #1 waits for a final that comes later
        await settle()
        rig.streaming.onCreate = { $0.autoDone = "second" }
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.controller.handle(.released)          // #2 finishes immediately
        await settle(0.1)
        #expect(rig.inserter.inserted.isEmpty, "#2 must wait for #1")
        rig.streaming.sessions[0].emit(.done(text: "first", language: "en"))
        #expect(await waitUntil { rig.inserter.inserted.count == 2 })
        #expect(rig.inserter.inserted == ["first", "second"])
    }

    @Test func emptyTranscriptInsertsNothing() async {
        let rig = Rig()
        rig.streaming.onCreate = { $0.autoDone = "   " }
        rig.controller.handle(.pressed)
        rig.controller.handle(.released)
        #expect(await waitUntil { rig.env.metrics.count == 1 })
        #expect(rig.inserter.inserted.isEmpty)
        #expect(rig.env.metrics.first?.outcome == "empty")
    }

    @Test func blockedInsertionKeepsTheTranscript() async {
        let rig = Rig()
        rig.inserter.outcome = .notInserted(reason: "secure input", copied: false)
        rig.streaming.onCreate = { $0.autoDone = "keep me" }
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.controller.handle(.released)
        #expect(await waitUntil { rig.env.metrics.count == 1 })
        #expect(rig.controller.lastTranscript == "keep me")
        if case .notInserted(let text, _, _) = rig.controller.state { #expect(text == "keep me") } else { Issue.record("expected notInserted") }
    }

    @Test func networkFailureOffersRetryWhichInserts() async {
        let rig = Rig()
        rig.batch.result = .failure(.network("offline"))
        rig.streaming.onCreate = { $0.emit(.failed(.network("offline"))) }
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.controller.handle(.released)
        #expect(await waitUntil { if case .failed = rig.controller.state { return true }; return false })
        if case .failed(_, let canRetry) = rig.controller.state { #expect(canRetry) }
        rig.batch.result = .success(BatchTranscript(text: "back online", language: nil))
        rig.controller.retry()
        #expect(await waitUntil { rig.inserter.inserted == ["back online"] })
    }

    @Test func missingKeyOrMicrophoneDoesNotStartRecording() async {
        let rig = Rig()
        rig.env.apiKeyAvailable = false
        rig.controller.handle(.pressed)
        #expect(!rig.controller.isRecording)
        #expect(rig.streaming.sessions.isEmpty)
        rig.env.apiKeyAvailable = true
        rig.audio.startError = .permissionDenied
        rig.controller.handle(.pressed)
        #expect(!rig.controller.isRecording)
        if case .failed(let message, _) = rig.controller.state { #expect(message.contains("Microphone")) } else { Issue.record("expected failure") }
    }

    @Test func chordShortcutThatBecomesAnotherShortcutLeavesNoTrace() async {
        let rig = Rig()
        rig.env.activationFeedbackDelay = 0.2
        rig.controller.handle(.pressed)            // ⌃⇧ down
        #expect(rig.controller.isRecording, "audio starts immediately")
        #expect(rig.controller.state == .idle, "but nothing is shown yet")
        rig.controller.handle(.chordInterrupted)   // …it was ⌃⇧Tab
        await settle(0.3)
        #expect(rig.controller.state == .idle)
        #expect(rig.env.started == 0 && rig.env.stopped.isEmpty, "no sounds")
        #expect(rig.streaming.sessions[0].cancelled)
    }

    @Test func chordShortcutRevealsAfterDelayAndDictates() async {
        let rig = Rig()
        rig.env.activationFeedbackDelay = 0.05
        rig.streaming.onCreate = { $0.autoDone = "hello from the chord" }
        rig.controller.handle(.pressed)
        #expect(await waitUntil { rig.controller.state == .recording(preview: "") })
        #expect(rig.env.started == 1)
        rig.audio.speak()
        rig.controller.handle(.released)
        #expect(await waitUntil { rig.inserter.inserted == ["hello from the chord"] })
    }

    @Test func historyIsRecordedThroughTheEnvironmentOnly() async {
        let rig = Rig()
        rig.streaming.onCreate = { $0.autoDone = "note this" }
        rig.controller.handle(.pressed)
        rig.audio.speak()
        rig.controller.handle(.released)
        #expect(await waitUntil { rig.env.history.count == 1 })
        #expect(rig.env.history.first?.text == "note this")
    }
}
