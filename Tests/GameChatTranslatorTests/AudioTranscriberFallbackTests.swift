import Foundation
import Testing
@testable import GameChatTranslatorCore

@Suite("Audio transcriber fallback")
struct AudioTranscriberFallbackTests {
    private enum StubError: Error {
        case unavailable
    }

    private final class FailingTranscriber: AudioTranscribing {
        func transcribe(samples: [Float], sampleRate: Int) async throws -> TranscriptResult {
            throw StubError.unavailable
        }
    }

    private final class SuccessfulTranscriber: AudioTranscribing {
        func transcribe(samples: [Float], sampleRate: Int) async throws -> TranscriptResult {
            TranscriptResult(
                text: "Fallback active",
                detectedLanguage: "en",
                durationSeconds: Double(samples.count) / Double(sampleRate),
                averageTokenProbability: 1,
                tokenCount: 2
            )
        }
    }

    @Test("Cloud failure immediately uses local transcriber")
    func fallsBackAfterPrimaryFailure() async throws {
        let transcriber = FallbackAudioTranscriber(
            primary: FailingTranscriber(),
            fallback: SuccessfulTranscriber()
        )

        let result = try await transcriber.transcribe(samples: [0, 0, 0], sampleRate: 16_000)

        #expect(result.text == "Fallback active")
        #expect(result.detectedLanguage == "en")
    }
}
