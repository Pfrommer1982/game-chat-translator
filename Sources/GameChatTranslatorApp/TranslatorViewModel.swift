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
        self.modelPath = defaults.string(forKey: "modelPath") ?? Self.defaultModelPath()
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

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard canStart else { return }

        let command: LaunchCommand
        do {
            command = try makeLaunchCommand()
        } catch {
            statusText = "Configuration error"
            appendLine("Error: \(error.localizedDescription)")
            return
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL
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
            statusText = command.isBundledHelper ? "Listening" : "Listening (dev)"
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

    private func makeLaunchCommand() throws -> LaunchCommand {
        let model = try resolvedModelPath()
        let translatorArgs = commandArguments(modelPath: model)

        if let helperURL = bundledHelperURL(),
           FileManager.default.isExecutableFile(atPath: helperURL.path) {
            return LaunchCommand(
                executableURL: helperURL,
                arguments: translatorArgs,
                currentDirectoryURL: Bundle.main.resourceURL,
                isBundledHelper: true
            )
        }

        return LaunchCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["swift", "run", "SystemAudioTranscriber"] + translatorArgs,
            currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            isBundledHelper: false
        )
    }

    private func commandArguments(modelPath: String) -> [String] {
        var args = [
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

    private func resolvedModelPath() throws -> String {
        let trimmed = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ViewModelError.missingModel("Choose a whisper.cpp model first.")
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let fileManager = FileManager.default
        if expanded.hasPrefix("/") {
            guard fileManager.fileExists(atPath: expanded) else {
                throw ViewModelError.missingModel("Model not found: \(expanded)")
            }
            return expanded
        }

        let currentDirectoryPath = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
        if fileManager.fileExists(atPath: currentDirectoryPath) {
            return currentDirectoryPath
        }

        if let resourcePath = Bundle.main.resourceURL?
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path,
           fileManager.fileExists(atPath: resourcePath) {
            return resourcePath
        }

        throw ViewModelError.missingModel("Model not found: \(expanded)")
    }

    private static func defaultModelPath() -> String {
        if let bundledModel = Bundle.main.resourceURL?
            .appendingPathComponent("models/ggml-small.bin")
            .standardizedFileURL
            .path,
           FileManager.default.fileExists(atPath: bundledModel) {
            return bundledModel
        }
        return "./models/ggml-small.bin"
    }

    private func bundledHelperURL() -> URL? {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return nil
        }
        return Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("SystemAudioTranscriber")
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
            } else if line.contains("Screen & System Audio Recording") {
                statusText = "Permission needed"
                appendLine(line)
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

private struct LaunchCommand {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL?
    let isBundledHelper: Bool
}

private enum ViewModelError: LocalizedError {
    case missingModel(String)

    var errorDescription: String? {
        switch self {
        case .missingModel(let message):
            return message
        }
    }
}
