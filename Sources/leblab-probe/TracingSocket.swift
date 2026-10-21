import Foundation
import LeBlabCore

/// Probe-only socket: timestamps every server message and can rewrite the end-of-audio sequence
/// (`--end-mode flush-end|end|flush`) to measure how the server finalizes.
@MainActor
final class TracingSocket: RealtimeSocket {
    private let task: URLSessionWebSocketTask
    let endMode: String
    var releasedAt: TimeInterval?
    var log: [(TimeInterval, String)] = []

    init(task: URLSessionWebSocketTask, endMode: String) {
        self.task = task
        self.endMode = endMode
    }

    func resume() { task.resume() }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        if text.contains("input_audio.flush") || text.contains("input_audio.end") {
            if releasedAt == nil { releasedAt = ProcessInfo.processInfo.systemUptime }
            if endMode == "end" && text.contains("flush") { completion(nil); return }
            if endMode == "flush" && text.contains("input_audio.end") { completion(nil); return }
        }
        task.send(.string(text), completionHandler: completion)
    }

    func receive() async throws -> String {
        let message = try await task.receive()
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(decoding: d, as: UTF8.self)
        @unknown default: text = ""
        }
        if let r = releasedAt {
            let type = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String ?? "?"
            log.append((ProcessInfo.processInfo.systemUptime - r, type))
        }
        return text
    }

    func cancel() { task.cancel(with: .normalClosure, reason: nil) }

    var handshakeStatus: Int? {
        guard let http = task.response as? HTTPURLResponse, http.statusCode != 101 else { return nil }
        return http.statusCode
    }
    var handshakeHeaders: [AnyHashable: Any] { [:] }
}
