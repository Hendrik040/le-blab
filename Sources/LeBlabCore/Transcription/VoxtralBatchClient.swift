import Foundation

/// `POST /v1/audio/transcriptions` (multipart) — used for Voxtral Small Transcribe 3 (accuracy mode)
/// and as a fallback when a realtime stream dies. Audio is wrapped as WAV in memory and uploaded
/// directly; nothing is written to disk.
public struct VoxtralBatchTranscriber: BatchTranscriber {
    private let region: @Sendable () -> MistralAPI.Region
    private let apiKey: @Sendable () -> String?
    private let urlSession: URLSession
    private let timeout: TimeInterval

    public init(region: @escaping @Sendable () -> MistralAPI.Region,
                apiKey: @escaping @Sendable () -> String?,
                urlSession: URLSession = VoxtralRealtimeTranscriber.makeURLSession(),
                timeout: TimeInterval = 30) {
        self.region = region
        self.apiKey = apiKey
        self.urlSession = urlSession
        self.timeout = timeout
    }

    public func transcribe(pcm: Data, config: TranscriptionConfig) async throws -> BatchTranscript {
        guard let key = apiKey(), !key.isEmpty else { throw TranscriptionError.missingAPIKey }
        var form = MultipartForm()
        form.addField("model", config.model)
        if let language = config.language, !language.isEmpty { form.addField("language", language) }
        // The SDK serialises list fields as repeated form fields with the same name.
        for term in config.contextBias where !term.trimmingCharacters(in: .whitespaces).isEmpty {
            form.addField("context_bias", term)
        }
        form.addFile("file", filename: "dictation.wav", mimeType: "audio/wav", data: WAVEncoder.wav(fromPCM16Mono: pcm))

        var request = URLRequest(url: MistralAPI.transcriptionsURL(region: region()), timeoutInterval: timeout)
        request.httpMethod = "POST"
        MistralAPI.authorize(&request, apiKey: key)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        var body = form.finalize()
        defer { body.resetBytes(in: 0..<body.count) }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await urlSession.upload(for: request, from: body)
        } catch {
            throw MistralAPI.mapURLError(error, while: "uploading audio for transcription")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw MistralAPI.error(forStatus: status, body: data, headers: (response as? HTTPURLResponse)?.allHeaderFields ?? [:])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw TranscriptionError.protocolError("Transcription response had no text.")
        }
        return BatchTranscript(text: text, language: obj["language"] as? String)
    }
}

struct MultipartForm {
    let boundary = "leblab-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    mutating func finalize() -> Data {
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
