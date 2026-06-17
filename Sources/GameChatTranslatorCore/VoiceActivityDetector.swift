import Foundation

struct VoiceActivityResult {
    let hasLikelySpeech: Bool
    let speechFrameRatio: Float
    let speechFrameCount: Int
    let totalFrameCount: Int
}

enum VoiceActivityDetector {
    static func analyze(
        samples: [Float],
        sampleRate: Int,
        rmsThreshold: Float
    ) -> VoiceActivityResult {
        let frameSize = max(1, Int(0.03 * Double(sampleRate)))
        let hopSize = max(1, Int(0.015 * Double(sampleRate)))
        guard samples.count >= frameSize else {
            return VoiceActivityResult(hasLikelySpeech: false, speechFrameRatio: 0, speechFrameCount: 0, totalFrameCount: 0)
        }

        var speechFrames = 0
        var totalFrames = 0
        var start = 0

        while start + frameSize <= samples.count {
            let frame = samples[start..<(start + frameSize)]
            let rms = frameRMS(frame)
            let zcr = zeroCrossingRate(frame)

            // Speech usually has moderate zero-crossing structure. Pure silence, low rumbles,
            // many explosions, and clipped transients tend to fall outside this window.
            if rms >= rmsThreshold && zcr >= 0.015 && zcr <= 0.22 {
                speechFrames += 1
            }

            totalFrames += 1
            start += hopSize
        }

        let ratio = totalFrames > 0 ? Float(speechFrames) / Float(totalFrames) : 0
        return VoiceActivityResult(
            hasLikelySpeech: speechFrames >= 3 && ratio >= 0.12,
            speechFrameRatio: ratio,
            speechFrameCount: speechFrames,
            totalFrameCount: totalFrames
        )
    }

    private static func frameRMS(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in frame {
            sum += sample * sample
        }
        return sqrt(sum / Float(frame.count))
    }

    private static func zeroCrossingRate(_ frame: ArraySlice<Float>) -> Float {
        guard frame.count > 1 else { return 0 }
        var crossings = 0
        var previous = frame[frame.startIndex]

        for sample in frame.dropFirst() {
            if (previous >= 0 && sample < 0) || (previous < 0 && sample >= 0) {
                crossings += 1
            }
            previous = sample
        }

        return Float(crossings) / Float(frame.count - 1)
    }
}

