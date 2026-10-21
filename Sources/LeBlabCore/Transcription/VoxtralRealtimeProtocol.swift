import Foundation

/// Wire format of Mistral's realtime transcription WebSocket.
///
/// Source of truth: the official `mistralai` SDK 3.3.0 —
/// `extra/realtime/connection.py` (`_MESSAGE_MODELS`, `send_audio`, `flush_audio`, `end_audio`)
/// and the generated models `realtimetranscription*.py`, `transcriptionstream*.py`, `turndetection*.py`.
public enum VoxtralRealtimeProtocol {
    /// Max decoded bytes per `input_audio.append` (documented on `RealtimeTranscriptionInputAudioAppend.audio`).
    public static let maxAppendBytes = 262_144

    // MARK: Client → server

    public static func sessionUpdate(config: TranscriptionConfig, minSilenceMs: Int? = nil) -> String {
        var session: [String: Any] = [
            "audio_format": ["encoding": "pcm_s16le", "sample_rate": PCMFormat.sampleRate],
        ]
        if let delay = config.targetStreamingDelayMs { session["target_streaming_delay_ms"] = delay }
        if let language = config.language, !language.isEmpty { session["language"] = language }
        let bias = config.contextBias.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !bias.isEmpty { session["context_bias"] = bias }
        if config.turnDetection {
            var turn: [String: Any] = [:]
            if let minSilenceMs { turn["min_silence_ms"] = minSilenceMs }
            session["turn_detection"] = turn
        }
        return json(["type": "session.update", "session": session])
    }

    public static func audioAppend(_ pcm: Data) -> String {
        json(["type": "input_audio.append", "audio": pcm.base64EncodedString()])
    }

    public static let audioFlush = #"{"type":"input_audio.flush"}"#
    public static let audioEnd = #"{"type":"input_audio.end"}"#

    // MARK: Server → client

    public enum ServerEvent: Equatable {
        case sessionCreated(requestID: String?)
        case sessionUpdated
        case textDelta(String)
        case segment(String)
        case language(String)
        case done(text: String, language: String?)
        case turnStart, turnEagerEnd, turnResume
        case turnEnd(reason: String?)
        case error(message: String, code: Int?)
        case unknown(type: String?)
    }

    public static func parse(_ text: String) -> ServerEvent {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return .unknown(type: nil)
        }
        switch type {
        case "session.created":
            let session = obj["session"] as? [String: Any]
            return .sessionCreated(requestID: session?["request_id"] as? String)
        case "session.updated":
            return .sessionUpdated
        case "transcription.text.delta":
            return .textDelta(obj["text"] as? String ?? "")
        case "transcription.segment":
            return .segment(obj["text"] as? String ?? "")
        case "transcription.language":
            return .language(obj["audio_language"] as? String ?? "")
        case "transcription.done":
            return .done(text: obj["text"] as? String ?? "", language: obj["language"] as? String)
        case "turn.start": return .turnStart
        case "turn.eager_end": return .turnEagerEnd
        case "turn.resume": return .turnResume
        case "turn.end": return .turnEnd(reason: obj["end_reason"] as? String)
        case "error":
            let err = obj["error"] as? [String: Any]
            return .error(message: errorMessage(err?["message"]), code: err?["code"] as? Int)
        default:
            return .unknown(type: type)
        }
    }

    /// Mirrors `_extract_error_message` in the SDK: message may be a string or `{detail: …}`.
    static func errorMessage(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let d = raw as? [String: Any] {
            if let detail = d["detail"] as? String { return detail }
            if let data = try? JSONSerialization.data(withJSONObject: d), let s = String(data: data, encoding: .utf8) { return s }
        }
        return "Realtime transcription error"
    }

    /// Classifies a server `error` event. Realtime errors carry an internal code, not an HTTP status,
    /// so we fall back to message heuristics for the common cases.
    public static func classify(message: String, code: Int?) -> TranscriptionError {
        let lower = message.lowercased()
        if lower.contains("unauthor") || lower.contains("api key") || code == 401 { return .unauthorized }
        if lower.contains("rate limit") || lower.contains("too many") || code == 429 { return .rateLimited(retryAfter: nil) }
        if lower.contains("forbidden") || lower.contains("not allowed") || code == 403 { return .forbidden(message) }
        if lower.contains("timeout") || lower.contains("timed out") { return .timeout("waiting for the transcription server") }
        if let code, (500...599).contains(code) { return .server(status: code, message: message) }
        return .protocolError(message)
    }

    private static func json(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
