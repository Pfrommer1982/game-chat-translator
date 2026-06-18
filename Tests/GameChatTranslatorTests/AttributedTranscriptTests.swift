import Foundation
import Testing
@testable import GameChatTranslatorCore

// MARK: - AttributedTranscript factory tests

@Suite("AttributedTranscript")
struct AttributedTranscriptTests {

    private func makeProfile(threshold: Double = 0.7, stale: Double = 8.0) -> GameProfile {
        GameProfile(
            appName: "TestGame",
            ocrFPS: 3.0,
            staleThreshold: stale,
            attributionConfidenceThreshold: threshold,
            usernameRegex: ".*",
            speakerHoldTime: 2.0
        )
    }

    // MARK: - .from factory → SpeakerDisplayState mapping

    @Test("Identified result → .identified state")
    func identifiedMapping() {
        let result = AttributionResult(speakerName: "Raider101", confidence: 0.9, reason: "good match")
        let transcript = AttributedTranscript.from(
            result: result, text: "hello", detectedLanguage: "en",
            startTime: 0, endTime: 1, profile: makeProfile()
        )
        #expect(transcript.speakerState == .identified)
        #expect(transcript.speakerLabel == "Raider101")
        #expect(!transcript.isSystemMessage)
    }

    @Test("Unknown result, confidence 0 → .unknown state")
    func unknownMapping() {
        let result = AttributionResult(speakerName: "Unknown", confidence: 0.0, reason: "no candidate")
        let transcript = AttributedTranscript.from(
            result: result, text: "hello", detectedLanguage: "en",
            startTime: 0, endTime: 1, profile: makeProfile()
        )
        #expect(transcript.speakerState == .unknown)
    }

    @Test("Unknown result with hadStaleCandidate → .stale state")
    func staleMapping() {
        let result = AttributionResult(speakerName: "Unknown", confidence: 0.0, reason: "stale")
        let transcript = AttributedTranscript.from(
            result: result, text: "hi", detectedLanguage: "en",
            startTime: 0, endTime: 1, profile: makeProfile(),
            hadStaleCandidate: true
        )
        #expect(transcript.speakerState == .stale)
    }

    @Test("Unknown result with low-but-non-zero confidence → .lowConfidence state")
    func lowConfidenceMapping() {
        let result = AttributionResult(speakerName: "Unknown", confidence: 0.4, reason: "weak")
        let transcript = AttributedTranscript.from(
            result: result, text: "hi", detectedLanguage: "en",
            startTime: 0, endTime: 1, profile: makeProfile(threshold: 0.7)
        )
        #expect(transcript.speakerState == .lowConfidence)
    }

    @Test("Multiple speakers result → .multiple state")
    func multipleMapping() {
        let result = AttributionResult(speakerName: "Multiple speakers", confidence: 1.0, reason: "overlap")
        let transcript = AttributedTranscript.from(
            result: result, text: "chaos", detectedLanguage: "en",
            startTime: 0, endTime: 1, profile: makeProfile()
        )
        #expect(transcript.speakerState == .multiple)
    }

    // MARK: - .system factory

    @Test("System factory produces system message")
    func systemFactory() {
        let t = AttributedTranscript.system("Model loaded.")
        #expect(t.isSystemMessage)
        #expect(t.speakerState == .unknown)
        #expect(t.text == "Model loaded.")
        #expect(t.attributionConfidence == 0)
    }

    // MARK: - .unattributed factory

    @Test("Unattributed factory produces unknown non-system message")
    func unattributedFactory() {
        let t = AttributedTranscript.unattributed(
            text: "hello world",
            detectedLanguage: "en",
            startTime: 1000,
            endTime: 1004
        )
        #expect(!t.isSystemMessage)
        #expect(t.speakerState == .unknown)
        #expect(t.speakerLabel == "")
        #expect(t.text == "hello world")
    }

    // MARK: - Identifiable

    @Test("Each transcript gets a unique ID")
    func uniqueIDs() {
        let a = AttributedTranscript.system("a")
        let b = AttributedTranscript.system("b")
        #expect(a.id != b.id)
    }
}

// MARK: - SpeakerDisplayState determinism

@Suite("SpeakerDisplayState")
struct SpeakerDisplayStateTests {

    @Test("SpeakerDisplayState is Equatable")
    func equatable() {
        #expect(SpeakerDisplayState.identified == .identified)
        #expect(SpeakerDisplayState.unknown != .multiple)
    }
}
