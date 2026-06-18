import Foundation

/// Describes how the UI should present a speaker attribution result.
public enum SpeakerDisplayState: Equatable, Sendable {
    /// A known speaker was identified with sufficient confidence.
    case identified
    /// No speaker could be attributed (no OCR data or confidence too low).
    case unknown
    /// Two or more speakers overlapped during the utterance.
    case multiple
    /// The speaker has been on screen so long their attribution is unreliable.
    case stale
    /// Attribution returned a candidate but confidence is below the threshold.
    case lowConfidence
}

public struct AttributionResult {
    public let speakerName: String
    public let confidence: Double
    public let reason: String
    
    public init(speakerName: String, confidence: Double, reason: String) {
        self.speakerName = speakerName
        self.confidence = confidence
        self.reason = reason
    }
}

public final class SpeakerAttributionScorer {
    
    /// Attributes a transcript segment to a speaker based on overlapping timelines.
    /// - Parameters:
    ///   - speechStart: The timestamp when speech/VAD started
    ///   - speechEnd: The timestamp when speech/VAD ended
    ///   - states: Overlapping speaker states retrieved from the tracker
    ///   - profile: The active game profile containing timing settings
    public static func attribute(
        speechStart: Date,
        speechEnd: Date,
        states: [SpeakerState],
        profile: GameProfile
    ) -> AttributionResult {
        let speechDuration = speechEnd.timeIntervalSince(speechStart)
        guard speechDuration > 0 else {
            return AttributionResult(speakerName: "Unknown", confidence: 0.0, reason: "Speech duration is zero")
        }
        
        guard !states.isEmpty else {
            return AttributionResult(speakerName: "Unknown", confidence: 0.0, reason: "No speaker visible in selected region")
        }
        
        var candidates: [(state: SpeakerState, score: Double, details: String)] = []
        
        for state in states {
            // 1. Calculate Overlap
            let stateStart = state.appearedAt
            let stateEnd = state.disappearedAt ?? speechEnd
            
            let overlapStart = max(stateStart, speechStart)
            let overlapEnd = min(stateEnd, speechEnd)
            let overlapDuration = max(0.0, overlapEnd.timeIntervalSince(overlapStart))
            let overlapRatio = overlapDuration / speechDuration
            
            // 2. Proximity to speech start
            let startBonus: Double
            if stateStart <= speechStart {
                startBonus = 1.0 // Already visible when speech started
            } else {
                let dtStart = stateStart.timeIntervalSince(speechStart)
                startBonus = dtStart <= profile.speakerHoldTime
                    ? (1.0 - (dtStart / profile.speakerHoldTime))
                    : 0.0
            }
            
            // 3. Proximity to speech end
            let endBonus: Double
            if stateEnd >= speechEnd {
                endBonus = 1.0 // Still visible when speech ended
            } else {
                let dtEnd = speechEnd.timeIntervalSince(stateEnd)
                endBonus = dtEnd <= profile.speakerHoldTime
                    ? (1.0 - (dtEnd / profile.speakerHoldTime))
                    : 0.0
            }
            
            // Calculate combined score
            var score = (overlapRatio * 0.5) + (startBonus * 0.25) + (endBonus * 0.25)
            
            // 4. Stale speaker check
            // A speaker is stale if their continuous visible duration exceeds the threshold
            // during the speech segment.
            let isStale = state.continuousVisibleDuration > profile.staleThreshold
            
            var details = String(
                format: "overlap: %.1f%%, start proximity: %.1f%%, end proximity: %.1f%%",
                overlapRatio * 100,
                startBonus * 100,
                endBonus * 100
            )
            
            if isStale {
                score = 0.0
                details += " (stale speaker penalty)"
            }
            
            candidates.append((state: state, score: score, details: details))
        }
        
        // Sort candidates by score descending
        candidates.sort(by: { $0.score > $1.score })
        
        // Check if multiple speakers overlap significantly with the speech segment.
        // We define "multiple speakers overlap" if there are 2 or more candidates with a score >= 0.5
        // or if they both have an overlap ratio > 0.3.
        let highOverlapCandidates = candidates.filter { c in
            let stateStart = c.state.appearedAt
            let stateEnd = c.state.disappearedAt ?? Date()
            let overlapStart = max(stateStart, speechStart)
            let overlapEnd = min(stateEnd, speechEnd)
            let overlapDuration = max(0.0, overlapEnd.timeIntervalSince(overlapStart))
            let overlapRatio = overlapDuration / speechDuration
            
            return overlapRatio > 0.3 && c.score > 0.2
        }
        
        if highOverlapCandidates.count >= 2 {
            let names = highOverlapCandidates.map { $0.state.username }.joined(separator: ", ")
            return AttributionResult(
                speakerName: "Multiple speakers",
                confidence: 1.0,
                reason: "Multiple speakers overlap: \(names)"
            )
        }
        
        guard let best = candidates.first else {
            return AttributionResult(speakerName: "Unknown", confidence: 0.0, reason: "No matching candidates")
        }
        
        let reason = "Candidate: \(best.state.username), Score: \(String(format: "%.2f", best.score)) (\(best.details))"
        
        if best.score >= profile.attributionConfidenceThreshold {
            return AttributionResult(
                speakerName: best.state.username,
                confidence: best.score,
                reason: reason
            )
        } else {
            return AttributionResult(
                speakerName: "Unknown", // Requirement 11: If confidence < 0.7, show "Unknown: translated text"
                confidence: best.score,
                reason: reason
            )
        }
    }
}
