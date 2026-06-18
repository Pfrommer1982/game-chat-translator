import SwiftUI

struct TranslatorWindow: View {
    @StateObject private var viewModel = TranslatorViewModel()
    @State private var isPulseActive = false

    var body: some View {
        HStack(spacing: 0) {
            settingsPanel
                .frame(width: 310)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            transcriptPanel
                .frame(minWidth: 540, minHeight: 520)
        }
        .frame(minWidth: 850, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermission()
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Game Chat Translator")
                        .font(.system(size: 17, weight: .bold))
                    Text("Live system-audio translation")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    modelSettings
                    translationSettings
                    battleSettings
                    displaySettings
                    audioSettings
                }
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.start()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.canStart)

                Button {
                    viewModel.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!viewModel.isRunning)
            }

            statusRow

            if !viewModel.permissionGranted {
                permissionBanner
            }
        }
        .padding(16)
    }

    private var modelSettings: some View {
        SettingsCard(title: "Transcription Engine", iconName: "cpu", iconColor: .blue) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Provider")
                        .font(.system(size: 11))
                    Spacer()
                    Picker("", selection: $viewModel.transcriptionProvider) {
                        ForEach(TranslatorViewModel.TranscriptionProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
                .disabled(viewModel.isRunning)

                Text(viewModel.activeProviderDescription)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(viewModel.transcriptionProvider.usesCloudAPI ? Color.green : Color.secondary)

                remoteProviderSettings

                if viewModel.transcriptionProvider.usesCloudAPI {
                    Divider()
                    Text("Local fallback")
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Text("Local model")
                        .font(.system(size: 10, weight: .semibold))
                }

                HStack(spacing: 6) {
                    Picker("", selection: $viewModel.modelPath) {
                        ForEach(viewModel.availableModels) { model in
                            Text(model.title).tag(model.path)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .disabled(viewModel.isRunning || viewModel.availableModels.isEmpty)

                    Button {
                        viewModel.chooseModel()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .controlSize(.small)
                    .disabled(viewModel.isRunning)
                    .help("Choose another Whisper model")
                }

                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.hardwareSummary)
                            .font(.system(size: 10, weight: .semibold))
                        Text(viewModel.modelRecommendationText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let selectedModel = viewModel.selectedModel {
                    Text(selectedModel.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                if let recommendedModel = viewModel.recommendedModel,
                   recommendedModel.path != viewModel.modelPath {
                    Button {
                        viewModel.useRecommendedModel()
                    } label: {
                        Label("Use recommended \(recommendedModel.title)", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(viewModel.isRunning)
                }
            }
        }
    }

    @ViewBuilder
    private var remoteProviderSettings: some View {
        switch viewModel.transcriptionProvider {
        case .groq:
            apiKeyField(
                placeholder: "Groq API key",
                key: $viewModel.groqAPIKey,
                help: "Create a Groq API key",
                openConsole: viewModel.openGroqConsole
            )
            remoteModelPicker(
                selection: $viewModel.groqModel,
                options: TranslatorViewModel.groqModels
            )
        case .openAI:
            apiKeyField(
                placeholder: "OpenAI API key",
                key: $viewModel.openAIAPIKey,
                help: "Create an OpenAI API key",
                openConsole: viewModel.openOpenAIConsole
            )
            remoteModelPicker(
                selection: $viewModel.openAIModel,
                options: TranslatorViewModel.openAIModels
            )
        case .compatible:
            SecureField("API key", text: $viewModel.compatibleAPIKey)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .disabled(viewModel.isRunning)
            TextField("https://provider.example/v1/audio/translations", text: $viewModel.compatibleEndpoint)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .disabled(viewModel.isRunning)
            TextField("Model name", text: $viewModel.compatibleModel)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .disabled(viewModel.isRunning)
        case .local:
            EmptyView()
        }

        if viewModel.transcriptionProvider.usesCloudAPI {
            if let detail = viewModel.selectedRemoteModelDetail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Text("Keys stay local to this Mac user. Cloud failures use the selected local model.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func apiKeyField(
        placeholder: String,
        key: Binding<String>,
        help: String,
        openConsole: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            SecureField(placeholder, text: key)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .disabled(viewModel.isRunning)

            Button(action: openConsole) {
                Image(systemName: "key")
            }
            .controlSize(.small)
            .help(help)
        }
    }

    private func remoteModelPicker(
        selection: Binding<String>,
        options: [TranslatorViewModel.RemoteModelOption]
    ) -> some View {
        HStack {
            Text("API model")
                .font(.system(size: 11))
            Spacer()
            Picker("", selection: selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(viewModel.isRunning)
        }
    }

    private var translationSettings: some View {
        SettingsCard(title: "Translation", iconName: "globe", iconColor: .green) {
            VStack(spacing: 8) {
                languagePicker(
                    title: "Source",
                    selection: $viewModel.sourceLanguage,
                    options: [
                        ("Auto", "auto"), ("Dutch (NL)", "nl"), ("English (EN)", "en"),
                        ("French (FR)", "fr"), ("German (DE)", "de"), ("Spanish (ES)", "es"),
                        ("Russian (RU)", "ru"), ("Arabic (AR)", "ar")
                    ]
                )

                languagePicker(
                    title: "Output",
                    selection: $viewModel.targetLanguage,
                    options: [
                        ("Dutch (NL)", "nl"), ("English (EN)", "en"), ("French (FR)", "fr"),
                        ("German (DE)", "de"), ("Spanish (ES)", "es")
                    ]
                )
                .disabled(viewModel.transcriptionProvider.usesCloudAPI)

                Divider()

                HStack {
                    Text("Preset")
                        .font(.system(size: 11))
                    Spacer()
                    Picker("", selection: $viewModel.preset) {
                        ForEach(TranslatorViewModel.Preset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 140)
                }
            }
        }
    }

    private func languagePicker(
        title: String,
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    private var battleSettings: some View {
        SettingsCard(title: "Battle Mode", iconName: "bolt.fill", iconColor: .yellow) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable Battle Mode", isOn: $viewModel.battleModeEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))

                if viewModel.battleModeEnabled {
                    Text("Local Whisper uses short chunks and preserves queued speech, but remains slower than cloud STT.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var displaySettings: some View {
        SettingsCard(title: "Display", iconName: "captions.bubble", iconColor: .cyan) {
            VStack(alignment: .leading, spacing: 8) {
                displayToggle("Debug Mode", isOn: $viewModel.debugMode)
                displayToggle("Show original text", isOn: $viewModel.showOriginalText)
                    .disabled(!viewModel.debugMode)
                displayToggle("Show untranslated fallback", isOn: $viewModel.showUntranslatedFallback)
                displayToggle("Show partial source while waiting", isOn: $viewModel.showPartialSource)

                if viewModel.debugMode {
                    Divider()
                    displayToggle("Speaker OCR diagnostics", isOn: $viewModel.enableSpeakerOCR)
                }
            }
        }
    }

    private func displayToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
    }

    private var audioSettings: some View {
        SettingsCard(title: "Audio", iconName: "waveform", iconColor: .purple) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Threads")
                        .font(.system(size: 11))
                    Spacer()
                    Stepper("", value: $viewModel.threads, in: 1...12)
                        .labelsHidden()
                        .controlSize(.small)
                    Text("\(viewModel.threads)")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .frame(width: 20, alignment: .trailing)
                }

                Divider()

                HStack {
                    Text("Noise Gate")
                        .font(.system(size: 11))
                    Spacer()
                    Text(String(format: "%.3f", viewModel.silenceThreshold))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $viewModel.silenceThreshold, in: 0.001...0.010, step: 0.001)
                    .controlSize(.small)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(viewModel.isRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(viewModel.statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let language = viewModel.detectedLanguage {
                        Text(language.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(language == "ru" ? Color.orange : Color.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((language == "ru" ? Color.orange : Color.blue).opacity(0.12), in: Capsule())
                    .accessibilityLabel("Detected language \(language.uppercased())")
            }
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Screen & System Audio Recording permission is required.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Open Privacy Settings") {
                viewModel.openPrivacySettings()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var transcriptPanel: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                transcriptHeader
                liveSubtitlePanel
                historyPanel(maxHeight: geometry.size.height * (viewModel.debugMode ? 0.34 : 0.60))

                if viewModel.debugMode {
                    ScrollView {
                        SpeakerAttributionDebugView(viewModel: viewModel)
                    }
                    .frame(maxHeight: geometry.size.height * 0.34)
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var transcriptHeader: some View {
        HStack(spacing: 9) {
            Text("Live Translation")
                .font(.system(size: 16, weight: .bold))

            if viewModel.isRunning {
                Circle()
                    .fill(viewModel.battleModeEnabled ? Color.yellow : Color.green)
                    .frame(width: 6, height: 6)
                    .scaleEffect(isPulseActive ? 1.25 : 0.8)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: isPulseActive)
                    .onAppear { isPulseActive = true }
            }

            Spacer()

            CircularIconButton(iconName: "doc.on.doc", tooltip: "Copy subtitles") {
                viewModel.copyTranscript()
            }
            CircularIconButton(iconName: "trash", tooltip: "Clear subtitles") {
                viewModel.clearTranscript()
            }
        }
    }

    private var liveSubtitlePanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let item = viewModel.liveDisplayItem,
               let text = viewModel.primaryText(for: item) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let speakerLabel = item.speakerLabel {
                        SpeakerLabelView(label: speakerLabel, state: item.speakerState)
                    }

                    Text(text)
                        .font(.system(size: 30, weight: .semibold))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if viewModel.debugMode,
                   viewModel.showOriginalText,
                   let originalText = item.originalText,
                   originalText.caseInsensitiveCompare(text) != .orderedSame {
                    Text(originalText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                if viewModel.debugMode {
                    Text(viewModel.debugMetadata(for: item))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            } else if viewModel.isLiveTranslationPending {
                Text("…")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
    }

    private func historyPanel(maxHeight: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.visibleHistoryItems) { item in
                    if let text = viewModel.primaryText(for: item) {
                        TranscriptRowView(
                            item: item,
                            text: text,
                            showOriginalText: viewModel.debugMode && viewModel.showOriginalText,
                            debugMetadata: viewModel.debugMode ? viewModel.debugMetadata(for: item) : nil
                        )
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
        }
        .frame(maxHeight: maxHeight, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.14), lineWidth: 1))
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let iconName: String
    let iconColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
            }
            content()
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1), lineWidth: 1))
    }
}

struct CircularIconButton: View {
    let iconName: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 0.8 : 0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}
