import Foundation
import Testing
@testable import GameChatTranslatorCore

@Suite("Voice speaker tracker")
struct VoiceSpeakerTrackerTests {
    @Test("Similar utterances keep the same anonymous label")
    func stableLabel() {
        let tracker = VoiceSpeakerTracker()
        let first = tracker.attribute(samples: voice(fundamental: 118, phase: 0.0))
        let second = tracker.attribute(samples: voice(fundamental: 118, phase: 0.8))

        #expect(first.speakerLabel == "P1")
        #expect(second.speakerLabel == "P1")
        #expect(second.speakerState == .identified)
    }

    @Test("Acoustically different voices receive different labels")
    func differentLabels() {
        let tracker = VoiceSpeakerTracker()
        let lowVoice = tracker.attribute(samples: voice(fundamental: 105, phase: 0.2))
        let highVoice = tracker.attribute(samples: voice(fundamental: 245, phase: 0.4))

        #expect(lowVoice.speakerLabel == "P1")
        #expect(highVoice.speakerLabel == "P2")
    }

    @Test("Very short audio stays unknown")
    func shortAudioIsUnknown() {
        let tracker = VoiceSpeakerTracker()
        let result = tracker.attribute(samples: Array(repeating: 0.1, count: 1_000))

        #expect(result.speakerLabel == "?")
        #expect(result.speakerState == .lowConfidence)
    }

    @Test("Reset starts a new anonymous session")
    func resetStartsNewSession() {
        let tracker = VoiceSpeakerTracker()
        _ = tracker.attribute(samples: voice(fundamental: 110))
        _ = tracker.attribute(samples: voice(fundamental: 250))
        tracker.reset()

        let firstAfterReset = tracker.attribute(samples: voice(fundamental: 250))
        #expect(firstAfterReset.speakerLabel == "P1")
    }

    private func voice(fundamental: Double, phase: Double = 0) -> [Float] {
        let sampleRate = 16_000.0
        let count = Int(sampleRate * 0.85)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let envelope = min(1, time / 0.04) * min(1, (0.85 - time) / 0.05)
            let fundamentalTone = sin(2 * .pi * fundamental * time + phase)
            let secondHarmonic = 0.32 * sin(2 * .pi * fundamental * 2 * time + phase * 0.5)
            let thirdHarmonic = 0.12 * sin(2 * .pi * fundamental * 3 * time)
            return Float((fundamentalTone + secondHarmonic + thirdHarmonic) * envelope * 0.16)
        }
    }
}
