import Foundation

public enum DictationState: Equatable, Sendable {
    case idle
    case recording(preview: String)
    case processing(preview: String)
    case inserted(text: String, method: String, latency: TimeInterval?)
    /// Transcript is done but couldn't be inserted automatically. It is kept for manual copy.
    case notInserted(text: String, reason: String, copied: Bool)
    case failed(message: String, canRetry: Bool)
    case hint(String)

    public var isActive: Bool {
        if case .recording = self { return true }
        if case .processing = self { return true }
        return false
    }
}

/// UI/OS side effects the controller requests; implemented by the app layer.
@MainActor
public protocol DictationEnvironment: AnyObject {
    var apiKeyAvailable: Bool { get }
    var microphoneAuthorized: Bool { get }
    func requestMicrophoneAccess() async -> Bool
    func sessionOptions(turnDetection: Bool) -> SessionOptions
    func makeFormatter() -> TranscriptFormatting
    var formattingLabel: String { get }
    var activationMode: ActivationMode { get }
    var autoStopOnSilence: Bool { get }
    var inputDeviceUID: String? { get }
    var shortcutLabel: String { get }
    /// Delay before the overlay/sound appear (modifier-chord shortcuts; 0 for key combos).
    var activationFeedbackDelay: TimeInterval { get }
    func recordingDidStart()
    func recordingDidStop(cancelled: Bool)
    func record(history: HistoryEntry)
    func record(metrics: DictationMetrics)
}

