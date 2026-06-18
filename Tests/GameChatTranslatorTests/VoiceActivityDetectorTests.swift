import Foundation
import Testing
@testable import GameChatTranslatorCore

@Suite("Voice activity detector")
struct VoiceActivityDetectorTests {
    @Test("Deep compressed speech is not rejected")
    func detectsLowFrequencyVoice() {
        let sampleRate = 16_000
        let samples = (0..<Int(0.30 * Double(sampleRate))).map { index in
            Float(sin(2 * Double.pi * 85 * Double(index) / Double(sampleRate)) * 0.025)
        }

        let result = VoiceActivityDetector.analyze(
            samples: samples,
            sampleRate: sampleRate,
            rmsThreshold: 0.003
        )

        #expect(result.hasLikelySpeech)
        #expect(result.speechFrameCount >= 2)
    }
}
