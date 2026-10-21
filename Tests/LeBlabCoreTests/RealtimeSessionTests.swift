import Foundation
import Testing
@testable import LeBlabCore

@Suite("Realtime WebSocket session") @MainActor
struct RealtimeSessionTests {
    func make(_ socket: FakeSocket, key: String? = "test-key",
              events: @escaping @MainActor (StreamingTranscriptionEvent) -> Void) -> (StreamingTranscriptionSession, () -> URLRequest?) {
        var captured: URLRequest?
        let transcriber = VoxtralRealtimeTranscriber(region: { .eu }, apiKey: { key }) { request in
            captured = request
            return socket
        }
        let config = TranscriptionConfig(model: MistralAPI.Models.realtime, language: "en", contextBias: ["Voxtral"], targetStreamingDelayMs: 240)
        return (transcriber.makeSession(config: config, onEvent: events), { captured })
    }

    @Test func authenticatesAndTargetsTheRealtimeEndpoint() async {
        let socket = FakeSocket()
        let (session, request) = make(socket) { _ in }
        session.start()
        #expect(socket.resumed)
        #expect(request()?.url?.absoluteString == "wss://api.eu.mistral.ai/v1/audio/transcriptions/realtime?model=voxtral-mini-transcribe-realtime-3-0")
        #expect(request()?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        session.cancel()
    }

    @Test func buffersAudioUntilSessionCreatedThenSendsSettingsFirst() async {
        let socket = FakeSocket()
        var events: [StreamingTranscriptionEvent] = []
        let (session, _) = make(socket) { events.append($0) }
        session.start()
        session.send(Data([1, 2]))
        session.send(Data([3, 4]))
        #expect(socket.sent.isEmpty, "nothing may be sent before session.created")
        socket.push(#"{"type":"session.created","session":{"request_id":"r","model":"m","audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}}"#)
        await settle()
        #expect(socket.sentTypes == ["session.update", "input_audio.append", "input_audio.append"])
        #expect(socket.sentAudio == Data([1, 2, 3, 4]))
        #expect(events.first == .ready)
        session.send(Data([5]))
        session.finish()
        #expect(socket.sentTypes.suffix(3) == ["input_audio.append", "input_audio.flush", "input_audio.end"])
        session.cancel()
    }

    @Test func finishBeforeReadyIsDeferredNotLost() async {
        let socket = FakeSocket()
        let (session, _) = make(socket) { _ in }
        session.start()
        session.send(Data([9]))
        session.finish()
        socket.push(#"{"type":"session.created","session":{"request_id":"r","model":"m","audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}}"#)
        await settle()
        #expect(socket.sentTypes == ["session.update", "input_audio.append", "input_audio.flush", "input_audio.end"])
        session.cancel()
    }

    @Test func splitsLargeAudioIntoProtocolSizedMessages() async {
        let socket = FakeSocket()
        let (session, _) = make(socket) { _ in }
        session.start()
        socket.push(#"{"type":"session.created","session":{"request_id":"r","model":"m","audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}}"#)
        await settle()
        session.send(Data(count: VoxtralRealtimeProtocol.maxAppendBytes * 2 + 10))
        #expect(socket.sentTypes.filter { $0 == "input_audio.append" }.count == 3)
        session.cancel()
    }

    @Test func forwardsDeltasAndDone() async {
        let socket = FakeSocket()
        var events: [StreamingTranscriptionEvent] = []
        let (session, _) = make(socket) { events.append($0) }
        session.start()
        socket.push(#"{"type":"session.created","session":{"request_id":"r","model":"m","audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}}"#)
        socket.push(#"{"type":"transcription.language","audio_language":"en"}"#)
        socket.push(#"{"type":"transcription.text.delta","text":"Hello"}"#)
        socket.push(#"{"type":"transcription.text.delta","text":" world"}"#)
        socket.push(#"{"type":"transcription.done","model":"m","text":"Hello world.","usage":{},"language":"en"}"#)
        #expect(await waitUntil { events.count == 5 })
        #expect(events == [.ready, .language("en"), .textDelta("Hello"), .textDelta(" world"), .done(text: "Hello world.", language: "en")])
        #expect(socket.cancelled, "socket closes after transcription.done")
    }

    @Test func serverErrorBecomesTypedFailure() async {
        let socket = FakeSocket()
        var events: [StreamingTranscriptionEvent] = []
        let (session, _) = make(socket) { events.append($0) }
        session.start()
        socket.push(#"{"type":"error","error":{"message":"Invalid API key / unauthorized","code":3401}}"#)
        #expect(await waitUntil { !events.isEmpty })
        #expect(events == [.failed(.unauthorized)])
    }

    @Test func handshakeHTTPStatusIsReported() async {
        let socket = FakeSocket()
        socket.handshakeStatus = 429
        var events: [StreamingTranscriptionEvent] = []
        let (session, _) = make(socket) { events.append($0) }
        session.start()
        socket.fail(URLError(.badServerResponse))
        #expect(await waitUntil { !events.isEmpty })
        #expect(events == [.failed(.rateLimited(retryAfter: nil))])
    }

    @Test func missingKeyFailsWithoutConnecting() async {
        let socket = FakeSocket()
        var events: [StreamingTranscriptionEvent] = []
        let (session, _) = make(socket, key: nil) { events.append($0) }
        session.start()
        #expect(!socket.resumed)
        #expect(events == [.failed(.missingAPIKey)])
    }

    @Test func droppedConnectionIsTransient() async {
        let socket = FakeSocket()
        var events: [StreamingTranscriptionEvent] = []
        let (session, _) = make(socket) { events.append($0) }
        session.start()
        socket.push(#"{"type":"session.created","session":{"request_id":"r","model":"m","audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}}"#)
        await settle()
        socket.fail(URLError(.networkConnectionLost))
        #expect(await waitUntil { events.count == 2 })
        if case .failed(let e) = events.last { #expect(e.isTransient) } else { Issue.record("expected failure") }
    }
}