/// The dictation state machine: shortcut → microphone → Voxtral → formatter → insertion.
///
/// Guarantees:
/// - A finished transcript is never dropped: if insertion fails it stays in `lastTranscript` (and the
///   overlay offers Copy); if transcription fails the audio is kept in memory for one retry.
/// - Overlapping dictations (press again while the previous one is still processing) insert in order.
/// - Escape cancels and discards the current dictation; nothing is sent after that.
@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var level: Float = 0
    @Published public private(set) var lastTranscript: String?
    @Published public private(set) var detectedLanguage: String?
    @Published public private(set) var isRecording = false

    public var audio: AudioCapturing
    public let streaming: StreamingTranscriber
    public let batch: BatchTranscriber
    public let inserter: TextInserting
    public weak var environment: DictationEnvironment?

    /// Audio captured after the key is released, so the last syllable isn't clipped.
    public var releaseTail: TimeInterval = 0.12
    /// Hold-to-talk presses shorter than this are treated as accidental taps.
    public var minimumHold: TimeInterval = 0.3
    public var maxDuration: TimeInterval = 15 * 60

    private struct Recording {
        let id = UUID()
        let session: TranscriptionSession
        let startedAt: TimeInterval
        var reconnects = 0
        /// Overlay and start sound have been shown (see `activationFeedbackDelay`).
        var revealed = false
    }

    private var current: Recording?
    private var lastInsertionGate: OneShotGate?
    private var retainedFailure: (session: TranscriptionSession, timeline: LatencyTimeline)?
    private var stateToken = UUID()
    private var maxDurationTask: Task<Void, Never>?
    private let clock: () -> TimeInterval

    public init(audio: AudioCapturing, streaming: StreamingTranscriber, batch: BatchTranscriber, inserter: TextInserting,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.audio = audio
        self.streaming = streaming
        self.batch = batch
        self.inserter = inserter
        self.clock = clock
    }

    // MARK: - Input

    public func handle(_ event: HotkeyEvent) {
        let mode = environment?.activationMode ?? .holdToTalk
        switch event {
        case .pressed:
            if mode == .toggle && isRecording { stop() } else if !isRecording { start() }
        case .released:
            guard mode == .holdToTalk, let current else { return }
            if clock() - current.startedAt < minimumHold {
                cancel(showHint: "Hold \(environment?.shortcutLabel ?? "the shortcut") while you speak.")
            } else {
                stop()
            }
        case .cancel:
            if isRecording { cancel(showHint: nil) }
        case .chordInterrupted:
            if let current, clock() - current.startedAt < 1.0 { cancel(showHint: nil, silent: true) }
        }
    }

    public func toggleFromMenu() {
        if isRecording { stop() } else { start() }
    }

    // MARK: - Lifecycle

    public func start() {
        guard current == nil, let env = environment else { return }
        guard env.apiKeyAvailable else {
            show(.failed(message: TranscriptionError.missingAPIKey.userMessage, canRetry: false))
            return
        }
        guard env.microphoneAuthorized else {
            Task {
                let granted = await env.requestMicrophoneAccess()
                show(granted ? .hint("Microphone enabled — press \(env.shortcutLabel) again to dictate.")
                             : .failed(message: AudioCaptureError.permissionDenied.description, canRetry: false))
            }
            return
        }
        discardRetainedFailure()

        let timeline = LatencyTimeline(clock: clock)
        timeline.mark(\.pressed)
        let turnDetection = env.activationMode == .toggle && env.autoStopOnSilence
        let session = TranscriptionSession(options: env.sessionOptions(turnDetection: turnDetection),
                                           streaming: streaming, batch: batch, timeline: timeline)
        let recording = Recording(session: session, startedAt: clock())
        let id = recording.id

        session.onPartial = { [weak self] preview in
            guard let self, self.current?.id == id, self.current?.revealed == true else { return }
            self.show(.recording(preview: preview))
        }
        session.onTurnEnded = { [weak self] in
            guard let self, self.current?.id == id else { return }
            self.stop()
        }
        session.onReconnect = { [weak self] n in
            guard let self, self.current?.id == id else { return }
            self.current?.reconnects = n
        }
        session.onLanguage = { [weak self] language in self?.detectedLanguage = language }
        audio.onChunk = { [weak self, weak session] chunk in
            session?.append(chunk)
            self?.level = chunk.level
        }
        audio.onInterrupted = { [weak self] _ in
            // Mic vanished: finalize what we have instead of losing it.
            guard let self, self.current?.id == id else { return }
            self.stop()
        }

        session.start()
        do {
            try audio.start(deviceUID: env.inputDeviceUID)
        } catch {
            session.cancel()
            show(.failed(message: (error as? AudioCaptureError)?.description ?? error.localizedDescription, canRetry: false))
            return
        }
        timeline.mark(\.captureStarted)
        current = recording
        isRecording = true
        detectedLanguage = nil
        // Audio is already flowing; only the visible/audible feedback waits (chord shortcuts).
        let delay = env.activationFeedbackDelay
        if delay <= 0 {
            reveal(id)
        } else {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                self?.reveal(id)
            }
        }

        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.maxDuration ?? 900) * 1e9))
            guard !Task.isCancelled, let self, self.current?.id == id else { return }
            self.stop()
        }
    }

    private func reveal(_ id: UUID) {
        guard current?.id == id, current?.revealed == false else { return }
        current?.revealed = true
        show(.recording(preview: current?.session.assembler.displayText ?? ""))
        environment?.recordingDidStart()
    }

    public func stop() {
        guard var recording = current else { return }
        if !recording.revealed {
            // Released before feedback appeared: still a real dictation (fast talker), show it now.
            reveal(recording.id)
            recording.revealed = true
        }
        current = nil
        isRecording = false
        maxDurationTask?.cancel()
        environment?.recordingDidStop(cancelled: false)
        let preview = recording.session.assembler.displayText
        show(.processing(preview: preview))

        // Reserve this dictation's place in the insertion order now, before any awaits.
        let previousGate = lastInsertionGate
        let gate = OneShotGate()
        lastInsertionGate = gate

        Task { [weak self] in
            guard let self else { gate.open(); return }
            try? await Task.sleep(nanoseconds: UInt64(self.releaseTail * 1e9))
            self.audio.stop()
            self.level = 0
            await self.process(recording, after: previousGate, gate: gate)
        }
    }

    public func cancel(showHint hint: String?, silent: Bool = false) {
        guard let recording = current else { return }
        current = nil
        isRecording = false
        maxDurationTask?.cancel()
        audio.stop()
        level = 0
        recording.session.cancel()
        guard recording.revealed else {
            // Nothing was shown yet (e.g. ⌃⇧ turned out to be ⌃⇧Tab): vanish without a trace.
            if case .recording = state { show(.idle) }
            return
        }
        environment?.recordingDidStop(cancelled: true)
        if let hint { show(.hint(hint)) } else if silent { show(.idle) } else { show(.hint("Dictation cancelled.")) }
    }

    /// Re-transcribes a failed dictation from the audio still held in memory.
    public func retry() {
        guard let failure = retainedFailure, failure.session.canRetry else { return }
        retainedFailure = nil
        show(.processing(preview: ""))
        let previousGate = lastInsertionGate
        let gate = OneShotGate()
        lastInsertionGate = gate
        Task { [weak self] in
            guard let self else { gate.open(); return }
            let result = await failure.session.retry()
            await self.complete(result, session: failure.session, timeline: failure.timeline, reconnects: 0,
                                after: previousGate, gate: gate)
        }
    }

    public func dismiss() {
        discardRetainedFailure()
        if !isRecording { show(.idle) }
    }

    // MARK: - Processing

    private func process(_ recording: Recording, after previousGate: OneShotGate?, gate: OneShotGate) async {
        let result = await recording.session.finish()
        await complete(result, session: recording.session, timeline: recording.session.timeline,
                       reconnects: recording.reconnects, after: previousGate, gate: gate)
    }

    private func complete(_ result: Result<TranscriptResult, TranscriptionError>, session: TranscriptionSession,
                          timeline: LatencyTimeline, reconnects: Int, after previousGate: OneShotGate?, gate: OneShotGate) async {
        defer { gate.open() }
        let env = environment
        let modelName = env?.sessionOptions(turnDetection: false).accuracyModel ?? MistralAPI.Models.realtime

        func metrics(_ outcome: String, source: TranscriptSource?, formatting: String, insertion: String?, chars: Int) {
            env?.record(metrics: DictationMetrics(timeline: timeline, outcome: outcome, model: modelName, source: source,
                                                  formatting: formatting, insertion: insertion,
                                                  audioSeconds: session.audioDuration, characters: chars, reconnects: reconnects))
        }

        let transcript: TranscriptResult
        switch result {
        case .failure(.cancelled):
            return
        case .failure(let error):
            if session.canRetry { retainedFailure = (session, timeline) }
            showUnlessRecording(.failed(message: error.userMessage, canRetry: session.canRetry))
            metrics("error: \(error.userMessage)", source: nil, formatting: "-", insertion: nil, chars: 0)
            return
        case .success(let t):
            transcript = t
        }

        guard !transcript.text.isEmpty else {
            showUnlessRecording(.hint(transcript.speechDetected ? "Couldn't make out any words." : "No speech detected."))
            metrics("empty", source: transcript.source, formatting: "-", insertion: nil, chars: 0)
            return
        }

        let formatter = env?.makeFormatter() ?? RawFormatter(vocabulary: VocabularyCorrector(entries: []))
        let formatted = await formatter.format(transcript.text, language: transcript.language)
        timeline.mark(\.formatted)
        let finalText = formatted.text.isEmpty ? transcript.text : formatted.text
        // Kept before insertion is attempted, so it survives any insertion failure.
        lastTranscript = finalText

        await previousGate?.wait()
        let outcome = await inserter.insert(finalText)
        timeline.mark(\.inserted)

        env?.record(history: HistoryEntry(text: finalText, rawText: formatted.usedLanguageModel ? transcript.text : nil,
                                          language: transcript.language, model: modelName))
        let formattingLabel = formatted.usedLanguageModel ? (env?.formattingLabel ?? "smart")
            : (formatted.fallbackReason.map { "raw (\($0))" } ?? "raw")
        switch outcome {
        case .notInserted(let reason, let copied):
            showUnlessRecording(.notInserted(text: finalText, reason: reason, copied: copied))
            metrics(copied ? "copied" : "not inserted", source: transcript.source, formatting: formattingLabel,
                    insertion: outcome.label, chars: finalText.count)
        default:
            showUnlessRecording(.inserted(text: finalText, method: outcome.label,
                                          latency: LatencyTimeline.span(timeline.released, timeline.inserted)))
            metrics("inserted", source: transcript.source, formatting: formattingLabel, insertion: outcome.label,
                    chars: finalText.count)
        }
    }

    // MARK: - State

    private func showUnlessRecording(_ newState: DictationState) {
        if !isRecording { show(newState) }
    }

    private func show(_ newState: DictationState) {
        state = newState
        let token = UUID()
        stateToken = token
        let linger: TimeInterval?
        switch newState {
        case .inserted: linger = 1.4
        case .hint: linger = 2.2
        case .notInserted: linger = 12
        case .failed: linger = 10
        default: linger = nil
        }
        guard let linger else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(linger * 1e9))
            guard let self, self.stateToken == token, !self.isRecording else { return }
            self.state = .idle
        }
    }

    private func discardRetainedFailure() {
        retainedFailure?.session.discard()
        retainedFailure = nil
    }
}

/// One-shot async gate used to keep insertions in dictation order.
@MainActor
final class OneShotGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume() }
    }
}
