import AVFoundation
import Foundation
import LeBlabCore

// Developer probe: drives LeBlabCore's real transcription/formatting code paths against the
// Mistral API with an audio file instead of the microphone, and prints timings.
//
//   MISTRAL_API_KEY=… leblab-probe models
//   MISTRAL_API_KEY=… leblab-probe realtime speech.aiff [--delay 480] [--lang de] [--fast] [--turns] [--region eu]
//   MISTRAL_API_KEY=… leblab-probe batch speech.aiff [--model voxtral-small-transcribe-3-0]
//   MISTRAL_API_KEY=… leblab-probe format "um so hey david …" [--model mistral-small-latest]
//
// The key is read from the environment only; the probe never prints it.

@main
@MainActor
struct Probe {
    static var args = Array(CommandLine.arguments.dropFirst())

    static func main() async {
        guard let command = args.first else { usage(); exit(2) }
        guard let key = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"], !key.isEmpty else {
            fputs("MISTRAL_API_KEY is not set\n", stderr); exit(2)
        }
        let region = MistralAPI.Region(rawValue: option("--region") ?? "global") ?? .global
        switch command {
        case "models": await models(key: key, region: region)
        case "realtime": await realtime(key: key, region: region)
        case "batch": await batchCommand(key: key, region: region)
        case "format": await format(key: key, region: region)
        default: usage(); exit(2)
        }
    }

    static func usage() {
        print("usage: leblab-probe models|realtime <file>|batch <file>|format <text> [options]")
    }

    static func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func flag(_ name: String) -> Bool { args.contains(name) }

    static func ms(_ t: TimeInterval) -> String { String(format: "%.0f ms", t * 1000) }

    // MARK: models

    static func models(key: String, region: MistralAPI.Region) async {
        switch await MistralAPI.verifyKey(key, region: region) {
        case .success(let ids):
            print("Key OK on \(region.displayName). \(ids.count) models.")
            for id in ids.sorted() where id.contains("voxtral") || id.contains("small") || id.contains("ministral") {
                print("  \(id)")
            }
        case .failure(let error):
            print("FAILED: \(error.userMessage)"); exit(1)
        }
    }

    // MARK: realtime

    static func realtime(key: String, region: MistralAPI.Region) async {
        guard args.count >= 2, let pcm = loadPCM(args[1]) else { fputs("can't read audio\n", stderr); exit(1) }
        let delay = Int(option("--delay") ?? "480") ?? 480
        let paced = !flag("--fast")
        let config = TranscriptionConfig(model: option("--model") ?? MistralAPI.Models.realtime, language: option("--lang"),
                                         contextBias: (option("--bias") ?? "CodeRabbit,DevRel,GitHub,Mistral,Voxtral")
                                            .split(separator: ",").map(String.init),
                                         targetStreamingDelayMs: delay, turnDetection: flag("--turns"))
        let urlSession = VoxtralRealtimeTranscriber.makeURLSession()
        var sockets: [TracingSocket] = []
        let endMode = option("--end-mode") ?? "flush-end"
        let streaming = VoxtralRealtimeTranscriber(region: { region }, apiKey: { key }) { request in
            let socket = TracingSocket(task: urlSession.webSocketTask(with: request), endMode: endMode)
            sockets.append(socket)
            return socket
        }
        let batch = VoxtralBatchTranscriber(region: { region }, apiKey: { key })
        let session = TranscriptionSession(options: SessionOptions(realtime: config, finalTimeout: 4), streaming: streaming, batch: batch)
        let t0 = ProcessInfo.processInfo.systemUptime
        func now() -> String { ms(ProcessInfo.processInfo.systemUptime - t0) }
        var partials = 0
        let trace = flag("--trace")
        var releasedAt: TimeInterval?
        session.onPartial = { text in
            partials += 1
            if trace, let r = releasedAt {
                print("  +\(ms(ProcessInfo.processInfo.systemUptime - r)) after release: …\(text.suffix(40))")
            } else if partials <= 3 || partials % 10 == 0 { print("[\(now())] partial: \(text.suffix(90))") }
        }
        session.onLanguage = { print("[\(now())] language: \($0)") }
        session.onTurnEnded = { print("[\(now())] turn.end") }
        session.onReconnect = { print("[\(now())] reconnect #\($0)") }
        var verification: Bool?
        session.onLateVerification = { verification = $0 }
        session.timeline.mark(\.pressed)
        session.start()

        // Feed 50 ms chunks, paced like a microphone unless --fast.
        let chunkBytes = PCMFormat.bytesPerSecond / 20
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkBytes, pcm.count)
            session.append(AudioChunk(pcm: pcm.subdata(in: offset..<end), level: 0.5, voiced: true))
            offset = end
            if paced { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        print("[\(now())] audio sent (\(String(format: "%.1f", PCMFormat.duration(ofBytes: pcm.count))) s) — finishing")
        releasedAt = ProcessInfo.processInfo.systemUptime
        let result = await session.finish()
        let t = session.timeline
        switch result {
        case .success(let r):
            print("\nFINAL (\(r.source.rawValue), early=\(session.finalizedEarly), lang=\(r.language ?? "?")):\n\(r.text)\n")
            if session.finalizedEarly {
                for _ in 0..<40 where verification == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
                print("late transcription.done matched early text: \(verification.map { "\($0)" } ?? "no done received")")
            }
        case .failure(let e):
            print("\nFAILED: \(e.userMessage)\n")
        }
        func span(_ a: TimeInterval?, _ b: TimeInterval?) -> String {
            guard let a, let b else { return "—" }
            return ms(b - a)
        }
        if flag("--trace"), let socket = sockets.last {
            let summary = socket.log.map { "\($0.1)@\(Int($0.0 * 1000))" }.joined(separator: " ")
            print("server events after end (\(endMode)): \(summary)")
        }
        print("connect (press→session ready): \(span(t.pressed, t.streamReady))")
        print("time to first partial:          \(span(t.pressed, t.firstPartial))")
        print("release → final transcript:     \(span(t.released, t.finalTranscript))")
    }

    // MARK: batch

    static func batchCommand(key: String, region: MistralAPI.Region) async {
        guard args.count >= 2, let pcm = loadPCM(args[1]) else { fputs("can't read audio\n", stderr); exit(1) }
        let model = option("--model") ?? MistralAPI.Models.smallBatch
        let batch = VoxtralBatchTranscriber(region: { region }, apiKey: { key })
        let config = TranscriptionConfig(model: model, language: option("--lang"),
                                         contextBias: ["CodeRabbit", "DevRel", "GitHub", "Mistral", "Voxtral"])
        let t0 = Date()
        do {
            let r = try await batch.transcribe(pcm: pcm, config: config)
            print("[\(model)] \(ms(Date().timeIntervalSince(t0))) lang=\(r.language ?? "?")\n\(r.text)")
        } catch {
            print("FAILED: \((error as? TranscriptionError)?.userMessage ?? "\(error)")"); exit(1)
        }
    }

    // MARK: format

    static func format(key: String, region: MistralAPI.Region) async {
        guard args.count >= 2 else { usage(); exit(2) }
        let text = args[1]
        let model = option("--model") ?? MistralAPI.Models.defaultFormatter
        let client = MistralChatClient(region: { region }, apiKey: { key })
        let formatter = SmartFormatter(client: client, model: model, vocabulary: VocabularyEntry.defaults, timeout: 10)
        let t0 = Date()
        let result = await formatter.format(text, language: option("--lang"))
        print("[\(model)] \(ms(Date().timeIntervalSince(t0))) llm=\(result.usedLanguageModel) fallback=\(result.fallbackReason ?? "-")")
        print(result.text)
    }

    // MARK: audio

    static func loadPCM(_ path: String) -> Data? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let inFormat = file.processingFormat
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCMFormat.sampleRate), channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try? file.read(into: inBuffer)
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * outFormat.sampleRate / inFormat.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var done = false
        _ = converter.convert(to: out, error: nil) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true
            status.pointee = .haveData
            return inBuffer
        }
        guard let samples = out.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(out.frameLength) * 2)
    }
}
