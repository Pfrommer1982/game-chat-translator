import SwiftUI

struct TranslatorWindow: View {
    @StateObject private var viewModel = TranslatorViewModel()

    var body: some View {
        HStack(spacing: 0) {
            settingsPanel
                .frame(width: 320)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            transcriptPanel
                .frame(minWidth: 560, minHeight: 520)
        }
        .frame(minWidth: 880, minHeight: 560)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Game Chat Translator")
                    .font(.title2.weight(.semibold))
                Text("Local system-audio translation")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.headline)
                HStack {
                    TextField("models/ggml-small.bin", text: $viewModel.modelPath)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        viewModel.chooseModel()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Choose model")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Source Language")
                    .font(.headline)
                Picker("", selection: $viewModel.sourceLanguage) {
                    Text("Auto").tag("auto")
                    Text("English").tag("en")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Spanish").tag("es")
                    Text("Russian").tag("ru")
                    Text("Arabic").tag("ar")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Preset")
                    .font(.headline)
                Picker("", selection: $viewModel.preset) {
                    ForEach(TranslatorViewModel.Preset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Threads")
                    Spacer()
                    Stepper("\(viewModel.threads)", value: $viewModel.threads, in: 1...12)
                        .labelsHidden()
                    Text("\(viewModel.threads)")
                        .monospacedDigit()
                        .frame(width: 24, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Noise Gate")
                        Spacer()
                        Text(String(format: "%.3f", viewModel.silenceThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $viewModel.silenceThreshold, in: 0.001...0.010, step: 0.001)
                }
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.start()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)

                Button {
                    viewModel.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!viewModel.isRunning)
            }

            statusRow

            Spacer()

            Text("Requires Screen & System Audio Recording permission.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isRunning ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
            Text(viewModel.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live Translation")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    viewModel.copyTranscript()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy transcript")

                Button {
                    viewModel.clearTranscript()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear")
            }
            .padding(16)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if viewModel.transcriptLines.isEmpty {
                            emptyState
                        } else {
                            ForEach(Array(viewModel.transcriptLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 16, weight: .regular, design: .rounded))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 16)
                                    .id(index)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
                .onChange(of: viewModel.transcriptLines.count) { count in
                    guard count > 0 else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Press Start and play audio through your Mac.")
                .font(.headline)
            Text("Translations will appear here when voice chat is detected.")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }
}
