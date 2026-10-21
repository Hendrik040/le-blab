import Foundation

/// Mistral API endpoints and model identifiers.
///
/// Every identifier here was verified against Mistral's Voxtral 3 docs
/// (docs.mistral.ai/capabilities/audio, /studio/audio/migrate-from-voxtral-2) and the
/// official `mistralai` Python SDK 3.3.0 (`mistralai/extra/realtime`).
public enum MistralAPI {
    public enum Region: String, CaseIterable, Codable, Sendable, Identifiable {
        case global, eu, us
        public var id: String { rawValue }

        /// Matches `SERVERS` in the official SDK's `sdkconfiguration.py`.
        public var baseURL: URL {
            switch self {
            case .global: return URL(string: "https://api.mistral.ai")!
            case .eu: return URL(string: "https://api.eu.mistral.ai")!
            case .us: return URL(string: "https://api.us.mistral.ai")!
            }
        }

        public var displayName: String {
            switch self {
            case .global: return "Global (api.mistral.ai)"
            case .eu: return "EU (api.eu.mistral.ai)"
            case .us: return "US (api.us.mistral.ai)"
            }
        }
    }

    public enum Models {
        /// Voxtral Mini Transcribe Realtime 3 — WebSocket streaming, default.
        public static let realtime = "voxtral-mini-transcribe-realtime-3-0"
        /// Voxtral Small Transcribe 3 — batch, higher accuracy ("transcription only at launch").
        public static let smallBatch = "voxtral-small-transcribe-3-0"
        /// Voxtral Mini Transcribe 3 — batch; used as a network-failure fallback.
        public static let miniBatch = "voxtral-mini-transcribe-3-0"
        /// Default text-cleanup model: Mistral Small 4, pinned (aliases can change behaviour without notice).
        /// Chosen by measurement: best instruction-following and lowest latency of the candidates.
        public static let defaultFormatter = "mistral-small-2603"
        public static let formatterChoices = ["mistral-small-2603", "mistral-small-latest", "ministral-8b-2512", "ministral-3b-2512"]
    }

    /// `wss://<host>/v1/audio/transcriptions/realtime?model=<id>` — path from the SDK's `_build_url`.
    public static func realtimeURL(region: Region, model: String) -> URL {
        var components = URLComponents(url: region.baseURL.appendingPathComponent("v1/audio/transcriptions/realtime"),
                                       resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url!
    }

    public static func transcriptionsURL(region: Region) -> URL {
        region.baseURL.appendingPathComponent("v1/audio/transcriptions")
    }

    public static func chatCompletionsURL(region: Region) -> URL {
        region.baseURL.appendingPathComponent("v1/chat/completions")
    }

    public static func modelsURL(region: Region) -> URL {
        region.baseURL.appendingPathComponent("v1/models")
    }

    /// One ephemeral session (no disk cache, no cookies) shared by every Mistral call, so TLS and
    /// HTTP/2 connections are reused across dictations instead of re-handshaking each time.
    public static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    private static let warmUpLock = NSLock()
    nonisolated(unsafe) private static var lastWarmUp: Date = .distantPast

    /// Opens (or keeps alive) the HTTPS connection used for formatting/batch calls while the user is
    /// still speaking. Body-less `HEAD`, no API key, no content — the response is ignored.
    public static func warmUp(region: Region) {
        let shouldRun: Bool = warmUpLock.withLock {
            guard Date().timeIntervalSince(lastWarmUp) > 15 else { return false }
            lastWarmUp = Date()
            return true
        }
        guard shouldRun else { return }
        var request = URLRequest(url: chatCompletionsURL(region: region), timeoutInterval: 5)
        request.httpMethod = "HEAD"
        sharedSession.dataTask(with: request).resume()
    }

    public static func authorize(_ request: inout URLRequest, apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("LeBlab/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
    }

    /// Maps an HTTP status (+ optional body) to a user-facing error.
    public static func error(forStatus status: Int, body: Data?, headers: [AnyHashable: Any] = [:]) -> TranscriptionError {
        let message = body.flatMap(extractMessage) ?? ""
        switch status {
        case 400, 422: return .badRequest(message.isEmpty ? "HTTP \(status)" : message)
        case 401: return .unauthorized
        case 403: return .forbidden(message)
        case 404: return .badRequest(message.isEmpty ? "Model or endpoint not found (404)." : message)
        case 408: return .timeout("waiting for Mistral")
        case 429:
            let retry = (headers["Retry-After"] as? String).flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retry)
        default: return .server(status: status, message: message)
        }
    }

    static func extractMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let s = String(data: data.prefix(300), encoding: .utf8)
            return s?.isEmpty == false ? s : nil
        }
        if let m = obj["message"] as? String { return m }
        if let d = obj["detail"] as? String { return d }
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let d = obj["detail"] as? [[String: Any]], let m = d.first?["msg"] as? String { return m }
        return nil
    }

    static func mapURLError(_ error: Error, while what: String) -> TranscriptionError {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return .timeout(what)
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorNotConnectedToInternet: return .network("You appear to be offline.")
            case NSURLErrorNetworkConnectionLost: return .network("Connection lost.")
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .network("Can't reach Mistral (DNS).")
            default: return .network(ns.localizedDescription)
            }
        }
        if ns.domain == NSPOSIXErrorDomain { return .network("Connection lost (\(ns.code)).") }
        return .network(ns.localizedDescription)
    }

    /// Lightweight key check: `GET /v1/models`. Never sends audio or text.
    public static func verifyKey(_ apiKey: String, region: Region, session: URLSession = .shared) async -> Result<[String], TranscriptionError> {
        var request = URLRequest(url: modelsURL(region: region), timeoutInterval: 10)
        authorize(&request, apiKey: apiKey)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .failure(error(forStatus: status, body: data)) }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let ids = (obj?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            return .success(ids)
        } catch {
            return .failure(mapURLError(error, while: "checking the API key"))
        }
    }
}
