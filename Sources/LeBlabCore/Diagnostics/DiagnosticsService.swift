import Foundation

/// Monotonic timestamps for one dictation. Contains no content — only timings.
@MainActor
public final class LatencyTimeline {
    public var pressed: TimeInterval?
    public var captureStarted: TimeInterval?
    public var streamReady: TimeInterval?
    public var firstAudio: TimeInterval?
    public var firstPartial: TimeInterval?
    /// The user let go of the shortcut (start of every "after release" metric).
    public var released: TimeInterval?
    /// Capture stopped and end-of-audio was sent (after the release tail).
    public var audioEnded: TimeInterval?
    public var finalTranscript: TimeInterval?
    public var formatted: TimeInterval?
    /// First dictated text visible in the target app (provisional or final).
    public var firstText: TimeInterval?
    /// Final text in place.
    public var inserted: TimeInterval?

    private let clock: () -> TimeInterval

    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    public func mark(_ keyPath: ReferenceWritableKeyPath<LatencyTimeline, TimeInterval?>) {
        self[keyPath: keyPath] = clock()
    }

    public func now() -> TimeInterval { clock() }

    static func span(_ from: TimeInterval?, _ to: TimeInterval?) -> TimeInterval? {
        guard let from, let to, to >= from else { return nil }
        return to - from
    }
}

public struct DictationMetrics: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var outcome: String
    public var model: String
    public var source: TranscriptSource?
    public var formatting: String
    public var insertion: String?
    public var audioSeconds: Double
    public var characters: Int
    public var reconnects: Int

    /// Key press → WebSocket session ready.
    public var connect: TimeInterval?
    /// Key press → first partial transcript on screen.
    public var firstPartial: TimeInterval?
    /// Key release → final transcript available.
    public var releaseToFinal: TimeInterval?
    /// Final transcript → formatted text.
    public var formattingTime: TimeInterval?
    /// Key release → first dictated text visible in the target app.
    public var releaseToFirstText: TimeInterval?
    /// Key release → final text in place in the target app.
    public var releaseToInsert: TimeInterval?
    /// Time spent waiting on Mistral (connect + final wait after end of audio + formatting request).
    public var apiLatency: TimeInterval?
    /// Audio captured after release (0 when the user had already stopped talking).
    public var releaseTail: TimeInterval?

    @MainActor
    public init(timeline t: LatencyTimeline, outcome: String, model: String, source: TranscriptSource?, formatting: String,
                insertion: String?, audioSeconds: Double, characters: Int, reconnects: Int) {
        self.outcome = outcome
        self.model = model
        self.source = source
        self.formatting = formatting
        self.insertion = insertion
        self.audioSeconds = audioSeconds
        self.characters = characters
        self.reconnects = reconnects
        connect = LatencyTimeline.span(t.pressed, t.streamReady)
        firstPartial = LatencyTimeline.span(t.pressed, t.firstPartial)
        releaseToFinal = LatencyTimeline.span(t.released, t.finalTranscript)
        formattingTime = LatencyTimeline.span(t.finalTranscript, t.formatted)
        releaseToFirstText = LatencyTimeline.span(t.released, t.firstText ?? t.inserted)
        releaseToInsert = LatencyTimeline.span(t.released, t.inserted)
        releaseTail = LatencyTimeline.span(t.released, t.audioEnded)
        let finalWait = LatencyTimeline.span(t.audioEnded ?? t.released, t.finalTranscript)
        let parts = [connect, finalWait, formattingTime].compactMap { $0 }
        apiLatency = parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

/// In-memory ring buffer of recent dictation metrics. Never persisted, never uploaded.
@MainActor
public final class DiagnosticsService: ObservableObject {
    @Published public private(set) var recent: [DictationMetrics] = []
    @Published public private(set) var lastError: String?
    private let capacity: Int

    public init(capacity: Int = 50) { self.capacity = capacity }

    public func record(_ metrics: DictationMetrics) {
        recent.insert(metrics, at: 0)
        if recent.count > capacity { recent.removeLast(recent.count - capacity) }
    }

    public func recordError(_ message: String) { lastError = message }

    public func clear() {
        recent.removeAll()
        lastError = nil
    }

    public struct Summary: Equatable {
        public var count: Int
        public var firstPartialP50: TimeInterval?
        public var releaseToFinalP50: TimeInterval?
        public var releaseToInsertP50: TimeInterval?
        public var releaseToInsertP90: TimeInterval?
        public var apiLatencyP50: TimeInterval?
    }

    public var summary: Summary {
        let ok = recent.filter { $0.outcome == "inserted" || $0.outcome == "copied" }
        return Summary(count: ok.count,
                       firstPartialP50: Self.percentile(ok.compactMap(\.firstPartial), 0.5),
                       releaseToFinalP50: Self.percentile(ok.compactMap(\.releaseToFinal), 0.5),
                       releaseToInsertP50: Self.percentile(ok.compactMap(\.releaseToInsert), 0.5),
                       releaseToInsertP90: Self.percentile(ok.compactMap(\.releaseToInsert), 0.9),
                       apiLatencyP50: Self.percentile(ok.compactMap(\.apiLatency), 0.5))
    }

    public nonisolated static func percentile(_ values: [TimeInterval], _ p: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - Double(lo))
    }

    public nonisolated static func format(_ t: TimeInterval?) -> String {
        guard let t else { return "—" }
        return t < 1 ? "\(Int((t * 1000).rounded())) ms" : String(format: "%.2f s", t)
    }
}
