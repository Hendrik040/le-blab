import Foundation
import LeBlabCore

/// `--measure-mic <file>`: how long from "start" until the first audio buffer arrives, with a cold
/// engine versus a pre-warmed one. Each run captures well under a second and discards the audio.
@MainActor
enum MicStartProbe {
    static func run(capture: AudioCaptureManager, deviceUID: String?, output: String) async {
        var lines: [String] = []
        for warm in [false, true, false, true, false, true] {
            if warm { capture.prewarm(deviceUID: deviceUID); try? await Task.sleep(nanoseconds: 300_000_000) }
            var firstChunk: Double?
            let t0 = ProcessInfo.processInfo.systemUptime
            capture.onChunk = { _ in if firstChunk == nil { firstChunk = ProcessInfo.processInfo.systemUptime } }
            do { try capture.start(deviceUID: deviceUID) } catch { lines.append("error: \(error)"); continue }
            let started = capture.lastStartDuration
            for _ in 0..<100 where firstChunk == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
            capture.stop()
            let first = firstChunk.map { Int(($0 - t0) * 1000) } ?? -1
            lines.append("\(warm ? "warm" : "cold") start=\(Int(started * 1000))ms first_audio=\(first)ms")
            // Make the next cold run really cold.
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !warm { capture.discardPreparedForTesting() }
        }
        try? lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }
}
