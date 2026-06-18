import Foundation

public final class GroqTranscriber: AudioTranscribing {
    private let transcriber: RemoteAudioTranscriber

    public init(
        apiKey: String,
        language: String = "auto",
        model: String = "whisper-large-v3-turbo",
        timeoutSeconds: TimeInterval = 1.8
    ) throws {
        transcriber = try RemoteAudioTranscriber(
            providerName: "Groq",
            apiKey: apiKey,
            endpoint: "https://api.groq.com/openai/v1/audio/translations",
            model: model,
            inputLanguage: language,
            prompt: "Translate spoken game chat into concise, natural English. Preserve names, commands, numbers, and urgency. Do not explain.",
            includeLanguageField: language != "auto",
            responseFormat: "verbose_json",
            timeoutSeconds: timeoutSeconds
        )
    }

    public func transcribe(samples: [Float], sampleRate: Int) async throws -> TranscriptResult {
        try await transcriber.transcribe(samples: samples, sampleRate: sampleRate)
    }
}
