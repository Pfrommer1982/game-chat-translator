import Foundation
import Testing
@testable import GameChatTranslatorCore

// MARK: - Tests

@Suite("Speaker Attribution Scoring")
struct SpeakerAttributionTests {

    // MARK: - Helpers

    private func makeProfile() -> GameProfile {
        GameProfile(
            appName: "TestGame",
            ocrFPS: 3.0,
            staleThreshold: 8.0,
            attributionConfidenceThreshold: 0.7,
            usernameRegex: ".*",
            speakerHoldTime: 2.0
        )
    }

    private let baseDate = Date(timeIntervalSince1970: 10_000)

    private func t(_ offset: Double) -> Date {
        baseDate.addingTimeInterval(offset)
    }

    /// Feed the tracker with periodic OCR updates between `from` and `to` (inclusive),
    /// simulating a 3 FPS camera seeing `speakers`.
    private func feedTracker(
        _ tracker: OCRSpeakerTracker,
        speakers: [(String, Double)],
        from start: Double,
        to end: Double,
        profile: GameProfile
    ) {
        var ts = start
        while ts <= end + 0.001 {
            tracker.update(detected: speakers.map { (username: $0.0, confidence: $0.1) },
                           at: t(ts),
                           profile: profile)
            ts += 1.0 / profile.ocrFPS   // simulate camera FPS
        }
    }

    // MARK: Scenario 1 — Normal speaker
    @Test("Normal speaker visible during speech → attributed with high confidence")
    func normalSpeaker() {
        let profile = makeProfile()
        let tracker = OCRSpeakerTracker()

        // Speaker visible 10–14 s; speech 10–14 s
        feedTracker(tracker, speakers: [("Raider101", 0.9)], from: 10.0, to: 14.0, profile: profile)
        // One empty frame right after speech
        tracker.update(detected: [], at: t(14.33), profile: profile)

        let states = tracker.getStatesOverlapping(from: t(10.0), to: t(14.0))
        let result = SpeakerAttributionScorer.attribute(
            speechStart: t(10.0), speechEnd: t(14.0), states: states, profile: profile)

        #expect(result.speakerName == "Raider101")
        #expect(result.confidence >= 0.7)
    }

    // MARK: Scenario 2 — Stale speaker (stuck > 8 s)
    @Test("Speaker stuck on screen for 45 s → scored as stale, returns Unknown")
    func staleSpeaker() {
        let profile = makeProfile()
        let tracker = OCRSpeakerTracker()

        // Speaker visible 0–45 s; speech 30–34 s
        feedTracker(tracker, speakers: [("RaiderStuck", 0.9)], from: 0.0, to: 45.0, profile: profile)

        let states = tracker.getStatesOverlapping(from: t(30.0), to: t(34.0))
        let result = SpeakerAttributionScorer.attribute(
            speechStart: t(30.0), speechEnd: t(34.0), states: states, profile: profile)

        // Continuous duration ≈ 30 s at speech start → well above staleThreshold (8 s)
        #expect(result.speakerName == "Unknown")
        #expect(result.confidence < 0.7)
    }

    // MARK: Scenario 3 — No speaker visible
    @Test("No speaker visible at all → Unknown with confidence 0")
    func noSpeaker() {
        let profile = makeProfile()
        let tracker = OCRSpeakerTracker()

        // No updates at all
        let states = tracker.getStatesOverlapping(from: t(10.0), to: t(14.0))
        let result = SpeakerAttributionScorer.attribute(
            speechStart: t(10.0), speechEnd: t(14.0), states: states, profile: profile)

        #expect(result.speakerName == "Unknown")
        #expect(result.confidence == 0.0)
    }

    // MARK: Scenario 4 — Multiple speakers visible simultaneously
    @Test("Two speakers both visible throughout speech → Multiple speakers")
    func multipleSpeakers() {
        let profile = makeProfile()
        let tracker = OCRSpeakerTracker()

        feedTracker(tracker,
                    speakers: [("RaiderA", 0.9), ("RaiderB", 0.9)],
                    from: 10.0, to: 14.0,
                    profile: profile)

        let states = tracker.getStatesOverlapping(from: t(10.0), to: t(14.0))
        let result = SpeakerAttributionScorer.attribute(
            speechStart: t(10.0), speechEnd: t(14.0), states: states, profile: profile)

        #expect(result.speakerName == "Multiple speakers")
    }

    // MARK: Scenario 5 — OCR flicker (hold-time tolerance)
    @Test("OCR flickers for 0.66 s within hold-time → speaker still attributed")
    func ocrFlicker() {
        let profile = makeProfile()
        let tracker = OCRSpeakerTracker()

        // 10–11 s: visible
        feedTracker(tracker, speakers: [("RaiderFlicker", 0.9)], from: 10.0, to: 11.0, profile: profile)
        // 11.33–11.66 s: flicker (2 empty frames, still within 2 s hold)
        tracker.update(detected: [], at: t(11.33), profile: profile)
        tracker.update(detected: [], at: t(11.66), profile: profile)
        // 12–14 s: visible again
        feedTracker(tracker, speakers: [("RaiderFlicker", 0.9)], from: 12.0, to: 14.0, profile: profile)

        let states = tracker.getStatesOverlapping(from: t(10.0), to: t(14.0))
        let result = SpeakerAttributionScorer.attribute(
            speechStart: t(10.0), speechEnd: t(14.0), states: states, profile: profile)

        #expect(result.speakerName == "RaiderFlicker")
        #expect(result.confidence >= 0.7)
    }

    // MARK: Scenario 6 — Speaker appears 1 s early
    @Test("Speaker appears 1 s before speech starts → still attributed")
    func speakerAppearsEarly() {
        let profile = makeProfile()
        let tracker = OCRSpeakerTracker()

        feedTracker(tracker, speakers: [("RaiderEarly", 0.9)], from: 9.0, to: 14.0, profile: profile)

        let states = tracker.getStatesOverlapping(from: t(10.0), to: t(14.0))
        let result = SpeakerAttributionScorer.attribute(
            speechStart: t(10.0), speechEnd: t(14.0), states: states, profile: profile)

        #expect(result.speakerName == "RaiderEarly")
        #expect(result.confidence >= 0.7)
    }

    // MARK: Scenario 7 — Speaker disappears 1.5 s after speech ends
    @Test("Speaker disappears 1.5 s after speech ends → still attributed")
    func speakerDisappearsLate() {
        let profile = makeProfile()
        let tracker = OCRSpeakerTracker()

        feedTracker(tracker, speakers: [("RaiderLate", 0.9)], from: 10.0, to: 15.5, profile: profile)

        let states = tracker.getStatesOverlapping(from: t(10.0), to: t(14.0))
        let result = SpeakerAttributionScorer.attribute(
            speechStart: t(10.0), speechEnd: t(14.0), states: states, profile: profile)

        #expect(result.speakerName == "RaiderLate")
        #expect(result.confidence >= 0.7)
    }
}
