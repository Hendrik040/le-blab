import Foundation

/// Accumulates streaming deltas for display and picks the authoritative final text.
///
/// Voxtral's realtime deltas are append-only, and `transcription.done` carries the full text,
/// so the final transcript is taken verbatim from `done` — never by concatenating partials
/// onto it. That is what prevents duplicated words.
public struct TranscriptAssembler: Equatable {
    public private(set) var streamed = ""
    /// Best text from a previous connection attempt (shown while a replacement stream catches up).
    private var previousAttempt = ""

    public init() {}

    public mutating func append(_ delta: String) { streamed += delta }

    /// A replacement session will replay the whole utterance from the start.
    public mutating func beginReplay() {
        if streamed.count > previousAttempt.count { previousAttempt = streamed }
        streamed = ""
    }

    public var displayText: String {
        let best = streamed.count >= previousAttempt.count ? streamed : previousAttempt
        return Self.normalize(best)
    }

    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TranscriptSource: String, Codable, Sendable {
    case realtime, batchAccuracy, batchFallback
}

public struct TranscriptResult: Equatable, Sendable {
    public var text: String
    public var language: String?
    public var source: TranscriptSource
    public var audioDuration: TimeInterval
    public var speechDetected: Bool
}

/// Settings a single dictation needs from the transcription layer.
public struct SessionOptions: Sendable {
    public var realtime: TranscriptionConfig
    /// Non-nil = accuracy mode: the realtime stream is preview-only and this batch model produces the final text.
    public var accuracyModel: String?
    /// Batch model used if the realtime stream can't produce a final transcript.
    public var fallbackModel: String
    public var maxReconnects: Int
    /// How long to wait for `transcription.done` after the last audio was sent.
    public var finalTimeout: TimeInterval
    /// Use the streamed text as soon as the stream has settled instead of waiting for `transcription.done`.
    ///
    /// Measured on Voxtral Mini Transcribe Realtime 3: after `input_audio.flush`/`end`, the remaining
    /// deltas arrive within ~250–450 ms, but `transcription.done` follows ~400–500 ms after the last delta.
    /// Settling early removes that wait; `done` is still received and compared for diagnostics.
    public var earlyFinalization: Bool
    /// No new delta for this long (after the look-ahead window has passed) = settled.
    public var settleWindow: TimeInterval

    public init(realtime: TranscriptionConfig, accuracyModel: String? = nil,
                fallbackModel: String = MistralAPI.Models.miniBatch, maxReconnects: Int = 2, finalTimeout: TimeInterval = 6,
                earlyFinalization: Bool = true, settleWindow: TimeInterval = 0.15) {
        self.realtime = realtime
        self.accuracyModel = accuracyModel
        self.fallbackModel = fallbackModel
        self.maxReconnects = maxReconnects
        self.finalTimeout = finalTimeout
        self.earlyFinalization = earlyFinalization
        self.settleWindow = settleWindow
    }
}

/// One dictation: audio in, final transcript out.
///
/// - Audio captured before the WebSocket is ready is queued (no lost first words).
/// - The utterance's PCM is held in memory only, so a dropped connection can be replayed on a
///   fresh session, or transcribed via the batch endpoint. A finished dictation is never lost
///   to a network blip.
/// - Buffers are zeroed when the session ends.
@MainActor
public final class TranscriptionSession {
    public enum Phase: Equatable { case streaming, finalizing, completed, failed, cancelled }

    public private(set) var phase: Phase = .streaming
    public private(set) var assembler = TranscriptAssembler()
    public private(set) var detectedLanguage: String?
    public private(set) var lastStreamError: TranscriptionError?
    public let timeline: LatencyTimeline

    /// Live preview text changed.
    public var onPartial: ((String) -> Void)?
    /// Server detected the end of the user's turn (only when turn detection is enabled).
    public var onTurnEnded: (() -> Void)?
    /// Diagnostics: a reconnect attempt was made.
    public var onReconnect: ((Int) -> Void)?
    /// Language detected by the model.
    public var onLanguage: ((String) -> Void)?
    /// After an early finalization, reports whether the server's `done` text matched (true) or differed (false).
    public var onLateVerification: ((Bool) -> Void)?
    public private(set) var finalizedEarly = false

    private let options: SessionOptions
    private let streaming: StreamingTranscriber
    private let batch: BatchTranscriber
    private var stream: StreamingTranscriptionSession?
    private var audio = Data()
    private var speechChunks = 0
    private var reconnects = 0
    private var streamFinal: (text: String, language: String?)?
    private var streamDead = false
    private var finalContinuation: CheckedContinuation<Void, Never>?
    private var lastDeltaAt: TimeInterval?
    private var releasedAt: TimeInterval?
    private var earlyText: String?

