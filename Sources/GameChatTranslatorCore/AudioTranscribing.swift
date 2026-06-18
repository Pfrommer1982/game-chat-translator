import Foundation

public protocol AudioTranscribing: AnyObject {
    func transcribe(samples: [Float], sampleRate: Int) async throws -> TranscriptResult
}

public final class FallbackAudioTranscriber: AudioTranscribing {
    private let primary: any AudioTranscribing
    private let fallback: any AudioTranscribing

    public init(primary: any AudioTranscribing, fallback: any AudioTranscribing) {
        self.primary = primary
        self.fallback = fallback
    }

    public func transcribe(samples: [Float], sampleRate: Int) async throws -> TranscriptResult {
        do {
            return try await primary.transcribe(samples: samples, sampleRate: sampleRate)
        } catch {
            return try await fallback.transcribe(samples: samples, sampleRate: sampleRate)
        }
    }
}
