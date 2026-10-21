import Foundation

/// Model-agnostic speech transcription interfaces.
///
/// Voxtral is one implementation. A local model (e.g. an on-device Whisper/Parakeet
/// port) can be dropped in by conforming to these two protocols — nothing above this
/// layer knows which provider produced the text.

/// Fixed PCM format every transcriber in Le Blab consumes: 16 kHz, mono, signed 16-bit LE.
public enum PCMFormat {
    public static let sampleRate: Int = 16_000
    public static let bytesPerSample: Int = 2
    public static let bytesPerSecond: Int = sampleRate * bytesPerSample

    public static func duration(ofBytes count: Int) -> TimeInterval {
        Double(count) / Double(bytesPerSecond)
    }
}

public struct TranscriptionConfig: Equatable, Sendable {
    /// Model identifier understood by the transcriber (e.g. `voxtral-mini-transcribe-realtime-3-0`).
    public var model: String
    /// ISO-639-1 code, or nil for automatic language detection.
    public var language: String?
    /// Terms/phrases to bias recognition toward (custom vocabulary).
    public var contextBias: [String]
    /// Realtime only: how long the model waits for right-context before emitting text.
    public var targetStreamingDelayMs: Int?
    /// Realtime only: enable server-side semantic turn detection (used for auto-stop).
    public var turnDetection: Bool

    public init(model: String, language: String? = nil, contextBias: [String] = [],
                targetStreamingDelayMs: Int? = nil, turnDetection: Bool = false) {
        self.model = model
        self.language = language
        self.contextBias = contextBias
        self.targetStreamingDelayMs = targetStreamingDelayMs
        self.turnDetection = turnDetection
    }
}

/// Events emitted by a streaming session. Delivered on the main actor.
public enum StreamingTranscriptionEvent: Equatable, Sendable {
    /// Server accepted the session; audio can flow.
    case ready
    /// Incremental text. `delta` is appended to everything received so far in this session.
    case textDelta(String)
    /// Language detected by the model.
    case language(String)
    /// Semantic end of turn detected by the server (only when turn detection is enabled).
    case turnEnded
    /// Authoritative final transcript for the whole session.
    case done(text: String, language: String?)
    /// Terminal failure. The session will emit nothing else.
    case failed(TranscriptionError)
}

@MainActor
public protocol StreamingTranscriptionSession: AnyObject {
    /// Opens the connection. Audio sent before the session is ready is buffered by the caller.
    func start()
    /// Streams PCM (16 kHz mono s16le).
    func send(_ pcm: Data)
    /// Signals end of audio; the session will emit `.done` (or `.failed`).
    func finish()
    /// Tears down immediately; no further events.
    func cancel()
}

@MainActor
public protocol StreamingTranscriber: AnyObject {
    var displayName: String { get }
    func makeSession(config: TranscriptionConfig,
                     onEvent: @escaping @MainActor (StreamingTranscriptionEvent) -> Void) -> StreamingTranscriptionSession
}

public struct BatchTranscript: Equatable, Sendable {
    public var text: String
    public var language: String?
    public init(text: String, language: String?) {
        self.text = text
        self.language = language
    }
}

public protocol BatchTranscriber: Sendable {
    /// Transcribes an in-memory PCM buffer (16 kHz mono s16le). Never touches disk.
    func transcribe(pcm: Data, config: TranscriptionConfig) async throws -> BatchTranscript
}

public enum TranscriptionError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingAPIKey
    case unauthorized
    case forbidden(String)
    case rateLimited(retryAfter: TimeInterval?)
    case timeout(String)
    case network(String)
    case server(status: Int, message: String)
    case protocolError(String)
    case badRequest(String)
    case cancelled

    /// Whether retrying the same request on a fresh connection could help.
    public var isTransient: Bool {
        switch self {
        case .network, .timeout, .server: return true
        case .rateLimited: return true
        default: return false
        }
    }

    public var description: String { userMessage }

    public var userMessage: String {
        switch self {
        case .missingAPIKey: return "No Mistral API key. Add one in Settings → Account."
        case .unauthorized: return "Mistral rejected the API key (401). Check it in Settings → Account."
        case .forbidden(let m): return "Access denied by Mistral (403). \(m)"
        case .rateLimited(let after):
            if let after { return "Rate limited by Mistral. Try again in \(Int(after.rounded(.up)))s." }
            return "Rate limited by Mistral. Try again shortly."
        case .timeout(let what): return "Timed out \(what)."
        case .network(let m): return "Network problem: \(m)"
        case .server(let status, let m): return "Mistral server error \(status). \(m)"
        case .protocolError(let m): return "Unexpected response from Mistral: \(m)"
        case .badRequest(let m): return "Request rejected: \(m)"
        case .cancelled: return "Cancelled."
        }
    }
}
