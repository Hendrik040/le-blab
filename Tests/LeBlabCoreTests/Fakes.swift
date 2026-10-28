import ApplicationServices
import Foundation
@testable import LeBlabCore

/// In-memory WebSocket: records what the client sends and lets tests push server messages.
@MainActor
final class FakeSocket: RealtimeSocket {
    var sent: [String] = []
    var resumed = false
    var cancelled = false
    var handshakeStatus: Int?
    var handshakeHeaders: [AnyHashable: Any] = [:]
    private var inbox: [Result<String, Error>] = []
    private var waiter: CheckedContinuation<String, Error>?

    func resume() { resumed = true }
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) { sent.append(text); completion(nil) }
    func cancel() {
        cancelled = true
        deliver(.failure(URLError(.cancelled)))
    }

    func receive() async throws -> String {
        if !inbox.isEmpty { return try inbox.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func push(_ json: String) { deliver(.success(json)) }
    func fail(_ error: Error) { deliver(.failure(error)) }

    private func deliver(_ result: Result<String, Error>) {
        if let w = waiter {
            waiter = nil
            w.resume(with: result)
        } else {
            inbox.append(result)
        }
    }

    var sentTypes: [String] {
        sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["type"] as? String }
    }

    var sentAudio: Data {
        sent.reduce(into: Data()) { acc, msg in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(msg.utf8)) as? [String: Any],
                  obj["type"] as? String == "input_audio.append", let b64 = obj["audio"] as? String,
                  let data = Data(base64Encoded: b64) else { return }
            acc.append(data)
        }
    }
}

/// Streaming transcriber whose sessions are scripted by the test.
@MainActor
final class FakeStreaming: StreamingTranscriber {
    let displayName = "fake"
    var sessions: [FakeStreamSession] = []
    var configs: [TranscriptionConfig] = []
    /// Called right after a session is created, e.g. to make it fail immediately.
    var onCreate: ((FakeStreamSession) -> Void)?

    func makeSession(config: TranscriptionConfig,
                     onEvent: @escaping @MainActor (StreamingTranscriptionEvent) -> Void) -> StreamingTranscriptionSession {
        let s = FakeStreamSession(onEvent: onEvent)
        sessions.append(s)
        configs.append(config)
        onCreate?(s)
        return s
    }
}

@MainActor
final class FakeStreamSession: StreamingTranscriptionSession {
    let onEvent: @MainActor (StreamingTranscriptionEvent) -> Void
    var audio = Data()
    var started = false
    var finished = false
    var cancelled = false
    /// If set, `finish()` immediately answers with `.done(text)`.
    var autoDone: String?

    init(onEvent: @escaping @MainActor (StreamingTranscriptionEvent) -> Void) { self.onEvent = onEvent }

    func start() { started = true }
    func send(_ pcm: Data) { audio.append(pcm) }
    func finish() {
        finished = true
        if let autoDone { onEvent(.done(text: autoDone, language: "en")) }
    }
    func cancel() { cancelled = true }
    func emit(_ e: StreamingTranscriptionEvent) { onEvent(e) }
}

final class FakeBatch: BatchTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(bytes: Int, model: String)] = []
    var result: Result<BatchTranscript, TranscriptionError>

    init(result: Result<BatchTranscript, TranscriptionError> = .success(BatchTranscript(text: "batch text", language: "en"))) {
        self.result = result
    }

    var calls: [(bytes: Int, model: String)] { lock.withLock { _calls } }

    func transcribe(pcm: Data, config: TranscriptionConfig) async throws -> BatchTranscript {
        lock.withLock { _calls.append((pcm.count, config.model)) }
        return try result.get()
    }
}

final class FakeAudio: AudioCapturing {
    var onChunk: ((AudioChunk) -> Void)?
    var onInterrupted: ((AudioCaptureError) -> Void)?
    var running = false
    var startError: AudioCaptureError?
    func start(deviceUID: String?) throws {
        if let startError { throw startError }
        running = true
    }
    func stop() { running = false }
    func speak(_ bytes: Int = 3200) { onChunk?(AudioChunk(pcm: Data(repeating: 1, count: bytes), level: 0.5, voiced: true)) }
    /// 50 ms unvoiced chunks.
    func silence(_ chunks: Int = 7) {
        for _ in 0..<chunks { onChunk?(AudioChunk(pcm: Data(count: 1600), level: 0, voiced: false)) }
    }
}

