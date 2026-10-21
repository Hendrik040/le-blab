import Foundation
import os

/// Minimal WebSocket surface the realtime session needs (lets tests swap in a fake).
@MainActor
public protocol RealtimeSocket: AnyObject {
    func resume()
    /// Sends are delivered in call order.
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void)
    func receive() async throws -> String
    func cancel()
    /// HTTP status of a failed upgrade, if any.
    var handshakeStatus: Int? { get }
    var handshakeHeaders: [AnyHashable: Any] { get }
}

@MainActor
final class URLSessionRealtimeSocket: RealtimeSocket {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = 8 * 1024 * 1024
    }

    func resume() { task.resume() }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func cancel() { task.cancel(with: .normalClosure, reason: nil) }

    var handshakeStatus: Int? {
        guard let http = task.response as? HTTPURLResponse, http.statusCode != 101 else { return nil }
        return http.statusCode
    }

    var handshakeHeaders: [AnyHashable: Any] { (task.response as? HTTPURLResponse)?.allHeaderFields ?? [:] }
}

/// Streams PCM to Voxtral Mini Transcribe Realtime 3 over Mistral's documented WebSocket
/// (`/v1/audio/transcriptions/realtime`). Swift-native: no Python helper, no local server.
@MainActor
public final class VoxtralRealtimeTranscriber: StreamingTranscriber {
    public let displayName = "Voxtral Mini Transcribe Realtime 3"
    private let region: () -> MistralAPI.Region
    private let apiKey: () -> String?
    private let makeSocket: (URLRequest) -> RealtimeSocket
    /// Silence length (ms) the server waits for before `turn.end` when turn detection is on.
    public var minSilenceMs: Int = 900

    public convenience init(region: @escaping () -> MistralAPI.Region,
                            apiKey: @escaping () -> String?,
                            urlSession: URLSession = VoxtralRealtimeTranscriber.makeURLSession()) {
        self.init(region: region, apiKey: apiKey) { request in
            URLSessionRealtimeSocket(task: urlSession.webSocketTask(with: request))
        }
    }

    public init(region: @escaping () -> MistralAPI.Region, apiKey: @escaping () -> String?,
                makeSocket: @escaping (URLRequest) -> RealtimeSocket) {
        self.region = region
        self.apiKey = apiKey
        self.makeSocket = makeSocket
    }

    /// The process-wide session (see `MistralAPI.sharedSession`).
    public nonisolated static func makeURLSession() -> URLSession { MistralAPI.sharedSession }

    public func makeSession(config: TranscriptionConfig,
                            onEvent: @escaping @MainActor (StreamingTranscriptionEvent) -> Void) -> StreamingTranscriptionSession {
        VoxtralRealtimeSession(config: config, region: region(), apiKey: apiKey(),
                               minSilenceMs: minSilenceMs, makeSocket: makeSocket, onEvent: onEvent)
    }
}

@MainActor
final class VoxtralRealtimeSession: StreamingTranscriptionSession {
    private enum State { case idle, connecting, ready, closed }

    private let config: TranscriptionConfig
    private let region: MistralAPI.Region
    private let apiKey: String?
    private let minSilenceMs: Int
    private let makeSocket: (URLRequest) -> RealtimeSocket
    private let onEvent: @MainActor (StreamingTranscriptionEvent) -> Void

    private var task: RealtimeSocket?
    private var state: State = .idle
    private var pending: [Data] = []
    private var finishRequested = false
    private var endSent = false
    private var connectTimeout: Task<Void, Never>?
    private(set) var requestID: String?

    static let connectTimeoutSeconds: Double = 6

    init(config: TranscriptionConfig, region: MistralAPI.Region, apiKey: String?, minSilenceMs: Int,
         makeSocket: @escaping (URLRequest) -> RealtimeSocket, onEvent: @escaping @MainActor (StreamingTranscriptionEvent) -> Void) {
        self.config = config
        self.region = region
        self.apiKey = apiKey
        self.minSilenceMs = minSilenceMs
        self.makeSocket = makeSocket
        self.onEvent = onEvent
    }

