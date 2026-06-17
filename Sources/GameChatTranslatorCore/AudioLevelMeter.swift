import Foundation

public struct AudioLevel {
    public let rms: Float
    public let dbFS: Float
}

public enum AudioLevelMeter {
    public static func measure(_ samples: [Float]) -> AudioLevel {
        guard !samples.isEmpty else {
            return AudioLevel(rms: 0, dbFS: -120)
        }

        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(samples.count))
        let clamped = max(rms, 0.000_001)
        return AudioLevel(rms: rms, dbFS: 20 * log10(clamped))
    }
}
