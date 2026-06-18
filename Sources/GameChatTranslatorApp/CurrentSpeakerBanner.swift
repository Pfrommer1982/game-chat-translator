import SwiftUI
import GameChatTranslatorCore

/// A compact panel displayed above the transcript list showing who is
/// currently speaking. Pulses briefly when the active speaker changes.
struct CurrentSpeakerView: View {
    let speakerLabel: String
    let speakerState: SpeakerDisplayState
    let attributionConfidence: Double
    let isOCRActive: Bool
    let highlightToken: UUID

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOCRActive ? .green : .secondary)

            Text("Current speaker")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            speakerPill
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .onChange(of: highlightToken) { _ in
            triggerPulse()
        }
    }

    // MARK: - Speaker pill

    private var speakerPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(speakerColor)
                .frame(width: 7, height: 7)
            Text(displayLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            speakerColor.opacity(0.15),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .stroke(speakerColor.opacity(0.4), lineWidth: 1)
        )
        .accessibilityLabel("Current speaker: \(displayLabel)")
    }

    // MARK: - Helpers

    private var displayLabel: String {
        guard isOCRActive else { return "OCR off" }
        switch speakerState {
        case .identified:
            return speakerLabel
        case .unknown:
            return "Unknown"
        case .multiple:
            return "Multiple speakers"
        case .stale:
            return speakerLabel.isEmpty ? "Stale" : speakerLabel
        case .lowConfidence:
            return speakerLabel.isEmpty ? "Unknown ?" : speakerLabel
        }
    }

    private var speakerColor: Color {
        switch speakerState {
        case .identified:
            return SpeakerColorHelper.hashColor(for: speakerLabel)
        case .unknown, .lowConfidence:
            return Color(nsColor: .systemGray).opacity(0.7)
        case .multiple:
            return .orange
        case .stale:
            return Color(hue: 0.12, saturation: 0.35, brightness: 0.60)
        }
    }

    private func triggerPulse() {
        // Snap to bigger, then spring back
        withAnimation(.easeOut(duration: 0.12)) {
            pulseScale = 1.15
            pulseOpacity = 0.7
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.55).delay(0.12)) {
            pulseScale = 1.0
            pulseOpacity = 1.0
        }
    }
}

typealias CurrentSpeakerBanner = CurrentSpeakerView