    public init(options: SessionOptions, streaming: StreamingTranscriber, batch: BatchTranscriber,
                timeline: LatencyTimeline? = nil) {
        self.options = options
        self.streaming = streaming
        self.batch = batch
        self.timeline = timeline ?? LatencyTimeline()
        audio.reserveCapacity(PCMFormat.bytesPerSecond * 30)
    }

    /// Seconds of audio captured (kept after the buffer itself is wiped).
    public var audioDuration: TimeInterval { max(PCMFormat.duration(ofBytes: audio.count), capturedDuration) }
    private var capturedDuration: TimeInterval = 0
    public var speechDetected: Bool { speechChunks >= 2 }

    public func start() {
        openStream(replay: false)
    }

    public func append(_ chunk: AudioChunk) {
        guard phase == .streaming else { return }
        if timeline.firstAudio == nil { timeline.mark(\.firstAudio) }
        audio.append(chunk.pcm)
        if chunk.voiced { speechChunks += 1 }
        stream?.send(chunk.pcm)
    }

    /// Ends audio input and resolves the final transcript (realtime → replay → batch fallback).
    public func finish() async -> Result<TranscriptResult, TranscriptionError> {
        guard phase == .streaming else { return .failure(.cancelled) }
        phase = .finalizing
        timeline.mark(\.released)
        releasedAt = timeline.now()
        capturedDuration = PCMFormat.duration(ofBytes: audio.count)

        if let accuracyModel = options.accuracyModel {
            stream?.finish()
            let result = await runBatch(model: accuracyModel, source: .batchAccuracy)
            if case .success = result { stream?.cancel(); return complete(result) }
            // Accuracy model failed: fall back to whatever the realtime stream produces.
            Log.transcription.error("Accuracy model failed; falling back to realtime result")
        } else {
            stream?.finish()
        }

        await waitForStreamFinal(timeout: options.finalTimeout + min(audioDuration * 0.25, 10),
                                 allowEarly: options.earlyFinalization && options.accuracyModel == nil)
        if phase == .cancelled { return .failure(.cancelled) }
        if streamFinal == nil, let early = settledText() {
            finalizedEarly = true
            earlyText = early
            timeline.mark(\.finalTranscript)
            let result = TranscriptResult(text: early, language: detectedLanguage, source: .realtime,
                                          audioDuration: audioDuration, speechDetected: speechDetected)
            phase = .completed
            wipeAudio()
            keepStreamForVerification()
            return .success(result)
        }
        if let final = streamFinal {
            timeline.mark(\.finalTranscript)
            return complete(.success(TranscriptResult(text: TranscriptAssembler.normalize(final.text),
                                                      language: final.language ?? detectedLanguage, source: .realtime,
                                                      audioDuration: audioDuration, speechDetected: speechDetected)))
        }
        stream?.cancel()
        // A bad key won't work on the batch endpoint either.
        if let error = lastStreamError, error == .unauthorized || error == .missingAPIKey {
            return complete(.failure(error))
        }
        Log.transcription.info("Realtime final unavailable; using batch fallback")
        return complete(await runBatch(model: options.fallbackModel, source: .batchFallback))
    }

    /// After a failed `finish()`, the audio is still in memory: transcribe it again via the batch endpoint.
    public var canRetry: Bool { phase == .failed && !audio.isEmpty }

    public func retry() async -> Result<TranscriptResult, TranscriptionError> {
        guard canRetry else { return .failure(.cancelled) }
        phase = .finalizing
        return complete(await runBatch(model: options.accuracyModel ?? options.fallbackModel, source: .batchFallback))
    }

    /// Drops retained audio (failed dictation dismissed).
    public func discard() {
        phase = .cancelled
        stream?.cancel()
        stream = nil
        wipeAudio()
    }

    public func cancel() {
        guard phase == .streaming || phase == .finalizing else { return }
        phase = .cancelled
        stream?.cancel()
        stream = nil
        resumeFinalWaiter()
        wipeAudio()
    }

    // MARK: - Streaming

    private func openStream(replay: Bool) {
        streamDead = false
        let session = streaming.makeSession(config: options.realtime) { [weak self] event in
            self?.handle(event)
        }
        stream = session
        session.start()
        if replay {
            assembler.beginReplay()
            session.send(audio)
            if phase == .finalizing { session.finish() }
        }
    }