@MainActor
final class FakeInserter: TextInserting {
    var inserted: [String] = []
    var outcome: InsertionOutcome = .pasted
    /// Native-app behaviour: provisional insertion supported.
    var supportsProvisional = false
    /// Simulates the user editing the text before the polished version arrives.
    var replaceSucceeds = true
    var provisional: [String] = []
    var replacements: [(from: String, to: String)] = []
    /// What the "document" shows after all operations.
    var document: [String] = []

    func insert(_ text: String) async -> InsertionOutcome {
        inserted.append(text)
        document.append(text)
        return outcome
    }

    /// Field accepts text but can't be read back (handle not replaceable).
    var provisionalReplaceable = true

    func insertProvisional(_ text: String) async -> ProvisionalInsertion? {
        guard supportsProvisional else { return nil }
        provisional.append(text)
        document.append(text)
        // A placeholder element marks the handle replaceable; the fake never touches it.
        let element: AXUIElement? = provisionalReplaceable ? AXUIElementCreateSystemWide() : nil
        return ProvisionalInsertion(insertedText: text, element: element, range: CFRange(location: 0, length: text.utf16.count))
    }

    func replaceProvisional(_ insertion: ProvisionalInsertion, with text: String) async -> ReplacementOutcome {
        replacements.append((insertion.insertedText, text))
        guard insertion.isReplaceable else { return .notReplaceable }
        guard replaceSucceeds, let i = document.lastIndex(of: insertion.insertedText) else { return .keptProvisional }
        document[i] = text
        return .replaced
    }
}

/// Formatter with a scripted provisional text and a delayed final result.
struct FakeFormatter: TranscriptFormatting {
    var provisional: String?
    var final: String
    var delay: TimeInterval
    func provisionalText(for transcript: String, language: String?) -> String? { provisional }
    func format(_ transcript: String, language: String?) async -> FormattedText {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        return FormattedText(text: final, usedLanguageModel: provisional != nil, fallbackReason: nil)
    }
}

@MainActor
final class FakeEnvironment: DictationEnvironment {
    var apiKeyAvailable = true
    var microphoneAuthorized = true
    var activationMode: ActivationMode = .holdToTalk
    var autoStopOnSilence = false
    var inputDeviceUID: String?
    var shortcutLabel = "⌥Space"
    var activationFeedbackDelay: TimeInterval = 0
    var optimisticInsertEnabled = false
    var speedFirstInPasteApps = false
    var formatter: TranscriptFormatting?
    var formattingLabel = "raw"
    var accuracy = false
    var history: [HistoryEntry] = []
    var metrics: [DictationMetrics] = []
    var started = 0
    var stopped: [Bool] = []

    func requestMicrophoneAccess() async -> Bool { true }
    func sessionOptions(turnDetection: Bool) -> SessionOptions {
        SessionOptions(realtime: TranscriptionConfig(model: MistralAPI.Models.realtime, targetStreamingDelayMs: 480, turnDetection: turnDetection),
                       accuracyModel: accuracy ? MistralAPI.Models.smallBatch : nil, maxReconnects: 2, finalTimeout: 0.3)
    }
    func makeFormatter() -> TranscriptFormatting {
        formatter ?? RawFormatter(vocabulary: VocabularyCorrector(entries: VocabularyEntry.defaults))
    }
    func recordingDidStart() { started += 1 }
    func recordingDidStop(cancelled: Bool) { stopped.append(cancelled) }
    func record(history entry: HistoryEntry) { history.append(entry) }
    func record(metrics m: DictationMetrics) { metrics.append(m) }
}

/// Lets queued main-actor work (Tasks, callbacks) run.
@MainActor
func settle(_ seconds: Double = 0.05) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
}

@MainActor
func waitUntil(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        await settle(0.01)
    }
    return true
}
