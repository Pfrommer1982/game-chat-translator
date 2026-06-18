import SwiftUI
import GameChatTranslatorCore

/// Provides deterministic, accessible colors for speaker attribution display.
///
/// Rules:
/// - `.identified`    → hue derived from speaker name hash (stable across the session)
/// - `.unknown`       → system gray (never gets a random color)
/// - `.multiple`      → orange / warning
/// - `.stale`         → muted amber-gray
/// - `.lowConfidence` → gray at 55% opacity
struct SpeakerColorHelper {

    // MARK: - Public API

    /// Primary badge background color for a given transcript.
    static func badgeColor(for transcript: AttributedTranscript) -> Color {
        badgeColor(label: transcript.speakerLabel, state: transcript.speakerState)
    }

    static func badgeColor(label: String, state: SpeakerDisplayState) -> Color {
        switch state {
        case .identified:
            return hashColor(for: label)
        case .unknown:
            return Color(nsColor: .systemGray).opacity(0.7)
        case .multiple:
            return Color.orange
        case .stale:
            return Color(hue: 0.12, saturation: 0.35, brightness: 0.60)
        case .lowConfidence:
            if anonymousSpeakerIndex(from: label) != nil {
                return hashColor(for: label).opacity(0.62)
            }
            return Color(nsColor: .systemGray).opacity(0.55)
        }
    }

    /// Text color on top of the badge (contrasted against the background).
    static func badgeForeground(for transcript: AttributedTranscript) -> Color {
        badgeForeground(state: transcript.speakerState)
    }

    static func badgeForeground(state: SpeakerDisplayState) -> Color {
        switch state {
        case .identified:
            return .white
        case .unknown, .lowConfidence:
            return Color(nsColor: .secondaryLabelColor)
        case .multiple:
            return .white
        case .stale:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    /// Border / accent color for the left rail on a transcript row.
    static func accentColor(for transcript: AttributedTranscript) -> Color {
        badgeColor(for: transcript)
    }

    // MARK: - Deterministic name → hue

    /// Generates a stable `Color` from a speaker name by hashing it to a hue.
    /// The same name always returns the same color within (and across) sessions.
    static func hashColor(for name: String) -> Color {
        if let speakerIndex = anonymousSpeakerIndex(from: name) {
            let palette: [Color] = [
                Color(red: 0.12, green: 0.48, blue: 0.96),
                Color(red: 0.10, green: 0.68, blue: 0.38),
                Color(red: 0.72, green: 0.31, blue: 0.84),
                Color(red: 0.95, green: 0.46, blue: 0.12)
            ]
            return palette[(speakerIndex - 1) % palette.count]
        }

        // Use DJB2-style hash for distribution across the hue wheel
        var hash: UInt32 = 5381
        for char in name.unicodeScalars {
            hash = (hash &* 31) &+ char.value
        }

        // Map hash to 0–360 hue, keeping saturation/brightness premium-looking
        let hue = Double(hash % 360) / 360.0
        // Avoid yellow-green range (0.18–0.28) which is hard to read; nudge it
        let adjustedHue = (hue >= 0.18 && hue < 0.28) ? hue + 0.10 : hue

        return Color(hue: adjustedHue, saturation: 0.68, brightness: 0.82)
    }

    private static func anonymousSpeakerIndex(from label: String) -> Int? {
        guard label.count >= 2,
              label.first?.uppercased() == "P",
              let index = Int(label.dropFirst()),
              index > 0 else { return nil }
        return index
    }
}
