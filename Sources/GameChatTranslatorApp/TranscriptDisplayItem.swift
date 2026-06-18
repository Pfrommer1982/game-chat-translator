import Foundation
import GameChatTranslatorCore

struct TranscriptDisplayItem: Identifiable, Equatable {
    let id: UUID
    let translatedText: String?
    let originalText: String?
    let detectedLanguage: String?
    let speakerLabel: String?
    let speakerState: SpeakerDisplayState
    let speakerConfidence: Double
    let isPartial: Bool
    let createdAt: Date
    let latencyMs: Int?

    init(transcript: AttributedTranscript, receivedAt: Date = Date()) {
        id = transcript.id
        translatedText = transcript.translatedText?.nilIfBlank
        originalText = transcript.originalText.nilIfBlank
        detectedLanguage = transcript.detectedLanguage?.nilIfBlank?.isoLanguageCode
        speakerLabel = transcript.speakerLabel.nilIfBlank
        speakerState = transcript.speakerState
        speakerConfidence = transcript.attributionConfidence
        isPartial = transcript.isPartial

        if transcript.endTime > 0 {
            let transcriptDate = Date(timeIntervalSinceReferenceDate: transcript.endTime)
            createdAt = transcriptDate
            latencyMs = max(0, Int(receivedAt.timeIntervalSince(transcriptDate) * 1_000))
        } else {
            createdAt = receivedAt
            latencyMs = nil
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isoLanguageCode: String {
        Locale(identifier: self).language.languageCode?.identifier.uppercased() ?? uppercased()
    }
}
