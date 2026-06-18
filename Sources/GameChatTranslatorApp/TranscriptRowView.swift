import SwiftUI
import GameChatTranslatorCore

struct TranscriptRowView: View {
    let item: TranscriptDisplayItem
    let text: String
    let showOriginalText: Bool
    let debugMetadata: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let speakerLabel = item.speakerLabel {
                SpeakerLabelView(label: speakerLabel, state: item.speakerState)
                    .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(text)
                        .font(.system(size: 17, weight: .medium))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if let language = item.detectedLanguage {
                        Text(language.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.35)))
                    }
                }

                if showOriginalText,
                   let originalText = item.originalText,
                   originalText.caseInsensitiveCompare(text) != .orderedSame {
                    Text(originalText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let debugMetadata {
                    Text(debugMetadata)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

struct SpeakerLabelView: View {
    let label: String
    let state: SpeakerDisplayState

    private var color: Color {
        SpeakerColorHelper.badgeColor(label: label, state: state)
    }

    private var displayLabel: String {
        if state == .lowConfidence, label != "?", !label.hasSuffix("?") {
            return "\(label)?"
        }
        return label
    }

    var body: some View {
        Text(displayLabel)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(state == .identified ? Color.white : Color.primary)
            .frame(minWidth: 25, minHeight: 18)
            .padding(.horizontal, 3)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Speaker \(displayLabel)")
    }
}