    private func handle(_ event: StreamingTranscriptionEvent) {
        if phase == .completed, let earlyText {
            // Early-finalized: compare the server's authoritative text, then let the stream go.
            if case .done(let text, _) = event {
                let matched = TranscriptAssembler.normalize(text) == earlyText
                if !matched { Log.transcription.error("Early final differed from transcription.done") }
                onLateVerification?(matched)
                self.earlyText = nil
                stream = nil
            } else if case .failed = event {
                self.earlyText = nil
                stream = nil
            }
            return
        }
        guard phase == .streaming || phase == .finalizing else { return }
        switch event {
        case .ready:
            if timeline.streamReady == nil { timeline.mark(\.streamReady) }
        case .textDelta(let delta):
            if timeline.firstPartial == nil { timeline.mark(\.firstPartial) }
            lastDeltaAt = timeline.now()
            assembler.append(delta)
            onPartial?(assembler.displayText)
        case .language(let language):
            detectedLanguage = language
            onLanguage?(language)
        case .turnEnded:
            onTurnEnded?()
        case .done(let text, let language):
            streamFinal = (text, language)
            resumeFinalWaiter()
        case .failed(let error):
            lastStreamError = error
            stream = nil
            if error.isTransient, reconnects < options.maxReconnects {
                reconnects += 1
                onReconnect?(reconnects)
                Log.transcription.info("Reconnecting realtime stream (attempt \(self.reconnects))")
                openStream(replay: true)
            } else {
                streamDead = true
                resumeFinalWaiter()
            }
        }
    }

    private func waitForStreamFinal(timeout: TimeInterval, allowEarly: Bool) async {
        if streamFinal != nil || streamDead || stream == nil { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            guard !Task.isCancelled else { return }
            self?.lastStreamError = .timeout("waiting for the final transcript")
            self?.resumeFinalWaiter()
        }
        let settle = allowEarly ? Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.settledText() != nil { self.resumeFinalWaiter(); return }
            }
        } : nil
        await withCheckedContinuation { continuation in
            finalContinuation = continuation
        }
        timer.cancel()
        settle?.cancel()
    }

    /// The streamed text, if the stream has visibly finished after release:
    /// the model's look-ahead window plus margin has elapsed, no delta for `settleWindow`,
    /// and the text ends a sentence (Voxtral emits final punctuation when it flushes).
    private func settledText() -> String? {
        guard options.earlyFinalization, options.accuracyModel == nil, streamFinal == nil, !streamDead,
              stream != nil, let releasedAt else { return nil }
        let now = timeline.now()
        let lookAhead = Double(options.realtime.targetStreamingDelayMs ?? 480) / 1000 + 0.12
        guard now - releasedAt >= lookAhead else { return nil }
        if let lastDeltaAt, now - lastDeltaAt < options.settleWindow { return nil }
        let text = TranscriptAssembler.normalize(assembler.streamed)
        guard let last = text.last, ".!?…。！？".contains(last) else { return nil }
        return text
    }

    /// Holds the stream open (max 3 s) so `transcription.done` can be compared with the early result.
    private func keepStreamForVerification() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.earlyText != nil else { return }
            self.earlyText = nil
            self.stream?.cancel()
            self.stream = nil
        }
    }

    private func resumeFinalWaiter() {
        let c = finalContinuation
        finalContinuation = nil
        c?.resume()
    }

    // MARK: - Batch

    private func runBatch(model: String, source: TranscriptSource) async -> Result<TranscriptResult, TranscriptionError> {
        guard !audio.isEmpty else {
            return .success(TranscriptResult(text: "", language: nil, source: source, audioDuration: 0, speechDetected: false))
        }
        var config = options.realtime
        config.model = model
        config.targetStreamingDelayMs = nil
        config.turnDetection = false
        let pcm = audio
        do {
            let transcript = try await batch.transcribe(pcm: pcm, config: config)
            if phase == .cancelled { return .failure(.cancelled) }
            timeline.mark(\.finalTranscript)
            return .success(TranscriptResult(text: TranscriptAssembler.normalize(transcript.text),
                                             language: transcript.language ?? detectedLanguage, source: source,
                                             audioDuration: audioDuration, speechDetected: speechDetected))
        } catch let error as TranscriptionError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private func complete(_ result: Result<TranscriptResult, TranscriptionError>) -> Result<TranscriptResult, TranscriptionError> {
        if phase != .cancelled {
            if case .success = result { phase = .completed } else { phase = .failed }
        }
        stream = nil
        // Keep audio only while a retry is possible; otherwise release it right away.
        if phase != .failed { wipeAudio() }
        return result
    }

    private func wipeAudio() {
        audio.resetBytes(in: 0..<audio.count)
        audio.removeAll(keepingCapacity: false)
    }
}
