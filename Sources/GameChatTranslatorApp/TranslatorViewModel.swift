import AppKit
import CoreMedia
import Foundation
import GameChatTranslatorCore

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

    private var capture: SystemAudioCapture?
    private var scheduler: TranscriptionScheduler?
    private var transcriber: WhisperTranscriber?
    private var converter: PCMConverter?
    private var ringBuffer: AudioRingBuffer?
    private var startTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        self.modelPath = Self.initialModelPath(storedPath: defaults.string(forKey: "modelPath"))
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

    var hasBundledModel: Bool {
        Self.bundledModelPath() != nil
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

    func useBundledModel() {
        guard let bundledModel = Self.bundledModelPath() else {
            statusText = "No bundled model"
            appendLine("No bundled whisper model was found in this app.")
            return
        }

        modelPath = bundledModel
        statusText = "Bundled model selected"
        appendLine("Using bundled model: \(bundledModel)")
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard canStart else { return }

        let model: String
        do {
            model = try resolvedModelPath()
        } catch {
            statusText = "Configuration error"
            appendLine("Error: \(error.localizedDescription)")
            return
        }

        transcriptLines.removeAll()
        isRunning = true
        statusText = "Starting..."
        appendLine("Starting translation engine...")

        let settings = EngineSettings(
            modelPath: model,
            sourceLanguage: sourceLanguage,
            threads: threads,
            silenceThreshold: Float(silenceThreshold),
            preset: preset
        )

        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.startEngine(settings)
        }
    }

    func stop() {
        guard isRunning || startTask != nil else { return }
        statusText = "Stopping..."
        startTask?.cancel()
        scheduler?.stop()

        let activeCapture = capture
        clearEngineReferences(keepTranscriber: false)

        Task { [weak self] in
            await activeCapture?.stop()
            await MainActor.run {
                self?.isRunning = false
                self?.statusText = "Stopped"
            }
        }
    }

    func clearTranscript() {
        transcriptLines.removeAll()
    }

    func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcriptLines.joined(separator: "\n"), forType: .string)
    }

    private func startEngine(_ settings: EngineSettings) async {
        do {
            statusText = "Loading model"
            appendLine("Loading whisper model: \(settings.modelPath)")

            let loadedTranscriber = try await Task.detached(priority: .userInitiated) {
                try WhisperTranscriber(
                    modelPath: settings.modelPath,
                    language: settings.sourceLanguage,
                    translateToEnglish: true,
                    realtimeMode: true,
                    threadCount: settings.threads
                )
            }.value

            if Task.isCancelled {
                isRunning = false
                statusText = "Stopped"
                return
            }

            let sampleRate = 16_000
            let ringBuffer = AudioRingBuffer(sampleRate: sampleRate, maxDurationSeconds: 20)
            let converter = PCMConverter(targetSampleRate: Double(sampleRate), targetChannels: 1)
            let scheduler = TranscriptionScheduler(
                ringBuffer: ringBuffer,
                transcriber: loadedTranscriber,
                chunkSeconds: 2.0,
                overlapSeconds: 1.7,
                sampleRate: sampleRate,
                silenceThresholdRMS: settings.silenceThreshold,
                realtimeUtteranceMode: true,
                utteranceEndSilenceSeconds: settings.utteranceEndSilenceSeconds,
                utteranceMaxSeconds: settings.utteranceMaxSeconds,
                verbose: false,
                onOutput: { [weak self] line in
                    Task { @MainActor in
                        self?.appendLine(line)
                    }
                }
            )

            let capture = SystemAudioCapture { [weak self, converter, ringBuffer] sampleBuffer in
                do {
                    let samples = try converter.convert(sampleBuffer)
                    ringBuffer.append(samples)
                } catch {
                    Task { @MainActor in
                        self?.appendLine("PCM conversion skipped buffer: \(error.localizedDescription)")
                    }
                }
            }

            self.transcriber = loadedTranscriber
            self.ringBuffer = ringBuffer
            self.converter = converter
            self.scheduler = scheduler
            self.capture = capture

            statusText = "Starting capture"
            appendLine("Model loaded.")

            try await capture.start()

            if Task.isCancelled {
                await capture.stop()
                isRunning = false
                statusText = "Stopped"
                clearEngineReferences(keepTranscriber: false)
                return
            }

            scheduler.start()
            statusText = "Listening"
            appendLine("Listening to system audio...")
            appendLine("Audio: 16000 Hz mono Float32")
            appendLine("Buffer: realtime")
        } catch {
            statusText = "Stopped with error"
            appendLine(error.localizedDescription)
            isRunning = false
            clearEngineReferences(keepTranscriber: false)
        }
    }

    private func clearEngineReferences(keepTranscriber: Bool) {
        scheduler = nil
        capture = nil
        converter = nil
        ringBuffer = nil
        startTask = nil
        if !keepTranscriber {
            transcriber = nil
        }
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
        if let bundledModel = bundledModelPath() {
            return bundledModel
        }
        return "./models/ggml-small.bin"
    }

    private static func initialModelPath(storedPath: String?) -> String {
        guard let storedPath,
              !storedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultModelPath()
        }

        let trimmed = storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDefaultRelativeModelPath(trimmed), let bundledModel = bundledModelPath() {
            return bundledModel
        }

        if existingModelPath(for: trimmed) != nil {
            return trimmed
        }

        return defaultModelPath()
    }

    private static func bundledModelPath() -> String? {
        guard let bundledModel = Bundle.main.resourceURL?
            .appendingPathComponent("models/ggml-small.bin")
            .standardizedFileURL
            .path,
              FileManager.default.fileExists(atPath: bundledModel) else {
            return nil
        }
        return bundledModel
    }

    private static func existingModelPath(for path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let fileManager = FileManager.default

        if expanded.hasPrefix("/") {
            return fileManager.fileExists(atPath: expanded) ? expanded : nil
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

        return nil
    }

    private static func isDefaultRelativeModelPath(_ path: String) -> Bool {
        path == "./models/ggml-small.bin" || path == "models/ggml-small.bin"
    }

    private func appendLine(_ line: String) {
        transcriptLines.append(line)
        if transcriptLines.count > 500 {
            transcriptLines.removeFirst(transcriptLines.count - 500)
        }
    }
}

private struct EngineSettings {
    let modelPath: String
    let sourceLanguage: String
    let threads: Int
    let silenceThreshold: Float
    let preset: TranslatorViewModel.Preset

    var utteranceEndSilenceSeconds: Double {
        switch preset {
        case .gameChat: 0.45
        case .quality: 0.75
        }
    }

    var utteranceMaxSeconds: Double {
        switch preset {
        case .gameChat: 5
        case .quality: 9
        }
    }
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