    func start() {
        guard state == .idle else { return }
        guard let apiKey, !apiKey.isEmpty else {
            state = .closed
            onEvent(.failed(.missingAPIKey))
            return
        }
        state = .connecting
        var request = URLRequest(url: MistralAPI.realtimeURL(region: region, model: config.model),
                                 timeoutInterval: Self.connectTimeoutSeconds)
        MistralAPI.authorize(&request, apiKey: apiKey)
        let task = makeSocket(request)
        self.task = task
        task.resume()
        receiveLoop(task)

        connectTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeoutSeconds * 1e9))
            guard let self, !Task.isCancelled, self.state == .connecting else { return }
            self.fail(.timeout("connecting to Mistral"))
        }
    }

    func send(_ pcm: Data) {
        guard !pcm.isEmpty, state != .closed, !endSent else { return }
        if state == .ready {
            transmit(pcm)
        } else {
            pending.append(pcm)
        }
    }

    func finish() {
        guard state != .closed, !finishRequested else { return }
        finishRequested = true
        if state == .ready { sendEnd() }
        // Otherwise sendEnd() runs as soon as the session is ready.
    }

    func cancel() {
        guard state != .closed else { return }
        state = .closed
        connectTimeout?.cancel()
        pending.removeAll()
        task?.cancel()
        task = nil
    }

    // MARK: - Internals

    private func transmit(_ pcm: Data) {
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + VoxtralRealtimeProtocol.maxAppendBytes, pcm.count)
            sendText(VoxtralRealtimeProtocol.audioAppend(pcm.subdata(in: offset..<end)))
            offset = end
        }
    }

    private func sendEnd() {
        guard !endSent else { return }
        endSent = true
        sendText(VoxtralRealtimeProtocol.audioFlush)
        sendText(VoxtralRealtimeProtocol.audioEnd)
    }

    private func sendText(_ text: String) {
        task?.send(text) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state != .closed else { return }
                self.fail(MistralAPI.mapURLError(error, while: "sending audio"))
            }
        }
    }

    private func receiveLoop(_ task: RealtimeSocket) {
        Task { @MainActor [weak self] in
            while true {
                let text: String
                do {
                    text = try await task.receive()
                } catch {
                    guard let self, self.state != .closed else { return }
                    self.fail(self.handshakeError(task: task) ?? MistralAPI.mapURLError(error, while: "receiving transcription"))
                    return
                }
                guard let self, self.state != .closed else { return }
                self.handle(VoxtralRealtimeProtocol.parse(text))
                if self.state == .closed { return }
            }
        }
    }

    /// WebSocket upgrade failures surface as a generic error; the HTTP status lives on the task.
    private func handshakeError(task: RealtimeSocket) -> TranscriptionError? {
        guard state == .connecting, let status = task.handshakeStatus else { return nil }
        return MistralAPI.error(forStatus: status, body: nil, headers: task.handshakeHeaders)
    }

    private func handle(_ event: VoxtralRealtimeProtocol.ServerEvent) {
        switch event {
        case .sessionCreated(let requestID):
            guard state == .connecting else { return }
            self.requestID = requestID
            connectTimeout?.cancel()
            // All settings must go in the first session.update: they lock when audio starts.
            sendText(VoxtralRealtimeProtocol.sessionUpdate(config: config, minSilenceMs: config.turnDetection ? minSilenceMs : nil))
            state = .ready
            onEvent(.ready)
            let queued = pending
            pending.removeAll()
            for chunk in queued { transmit(chunk) }
            if finishRequested { sendEnd() }
        case .sessionUpdated, .segment, .turnStart, .turnEagerEnd, .turnResume, .unknown:
            break
        case .textDelta(let delta):
            if !delta.isEmpty { onEvent(.textDelta(delta)) }
        case .language(let language):
            if !language.isEmpty { onEvent(.language(language)) }
        case .turnEnd:
            onEvent(.turnEnded)
        case .done(let text, let language):
            state = .closed
            onEvent(.done(text: text, language: language))
            task?.cancel()
            task = nil
        case .error(let message, let code):
            fail(VoxtralRealtimeProtocol.classify(message: message, code: code))
        }
    }

    private func fail(_ error: TranscriptionError) {
        guard state != .closed else { return }
        state = .closed
        connectTimeout?.cancel()
        pending.removeAll()
        task?.cancel()
        task = nil
        Log.transcription.error("Realtime session failed: \(error.userMessage, privacy: .public)")
        onEvent(.failed(error))
    }
}
