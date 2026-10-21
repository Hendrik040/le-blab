import Foundation
import Testing
@testable import LeBlabCore

@Suite("Voxtral realtime protocol")
struct ProtocolTests {
    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func sessionUpdateCarriesAllSettingsInOneMessage() throws {
        let config = TranscriptionConfig(model: MistralAPI.Models.realtime, language: "de",
                                         contextBias: ["CodeRabbit", " ", "Voxtral"], targetStreamingDelayMs: 480, turnDetection: true)
        let msg = try object(VoxtralRealtimeProtocol.sessionUpdate(config: config, minSilenceMs: 900))
        #expect(msg["type"] as? String == "session.update")
        let session = try #require(msg["session"] as? [String: Any])
        let format = try #require(session["audio_format"] as? [String: Any])
        #expect(format["encoding"] as? String == "pcm_s16le")
        #expect(format["sample_rate"] as? Int == 16_000)
        #expect(session["target_streaming_delay_ms"] as? Int == 480)
        #expect(session["language"] as? String == "de")
        #expect(session["context_bias"] as? [String] == ["CodeRabbit", "Voxtral"])
        #expect((session["turn_detection"] as? [String: Any])?["min_silence_ms"] as? Int == 900)
        #expect(session["diarize"] == nil, "diarization and turn detection can't share a session")
    }

    @Test func automaticLanguageOmitsLanguageField() throws {
        let config = TranscriptionConfig(model: "m", language: nil, contextBias: [], targetStreamingDelayMs: nil)
        let session = try #require(try object(VoxtralRealtimeProtocol.sessionUpdate(config: config))["session"] as? [String: Any])
        #expect(session["language"] == nil)
        #expect(session["context_bias"] == nil)
        #expect(session["turn_detection"] == nil)
    }

    @Test func audioAppendIsBase64PCM() throws {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
        let msg = try object(VoxtralRealtimeProtocol.audioAppend(pcm))
        #expect(msg["type"] as? String == "input_audio.append")
        #expect(Data(base64Encoded: msg["audio"] as? String ?? "") == pcm)
    }

    @Test func controlMessages() throws {
        #expect(try object(VoxtralRealtimeProtocol.audioFlush)["type"] as? String == "input_audio.flush")
        #expect(try object(VoxtralRealtimeProtocol.audioEnd)["type"] as? String == "input_audio.end")
    }

    @Test func parsesServerEvents() {
        typealias E = VoxtralRealtimeProtocol.ServerEvent
        #expect(VoxtralRealtimeProtocol.parse(#"{"type":"session.created","session":{"request_id":"r1","model":"m","audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}}"#)
                == E.sessionCreated(requestID: "r1"))
        #expect(VoxtralRealtimeProtocol.parse(#"{"type":"transcription.text.delta","text":" hello"}"#) == E.textDelta(" hello"))
        #expect(VoxtralRealtimeProtocol.parse(#"{"type":"transcription.language","audio_language":"de"}"#) == E.language("de"))
        #expect(VoxtralRealtimeProtocol.parse(#"{"type":"transcription.done","model":"m","text":"Hello world.","usage":{},"language":"en"}"#)
                == E.done(text: "Hello world.", language: "en"))
        #expect(VoxtralRealtimeProtocol.parse(#"{"type":"turn.end","time_s":1.2,"end_reason":"threshold"}"#) == E.turnEnd(reason: "threshold"))
    }

    @Test func parsesErrorShapesLikeTheSDK() {
        #expect(VoxtralRealtimeProtocol.parse(#"{"type":"error","error":{"message":"bad","code":1}}"#) == .error(message: "bad", code: 1))
        #expect(VoxtralRealtimeProtocol.parse(#"{"type":"error","error":{"message":{"detail":"nested"},"code":2}}"#) == .error(message: "nested", code: 2))
    }

    @Test func unknownAndInvalidMessagesAreTolerated() {
        #expect(VoxtralRealtimeProtocol.parse(#"{"type":"something.new"}"#) == .unknown(type: "something.new"))
        #expect(VoxtralRealtimeProtocol.parse("not json") == .unknown(type: nil))
    }

    @Test func errorClassification() {
        #expect(VoxtralRealtimeProtocol.classify(message: "Unauthorized", code: nil) == .unauthorized)
        #expect(VoxtralRealtimeProtocol.classify(message: "Rate limit exceeded", code: nil) == .rateLimited(retryAfter: nil))
        #expect(VoxtralRealtimeProtocol.classify(message: "boom", code: 503) == .server(status: 503, message: "boom"))
    }

    @Test func endpointsMatchTheOfficialSDK() {
        #expect(MistralAPI.realtimeURL(region: .global, model: "voxtral-mini-transcribe-realtime-3-0").absoluteString
                == "wss://api.mistral.ai/v1/audio/transcriptions/realtime?model=voxtral-mini-transcribe-realtime-3-0")
        #expect(MistralAPI.realtimeURL(region: .eu, model: "x").host == "api.eu.mistral.ai")
        #expect(MistralAPI.transcriptionsURL(region: .us).absoluteString == "https://api.us.mistral.ai/v1/audio/transcriptions")
    }

    @Test func httpStatusMapping() {
        #expect(MistralAPI.error(forStatus: 401, body: nil) == .unauthorized)
        #expect(MistralAPI.error(forStatus: 429, body: nil, headers: ["Retry-After": "3"]) == .rateLimited(retryAfter: 3))
        #expect(MistralAPI.error(forStatus: 400, body: Data(#"{"message":"nope"}"#.utf8)) == .badRequest("nope"))
        if case .server(503, _) = MistralAPI.error(forStatus: 503, body: nil) {} else { Issue.record("503 should map to server") }
        #expect(TranscriptionError.network("x").isTransient)
        #expect(!TranscriptionError.unauthorized.isTransient)
    }
}
