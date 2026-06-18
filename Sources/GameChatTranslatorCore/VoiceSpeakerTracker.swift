import Foundation

/// A low-cost, session-only voice grouping result.
///
/// This intentionally produces anonymous labels. It is not biometric identity
/// recognition and no voice profile is persisted after the tracker is released.
public struct VoiceSpeakerAttribution: Sendable, Equatable {
    public let speakerLabel: String
    public let speakerState: SpeakerDisplayState
    public let confidence: Double

    public init(
        speakerLabel: String,
        speakerState: SpeakerDisplayState,
        confidence: Double
    ) {
        self.speakerLabel = speakerLabel
        self.speakerState = speakerState
        self.confidence = confidence
    }

    public static let unknown = VoiceSpeakerAttribution(
        speakerLabel: "?",
        speakerState: .lowConfidence,
        confidence: 0
    )
}

struct VoiceSpeakerSample: Sendable {
    var pitch: Double
    var zeroCrossingRate: Double
    var highFrequencyRatio: Double
    var spectrum: [Double]
    var voicedRatio: Double
}

/// Groups short utterances by acoustic similarity without adding network latency.
/// Profiles only live for the current listening session.
public final class VoiceSpeakerTracker: @unchecked Sendable {
    private struct Profile {
        let label: String
        var voicePrint: VoiceSpeakerSample
        var observations: Int
    }

    private let lock = NSLock()
    private var profiles: [Profile] = []
    private let maxSpeakers: Int

    public init(maxSpeakers: Int = 4) {
        self.maxSpeakers = max(1, maxSpeakers)
    }

    public func reset() {
        lock.withLock {
            profiles.removeAll(keepingCapacity: true)
        }
    }

    public func attribute(
        samples: [Float],
        sampleRate: Int = 16_000
    ) -> VoiceSpeakerAttribution {
        attribute(sample: prepare(samples: samples, sampleRate: sampleRate))
    }

    func prepare(samples: [Float], sampleRate: Int = 16_000) -> VoiceSpeakerSample? {
        Self.makeVoicePrint(samples: samples, sampleRate: sampleRate)
    }

    func attribute(sample voicePrint: VoiceSpeakerSample?) -> VoiceSpeakerAttribution {
        guard let voicePrint else {
            return .unknown
        }

        return lock.withLock {
            if profiles.isEmpty {
                return addProfile(for: voicePrint)
            }

            let ranked = profiles.enumerated()
                .map { (index: $0.offset, distance: Self.distance(voicePrint, $0.element.voicePrint)) }
                .sorted { $0.distance < $1.distance }
            guard let nearest = ranked.first else { return .unknown }

            let createThreshold = voicePrint.voicedRatio >= 0.20 ? 0.43 : 0.50
            if nearest.distance > createThreshold, profiles.count < maxSpeakers {
                return addProfile(for: voicePrint)
            }

            let matchThreshold = 0.58
            guard nearest.distance <= matchThreshold else { return .unknown }

            if ranked.count > 1 {
                let margin = ranked[1].distance - nearest.distance
                if margin < 0.035, nearest.distance > 0.22 {
                    return .unknown
                }
            }

            updateProfile(at: nearest.index, with: voicePrint)
            let confidence = min(0.96, max(0.45, 1.0 - nearest.distance / matchThreshold))
            return VoiceSpeakerAttribution(
                speakerLabel: profiles[nearest.index].label,
                speakerState: confidence < 0.55 ? .lowConfidence : .identified,
                confidence: confidence
            )
        }
    }

    private func addProfile(for voicePrint: VoiceSpeakerSample) -> VoiceSpeakerAttribution {
        let label = "P\(profiles.count + 1)"
        profiles.append(Profile(label: label, voicePrint: voicePrint, observations: 1))
        return VoiceSpeakerAttribution(
            speakerLabel: label,
            speakerState: .identified,
            confidence: 0.72
        )
    }

    private func updateProfile(at index: Int, with voicePrint: VoiceSpeakerSample) {
        let observations = profiles[index].observations
        let blend = min(0.25, 1.0 / Double(observations + 1))
        var current = profiles[index].voicePrint
        current.pitch = Self.blend(current.pitch, voicePrint.pitch, amount: blend)
        current.zeroCrossingRate = Self.blend(
            current.zeroCrossingRate,
            voicePrint.zeroCrossingRate,
            amount: blend
        )
        current.highFrequencyRatio = Self.blend(
            current.highFrequencyRatio,
            voicePrint.highFrequencyRatio,
            amount: blend
        )
        current.voicedRatio = Self.blend(current.voicedRatio, voicePrint.voicedRatio, amount: blend)
        current.spectrum = zip(current.spectrum, voicePrint.spectrum).map {
            Self.blend($0, $1, amount: blend)
        }
        profiles[index].voicePrint = current
        profiles[index].observations += 1
    }

    private static func blend(_ lhs: Double, _ rhs: Double, amount: Double) -> Double {
        lhs * (1 - amount) + rhs * amount
    }

    private static func distance(_ lhs: VoiceSpeakerSample, _ rhs: VoiceSpeakerSample) -> Double {
        let pitchDistance = min(1.5, abs(lhs.pitch - rhs.pitch) / 0.55)
        let crossingDistance = min(1.5, abs(lhs.zeroCrossingRate - rhs.zeroCrossingRate) / 0.15)
        let highFrequencyDistance = min(
            1.5,
            abs(lhs.highFrequencyRatio - rhs.highFrequencyRatio) / 0.30
        )

        let dot = zip(lhs.spectrum, rhs.spectrum).reduce(0.0) { $0 + $1.0 * $1.1 }
        let lhsMagnitude = sqrt(lhs.spectrum.reduce(0.0) { $0 + $1 * $1 })
        let rhsMagnitude = sqrt(rhs.spectrum.reduce(0.0) { $0 + $1 * $1 })
        let cosineSimilarity = dot / max(0.000_001, lhsMagnitude * rhsMagnitude)
        let spectrumDistance = min(1.5, max(0, 1 - cosineSimilarity) * 2.2)

        let pitchWeight = min(lhs.voicedRatio, rhs.voicedRatio) >= 0.20 ? 0.40 : 0.18
        let remainingWeight = 1 - pitchWeight
        return pitchDistance * pitchWeight
            + crossingDistance * remainingWeight * 0.22
            + highFrequencyDistance * remainingWeight * 0.23
            + spectrumDistance * remainingWeight * 0.55
    }

