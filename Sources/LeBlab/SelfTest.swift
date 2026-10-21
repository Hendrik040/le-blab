import AppKit
import AVFoundation
import Foundation
import LeBlabCore

/// Plays pre-rendered PCM into the pipeline at real-time pace, standing in for the microphone.
final class SyntheticAudioSource: AudioCapturing {
    var onChunk: ((AudioChunk) -> Void)?
    var onInterrupted: ((AudioCaptureError) -> Void)?
    private let pcm: Data
    private var timer: Timer?
    private var offset = 0
    private(set) var finished = false

    init(pcm: Data) { self.pcm = pcm }

    func start(deviceUID: String?) throws {
        offset = 0
        finished = false
        let chunk = PCMFormat.bytesPerSecond / 20   // 50 ms
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.offset < self.pcm.count else {
                self.finished = true
                // Keep feeding silence until stopped, like a real mic.
                self.onChunk?(AudioChunk(pcm: Data(count: chunk), level: 0, voiced: false))
                return
            }
            let end = min(self.offset + chunk, self.pcm.count)
            self.onChunk?(AudioChunk(pcm: self.pcm.subdata(in: self.offset..<end), level: 0.6, voiced: true))
            self.offset = end
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// `--selftest "<phrase>" [--selftest-output <file>]`: synthesizes speech in memory, runs it through
/// shortcut-equivalent start/stop → Voxtral → formatter → insertion into the focused app, and
/// writes a timing report (no audio is written anywhere).
@MainActor
enum SelfTest {
    static func requestedPhrase() -> String? { value(after: "--selftest") }
    static func requestedOutputPath() -> String? { value(after: "--selftest-output") }

    static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func run(phrase: String, coordinator: AppCoordinator) async -> String {
        let repeats = max(1, Int(value(after: "--selftest-repeat") ?? "1") ?? 1)
        // Optional per-run formatting override; the saved preference is restored afterwards.
        let savedMode = coordinator.settings.formattingMode
        if let mode = value(after: "--selftest-formatting").flatMap(FormattingMode.init(rawValue:)) {
            coordinator.settings.formattingMode = mode
        }
        defer { coordinator.settings.formattingMode = savedMode }
        var reports: [String] = []
        for i in 0..<repeats {
            let report = await runOnce(phrase: phrase, coordinator: coordinator)
            reports.append(repeats > 1 ? "--- run \(i + 1)\n" + report : report)
            if report.contains("ABORT") || report.contains("FAIL") { break }
            if i + 1 < repeats { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        return reports.joined(separator: "\n")
    }

    static func runOnce(phrase: String, coordinator: AppCoordinator) async -> String {
        guard coordinator.keyState == .present else { return "SELFTEST FAIL: no API key (\(coordinator.keyState))" }
        // Safety: only type into the app the test expects, never into whatever the user is doing.
        if let target = value(after: "--selftest-target") {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            guard front == target else { return "SELFTEST ABORT: frontmost app is \(front), expected \(target)" }
        }
        let voice = value(after: "--selftest-voice")
        guard let pcm = await synthesize(phrase, voice: voice), !pcm.isEmpty else { return "SELFTEST FAIL: speech synthesis failed" }
        let source = SyntheticAudioSource(pcm: pcm)
        let controller = coordinator.controller
        var report = ""
        await coordinator.withSyntheticMicrophone(source) {
            controller.start()
            guard controller.isRecording else {
                report = "SELFTEST FAIL: could not start (\(controller.state))"
                return
            }
            while !source.finished { try? await Task.sleep(nanoseconds: 50_000_000) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            controller.stop()
            // Wait for the dictation to settle.
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if !controller.state.isActive { break }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let metrics = coordinator.diagnostics.recent.first
        let text = controller.lastTranscript ?? ""
        var readback = ""
        if CommandLine.arguments.contains("--selftest-readback") {
            try? await Task.sleep(nanoseconds: 700_000_000)   // let a paste land and the clipboard restore
            let value = AccessibilityReadback.focusedValue()
            readback = "\nfocused_app: \(AccessibilityReadback.focusedAppBundleID() ?? "-")\nfield_contains_text: \(value.map { $0.contains(text) } .map(String.init(describing:)) ?? "unreadable")\nfield_value: \(value ?? "-")"
        }
        report = report.isEmpty ? """
        SELFTEST \(metrics?.outcome == "inserted" ? "PASS" : "RESULT")
        outcome: \(metrics?.outcome ?? "none")
        insertion: \(metrics?.insertion ?? "-")
        formatting: \(metrics?.formatting ?? "-")
        source: \(metrics?.source?.rawValue ?? "-")
        audio_seconds: \(String(format: "%.2f", metrics?.audioSeconds ?? 0))
        connect_ms: \(ms(metrics?.connect))
        first_partial_ms: \(ms(metrics?.firstPartial))
        release_to_final_ms: \(ms(metrics?.releaseToFinal))
        formatting_ms: \(ms(metrics?.formattingTime))
        release_to_insert_ms: \(ms(metrics?.releaseToInsert))
        api_ms: \(ms(metrics?.apiLatency))
        text: \(text)\(readback)
        """ : report
        return report
    }

    private static func ms(_ t: TimeInterval?) -> String { t.map { String(Int(($0 * 1000).rounded())) } ?? "-" }

    /// Renders speech into memory and converts it to 16 kHz mono s16le.
    static func synthesize(_ text: String, voice: String?) async -> Data? {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        if let voice, let v = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == voice || $0.language == voice }) {
            utterance.voice = v
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCMFormat.sampleRate), channels: 1, interleaved: true)!
        var pcm = Data()
        var converter: AVAudioConverter?
        let result: Data = await withCheckedContinuation { continuation in
            var resumed = false
            synthesizer.write(utterance) { buffer in
                guard let buffer = buffer as? AVAudioPCMBuffer else { return }
                if buffer.frameLength == 0 {
                    if !resumed { resumed = true; continuation.resume(returning: pcm) }
                    return
                }
                if converter == nil { converter = AVAudioConverter(from: buffer.format, to: outFormat) }
                guard let converter else { return }
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 64
                guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
                var consumed = false
                _ = converter.convert(to: out, error: nil) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    consumed = true
                    status.pointee = .haveData
                    return buffer
                }
                if let samples = out.int16ChannelData?[0] {
                    pcm.append(Data(bytes: samples, count: Int(out.frameLength) * 2))
                }
            }
            // Safety net in case the synthesizer never signals completion.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                if !resumed { resumed = true; continuation.resume(returning: pcm) }
            }
        }
        // The synthesizer must outlive the asynchronous render.
        withExtendedLifetime(synthesizer) {}
        return result
    }
}
