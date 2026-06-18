import Foundation

public enum RemoteAudioTranscriberError: Error, LocalizedError {
    case missingAPIKey(String)
    case invalidEndpoint(String)
    case unsupportedSampleRate(Int)
    case invalidResponse(String)
    case requestFailed(String, Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "A \(provider) API key is required."
        case .invalidEndpoint(let endpoint):
            return "Invalid audio API endpoint: \(endpoint)"
        case .unsupportedSampleRate(let sampleRate):
            return "Remote audio APIs expect 16 kHz PCM, got \(sampleRate) Hz."
        case .invalidResponse(let provider):
            return "\(provider) returned an invalid transcription response."
        case .requestFailed(let provider, let statusCode, let message):
            return "\(provider) request failed (\(statusCode)): \(message)"
        }
    }
}

/// Multipart WAV client for OpenAI-compatible transcription/translation APIs.
public final class RemoteAudioTranscriber: AudioTranscribing {
    private struct Response: Decodable {
        let text: String
        let language: String?
    }

    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String?
        }
        let error: APIError?
    }

    private let providerName: String
    private let apiKey: String
    private let endpoint: URL
    private let model: String
    private let inputLanguage: String?
    private let prompt: String?
    private let includeLanguageField: Bool
    private let responseFormat: String
    private let session: URLSession

    public init(
        providerName: String,
        apiKey: String,
        endpoint: String,
        model: String,
        inputLanguage: String = "auto",
        prompt: String? = nil,
        includeLanguageField: Bool = false,
        responseFormat: String = "json",
        timeoutSeconds: TimeInterval = 2.5
    ) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw RemoteAudioTranscriberError.missingAPIKey(providerName)
        }
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpointURL = URL(string: trimmedEndpoint),
              endpointURL.scheme == "https" || endpointURL.scheme == "http" else {
            throw RemoteAudioTranscriberError.invalidEndpoint(trimmedEndpoint)
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw RemoteAudioTranscriberError.invalidResponse(providerName)
        }

        self.providerName = providerName
        self.apiKey = trimmedKey
        self.endpoint = endpointURL
        self.model = trimmedModel
        self.inputLanguage = inputLanguage == "auto" ? nil : inputLanguage
        self.prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.includeLanguageField = includeLanguageField
        self.responseFormat = responseFormat

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.waitsForConnectivity = false
        configuration.networkServiceType = .responsiveData
        self.session = URLSession(configuration: configuration)
    }

    public func transcribe(samples: [Float], sampleRate: Int) async throws -> TranscriptResult {
        guard sampleRate == 16_000 else {
            throw RemoteAudioTranscriberError.unsupportedSampleRate(sampleRate)
        }

        let boundary = "GameChatTranslator-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary,
            wavData: Self.wavData(samples: samples, sampleRate: sampleRate)
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteAudioTranscriberError.invalidResponse(providerName)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            let responseText = String(data: data, encoding: .utf8)
            let message = envelope?.error?.message
                ?? responseText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw RemoteAudioTranscriberError.requestFailed(
                providerName,
                httpResponse.statusCode,
                message
            )
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw RemoteAudioTranscriberError.invalidResponse(providerName)
        }
        return TranscriptResult(
            text: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: decoded.language ?? inputLanguage,
            durationSeconds: Double(samples.count) / Double(sampleRate),
            averageTokenProbability: 0,
            tokenCount: 0
        )
    }

    private func multipartBody(boundary: String, wavData: Data) -> Data {
        var body = Data()
        body.appendFormField(name: "model", value: model, boundary: boundary)
        body.appendFormField(name: "response_format", value: responseFormat, boundary: boundary)
        body.appendFormField(name: "temperature", value: "0", boundary: boundary)
        if includeLanguageField, let inputLanguage {
            body.appendFormField(name: "language", value: inputLanguage, boundary: boundary)
        }
        if let prompt, !prompt.isEmpty {
            body.appendFormField(name: "prompt", value: prompt, boundary: boundary)
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"utterance.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func wavData(samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        var wav = Data(capacity: 44 + pcm.count)
        wav.append("RIFF")
        wav.appendLittleEndian(UInt32(36 + pcm.count))
        wav.append("WAVEfmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(UInt32(sampleRate * 2))
        wav.appendLittleEndian(UInt16(2))
        wav.appendLittleEndian(UInt16(16))
        wav.append("data")
        wav.appendLittleEndian(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

private extension String {
    var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(string.data(using: .utf8)!)
    }

    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
