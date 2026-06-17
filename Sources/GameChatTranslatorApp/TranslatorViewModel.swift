import AppKit
import Foundation

@MainActor
final class TranslatorViewModel: ObservableObject {
    enum Preset: String, CaseIterable, Identifiable {
        case gameChat = "Game Chat"
        case quality = "Quality"

        var id: String { rawValue }
    }

    @Published var modelPath: String {
        didSet { UserDefaults.standard.set(modelPath, forKey: "modelPath") }
    }
    @Published var sourceLanguage: String {
        didSet { UserDefaults.standard.set(sourceLanguage, forKey: "sourceLanguage") }
    }
    @Published var threads: Int {
        didSet { UserDefaults.standard.set(threads, forKey: "threads") }
    }
    @Published var silenceThreshold: Double {
        didSet { UserDefaults.standard.set(silenceThreshold, forKey: "silenceThreshold") }
    }
    @Published var preset: Preset {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: "preset") }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Ready"
    @Published private(set) var transcriptLines: [String] = []

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    init() {
        let defaults = UserDefaults.standard
        self.modelPath = defaults.string(forKey: "modelPath") ?? "./models/ggml-small.bin"
        self.sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? "auto"
        let storedThreads = defaults.integer(forKey: "threads")
        self.threads = storedThreads > 0 ? storedThreads : 6
        let storedThreshold = defaults.double(forKey: "silenceThreshold")
        self.silenceThreshold = storedThreshold > 0 ? storedThreshold : 0.003
        if let storedPreset = defaults.string(forKey: "preset"),
           let preset = Preset(rawValue: storedPreset) {
            self.preset = preset
        } else {
            self.preset = .gameChat
        }
    }

    var canStart: Bool {
        !isRunning && !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Whisper Model"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.directoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        if panel.runModal() == .OK, let url = panel.url {
            modelPath = url.path
        }
    }

    func start() {
        guard canStart else { return }

        let args = commandArguments()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendOutput(text) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendStatusOutput(text) }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self?.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self?.isRunning = false
                self?.statusText = process.terminationStatus == 0 ? "Stopped" : "Stopped with error"
                self?.process = nil
            }
        }

        do {
            transcriptLines.removeAll()
            statusText = "Starting..."
            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            try process.run()
            isRunning = true
            statusText = "Listening"
        } catch {
            statusText = "Could not start translator"
            appendLine("Error: \(error.localizedDescription)")
            self.process = nil
        }
    }

    func stop() {
        guard let process else { return }
        statusText = "Stopping..."
        process.terminate()
    }

    func clearTranscript() {
        transcriptLines.removeAll()
    }

    func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcriptLines.joined(separator: "\n"), forType: .string)
    }

    private func commandArguments() -> [String] {
        var args = [
            "swift", "run", "SystemAudioTranscriber",
            "--model", modelPath,
            "--language", sourceLanguage,
            "--translate-to", "en",
            "--realtime",
            "--threads", "\(threads)",
            "--silence-threshold", String(format: "%.4f", silenceThreshold)
        ]

        switch preset {
        case .gameChat:
            args += [
                "--utterance-end-silence", "0.45",
                "--utterance-max-seconds", "5"
            ]
        case .quality:
            args += [
                "--utterance-end-silence", "0.75",
                "--utterance-max-seconds", "9"
            ]
        }

        return args
    }

    private func appendOutput(_ text: String) {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .forEach { appendLine($0) }
    }

    private func appendStatusOutput(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.contains("Loading whisper model") {
                statusText = "Loading model"
            } else if line.contains("Model loaded") {
                statusText = "Listening"
            } else if line.lowercased().contains("error") {
                appendLine(line)
            }
        }
    }

    private func appendLine(_ line: String) {
        transcriptLines.append(line)
        if transcriptLines.count > 500 {
            transcriptLines.removeFirst(transcriptLines.count - 500)
        }
    }
}

