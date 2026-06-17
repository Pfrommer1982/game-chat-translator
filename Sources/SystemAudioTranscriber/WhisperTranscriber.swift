import CWhisperBridge
import Foundation

struct TranscriptResult {
    let text: String
    let detectedLanguage: String?
    let durationSeconds: Double
    let averageTokenProbability: Float
    let tokenCount: Int
}

enum WhisperTranscriberError: Error, LocalizedError {
    case modelNotFound(String)
    case failedToLoadModel(String)
    case unsupportedSampleRate(Int)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Whisper model not found at \(path)."
        case .failedToLoadModel(let path):
            return "Could not load whisper.cpp model at \(path)."
        case .unsupportedSampleRate(let sampleRate):
            return "WhisperTranscriber expects 16 kHz PCM, got \(sampleRate) Hz."
        }
    }
}

final class WhisperTranscriber {
    private let bridge: OpaquePointer

    init(
        modelPath: String,
        language: String = "auto",
        translateToEnglish: Bool = false,
        realtimeMode: Bool = false,
        threadCount: Int = 4
    ) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperTranscriberError.modelNotFound(modelPath)
        }

        guard let bridge = whisper_bridge_create(modelPath) else {
            throw WhisperTranscriberError.failedToLoadModel(modelPath)
        }

        self.bridge = bridge
        whisper_bridge_set_language(bridge, language == "auto" ? nil : language)
        whisper_bridge_set_translate_to_english(bridge, translateToEnglish)
        whisper_bridge_set_realtime_mode(bridge, realtimeMode)
        whisper_bridge_set_thread_count(bridge, Int32(threadCount))
    }

    deinit {
        whisper_bridge_free(bridge)
    }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> TranscriptResult {
        guard sampleRate == 16_000 else {
            throw WhisperTranscriberError.unsupportedSampleRate(sampleRate)
        }

        return await Task.detached(priority: .userInitiated) {
            var mutableSamples = samples
            defer {
                mutableSamples.withUnsafeMutableBufferPointer { buffer in
                    buffer.initialize(repeating: 0)
                }
            }

            let result = mutableSamples.withUnsafeBufferPointer { buffer in
                whisper_bridge_transcribe(self.bridge, buffer.baseAddress, Int32(buffer.count), Int32(sampleRate))
            }
            defer {
                whisper_bridge_result_free(result)
            }

            let text = result.text.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let language = result.language.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }

            return TranscriptResult(
                text: text,
                detectedLanguage: language,
                durationSeconds: Double(samples.count) / Double(sampleRate),
                averageTokenProbability: result.average_token_probability,
                tokenCount: Int(result.token_count)
            )
        }.value
    }
}
