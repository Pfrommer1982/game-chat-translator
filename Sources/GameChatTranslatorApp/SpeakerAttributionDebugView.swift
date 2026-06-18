import SwiftUI
import GameChatTranslatorCore

struct SpeakerAttributionDebugView: View {
    @ObservedObject var viewModel: TranslatorViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Speaker Attribution Debug")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Circle()
                    .fill(viewModel.enableSpeakerOCR && viewModel.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(viewModel.enableSpeakerOCR && viewModel.isRunning ? "OCR Active" : "OCR Idle")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                DebugRowView(label: "Current OCR Text", value: viewModel.currentOCRText)
                DebugRowView(label: "Active Candidate", value: viewModel.activeCandidate)
                DebugRowView(
                    label: "Candidate Status",
                    value: viewModel.activeCandidate == "None" ? "N/A" : (viewModel.candidateIsStale ? "STALE (> \(Int(GameProfileManager.shared.activeProfile.staleThreshold))s)" : "Active"),
                    color: viewModel.activeCandidate == "None" ? .secondary : (viewModel.candidateIsStale ? .red : .green)
                )
                DebugRowView(
                    label: "Visible Duration",
                    value: viewModel.activeCandidate == "None" ? "0.0s" : String(format: "%.1fs", viewModel.candidateVisibleDuration)
                )
            }
            
            Divider()
                .padding(.vertical, 2)
            
            VStack(alignment: .leading, spacing: 8) {
                DebugRowView(label: "Last Transcript Segment", value: viewModel.lastTranscriptTiming)
                DebugRowView(
                    label: "Attribution Confidence",
                    value: viewModel.lastTranscriptTiming == "None" ? "N/A" : String(format: "%.1f%%", viewModel.lastAttributionConfidence * 100),
                    color: viewModel.lastTranscriptTiming == "None" ? .secondary : (viewModel.lastAttributionConfidence >= GameProfileManager.shared.activeProfile.attributionConfidenceThreshold ? .green : .orange)
                )
                DebugRowView(label: "Attribution Reason", value: viewModel.lastAttributionReason)
            }

            if let current = viewModel.currentSpeaker, !current.isSystemMessage {
                Divider()
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 8) {
                    DebugRowView(
                        label: "Last Speaker Label",
                        value: current.speakerLabel.isEmpty ? "—" : current.speakerLabel
                    )
                    DebugRowView(
                        label: "Display State",
                        value: "\(current.speakerState)",
                        color: stateColor(current.speakerState)
                    )
                    DebugRowView(
                        label: "Score",
                        value: String(format: "%.1f%%", current.attributionConfidence * 100),
                        color: current.attributionConfidence >= GameProfileManager.shared.activeProfile.attributionConfidenceThreshold ? .green : .orange
                    )
                }
            }

        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.02), radius: 6, x: 0, y: 3)
    }

    private func stateColor(_ state: SpeakerDisplayState) -> Color {
        switch state {
        case .identified:    return .green
        case .unknown:       return .secondary
        case .multiple:      return .orange
        case .stale:         return Color(hue: 0.12, saturation: 0.5, brightness: 0.7)
        case .lowConfidence: return .secondary
        }
    }
}

struct DebugRowView: View {
    let label: String
    let value: String
    var color: Color = .primary
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)
            
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
        }
    }
}
