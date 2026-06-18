import Foundation

/// A transcript segment with resolved speaker attribution, ready for display.
///
/// Built inside `TranscriptionScheduler` after attribution scoring; the UI
/// layer **must not** perform any attribution logic itself.
public struct AttributedTranscript: Identifiable, Sendable, Equatable {
    public let id: UUID

    /// Human-readable speaker label ("Raider101", "Unknown", "Multiple speakers").
    public let speakerLabel: String

    /// Categorised state for rendering decisions (color, icon, opacity).
    public let speakerState: SpeakerDisplayState

    /// Score from `SpeakerAttributionScorer` (0–1). 0 when OCR is off.
    public let attributionConfidence: Double

    /// The raw transcribed text from speech recognition.
    public let originalText: String

    /// The translated text, if available. Nil means the original is all we have.
    public let translatedText: String?

    /// BCP-47 language code detected by Whisper, if available.
    public let detectedLanguage: String?

    /// Epoch-relative start of the utterance.
    public let startTime: TimeInterval

    /// Epoch-relative end of the utterance.
    public let endTime: TimeInterval

    /// Whether this is a system/status message rather than a real utterance.
    public let isSystemMessage: Bool

    /// Whether this row is a live partial display that may be replaced.
    public let isPartial: Bool

    public var displayText: String {
        translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? translatedText!
            : originalText
    }

    public var text: String { displayText }

    public init(
        id: UUID = UUID(),
        speakerLabel: String,
        speakerState: SpeakerDisplayState,
        attributionConfidence: Double,
        originalText: String,
        translatedText: String? = nil,
        detectedLanguage: String? = nil,
        isPartial: Bool = false,
        startTime: TimeInterval = 0,
        endTime: TimeInterval = 0,
        isSystemMessage: Bool = false
    ) {
        self.id = id
        self.speakerLabel = speakerLabel
        self.speakerState = speakerState
        self.attributionConfidence = attributionConfidence
        self.originalText = originalText
        self.translatedText = translatedText
        self.detectedLanguage = detectedLanguage
        self.isPartial = isPartial
        self.startTime = startTime
        self.endTime = endTime
        self.isSystemMessage = isSystemMessage
    }

    public init(
        id: UUID = UUID(),
        speakerLabel: String,
        speakerState: SpeakerDisplayState,
        attributionConfidence: Double,
        text: String,
        detectedLanguage: String? = nil,
        startTime: TimeInterval = 0,
        endTime: TimeInterval = 0,
        isSystemMessage: Bool = false
    ) {
        self.init(
            id: id,
            speakerLabel: speakerLabel,
            speakerState: speakerState,
            attributionConfidence: attributionConfidence,
            originalText: text,
            detectedLanguage: detectedLanguage,
            startTime: startTime,
            endTime: endTime,
            isSystemMessage: isSystemMessage
        )
    }

    // MARK: - Convenience factories

    /// A plain system/status message (no speaker attribution).
    public static func system(_ message: String) -> AttributedTranscript {
        AttributedTranscript(
            speakerLabel: "",
            speakerState: .unknown,
            attributionConfidence: 0,
            originalText: message,
            isSystemMessage: true
        )
    }

    /// An utterance attributed by the scorer.
    public static func from(
        result: AttributionResult,
        originalText: String,
        translatedText: String? = nil,
        detectedLanguage: String?,
        isPartial: Bool = false,
        startTime: TimeInterval,
        endTime: TimeInterval,
        profile: GameProfile,
        hadStaleCandidate: Bool = false
    ) -> AttributedTranscript {
        let state: SpeakerDisplayState
        switch result.speakerName {
        case "Multiple speakers":
            state = .multiple
        case "Unknown":
            if hadStaleCandidate {
                state = .stale
            } else if result.confidence > 0 && result.confidence < profile.attributionConfidenceThreshold {
                state = .lowConfidence
            } else {
                state = .unknown
            }
        default:
            state = .identified
        }

        return AttributedTranscript(
            speakerLabel: result.speakerName,
            speakerState: state,
            attributionConfidence: result.confidence,
            originalText: originalText,
            translatedText: translatedText,
            detectedLanguage: detectedLanguage,
            isPartial: isPartial,
            startTime: startTime,
            endTime: endTime,
            isSystemMessage: false
        )
    }

    public static func from(
        result: AttributionResult,
        text: String,
        detectedLanguage: String?,
        startTime: TimeInterval,
        endTime: TimeInterval,
        profile: GameProfile,
        hadStaleCandidate: Bool = false
    ) -> AttributedTranscript {
        from(
            result: result,
            originalText: text,
            detectedLanguage: detectedLanguage,
            startTime: startTime,
            endTime: endTime,
            profile: profile,
            hadStaleCandidate: hadStaleCandidate
        )
    }

    /// An utterance without OCR attribution (OCR disabled).
    public static func unattributed(
        originalText: String,
        translatedText: String? = nil,
        detectedLanguage: String?,
        isPartial: Bool = false,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> AttributedTranscript {
        AttributedTranscript(
            speakerLabel: "",
            speakerState: .unknown,
            attributionConfidence: 0,
            originalText: originalText,
            translatedText: translatedText,
            detectedLanguage: detectedLanguage,
            isPartial: isPartial,
            startTime: startTime,
            endTime: endTime,
            isSystemMessage: false
        )
    }

    public static func unattributed(
        text: String,
        detectedLanguage: String?,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> AttributedTranscript {
        unattributed(
            originalText: text,
            detectedLanguage: detectedLanguage,
            startTime: startTime,
            endTime: endTime
        )
    }

    /// An utterance grouped by its anonymous, session-only voice print.
    public static func voiceAttributed(
        _ attribution: VoiceSpeakerAttribution,
        originalText: String,
        translatedText: String? = nil,
        detectedLanguage: String?,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> AttributedTranscript {
        AttributedTranscript(
            speakerLabel: attribution.speakerLabel,
            speakerState: attribution.speakerState,
            attributionConfidence: attribution.confidence,
            originalText: originalText,
            translatedText: translatedText,
            detectedLanguage: detectedLanguage,
            startTime: startTime,
            endTime: endTime,
            isSystemMessage: false
        )
    }
}