    private static func makeVoicePrint(samples: [Float], sampleRate: Int) -> VoiceSpeakerSample? {
        guard sampleRate > 0, samples.count >= Int(Double(sampleRate) * 0.28) else { return nil }

        let frameLength = max(160, Int(Double(sampleRate) * 0.030))
        let hopLength = max(80, Int(Double(sampleRate) * 0.015))
        guard samples.count >= frameLength else { return nil }

        var frameRMSValues: [Double] = []
        var frameStarts: [Int] = []
        var start = 0
        while start + frameLength <= samples.count {
            let frame = samples[start..<(start + frameLength)]
            let energy = frame.reduce(0.0) { $0 + Double($1 * $1) }
            frameRMSValues.append(sqrt(energy / Double(frameLength)))
            frameStarts.append(start)
            start += hopLength
        }

        guard let peakRMS = frameRMSValues.max(), peakRMS >= 0.001 else { return nil }
        let activeThreshold = max(0.0015, peakRMS * 0.28)
        let activeIndices = frameRMSValues.indices.filter { frameRMSValues[$0] >= activeThreshold }
        guard activeIndices.count >= 4 else { return nil }

        let frequencies = [100.0, 160.0, 240.0, 360.0, 540.0, 800.0, 1_200.0, 1_800.0, 2_600.0, 3_600.0]
            .filter { $0 < Double(sampleRate) * 0.48 }
        var spectrum = Array(repeating: 0.0, count: frequencies.count)
        var pitchSum = 0.0
        var pitchedFrames = 0
        var crossingSum = 0.0
        var highFrequencySum = 0.0

        for frameIndex in activeIndices {
            let frameStart = frameStarts[frameIndex]
            var frame = samples[frameStart..<(frameStart + frameLength)].map(Double.init)
            let mean = frame.reduce(0, +) / Double(frame.count)
            for index in frame.indices {
                let window = 0.54 - 0.46 * cos(2 * .pi * Double(index) / Double(frame.count - 1))
                frame[index] = (frame[index] - mean) * window
            }

            let energy = max(0.000_000_001, frame.reduce(0.0) { $0 + $1 * $1 })
            let scale = sqrt(Double(frame.count) / energy)
            for index in frame.indices {
                frame[index] *= scale
            }

            var crossings = 0
            var differenceEnergy = 0.0
            for index in 1..<frame.count {
                if (frame[index] >= 0) != (frame[index - 1] >= 0) {
                    crossings += 1
                }
                let difference = frame[index] - frame[index - 1]
                differenceEnergy += difference * difference
            }
            crossingSum += Double(crossings) / Double(frame.count - 1)
            highFrequencySum += min(1, differenceEnergy / max(0.000_001, energy * scale * scale * 2))

            if let pitch = estimatedPitch(frame: frame, sampleRate: sampleRate) {
                pitchSum += log2(pitch / 160.0)
                pitchedFrames += 1
            }

            for (index, frequency) in frequencies.enumerated() {
                spectrum[index] += goertzelPower(frame: frame, frequency: frequency, sampleRate: sampleRate)
            }
        }

        let frameCount = Double(activeIndices.count)
        let spectrumTotal = max(0.000_001, spectrum.reduce(0, +))
        spectrum = spectrum.map { sqrt($0 / spectrumTotal) }
        let pitch = pitchedFrames > 0 ? pitchSum / Double(pitchedFrames) : 0

        return VoiceSpeakerSample(
            pitch: pitch,
            zeroCrossingRate: crossingSum / frameCount,
            highFrequencyRatio: highFrequencySum / frameCount,
            spectrum: spectrum,
            voicedRatio: Double(pitchedFrames) / frameCount
        )
    }

    private static func estimatedPitch(frame: [Double], sampleRate: Int) -> Double? {
        let minimumLag = max(1, sampleRate / 350)
        let maximumLag = min(frame.count / 2, sampleRate / 70)
        guard minimumLag < maximumLag else { return nil }

        var bestLag = 0
        var bestCorrelation = 0.0
        for lag in minimumLag...maximumLag {
            var product = 0.0
            var leftEnergy = 0.0
            var rightEnergy = 0.0
            for index in lag..<frame.count {
                let left = frame[index]
                let right = frame[index - lag]
                product += left * right
                leftEnergy += left * left
                rightEnergy += right * right
            }
            let correlation = product / sqrt(max(0.000_001, leftEnergy * rightEnergy))
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }

        guard bestCorrelation >= 0.34, bestLag > 0 else { return nil }
        return Double(sampleRate) / Double(bestLag)
    }

    private static func goertzelPower(frame: [Double], frequency: Double, sampleRate: Int) -> Double {
        let coefficient = 2 * cos(2 * .pi * frequency / Double(sampleRate))
        var previous = 0.0
        var previousPrevious = 0.0
        for sample in frame {
            let current = sample + coefficient * previous - previousPrevious
            previousPrevious = previous
            previous = current
        }
        return max(0, previousPrevious * previousPrevious + previous * previous - coefficient * previous * previousPrevious)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
