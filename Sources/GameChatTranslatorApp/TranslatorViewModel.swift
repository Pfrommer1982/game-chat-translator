import AppKit
import CoreMedia
import Foundation
import GameChatTranslatorCore

@MainActor
final class TranslatorViewModel: ObservableObject {
    enum TranscriptionProvider: String, CaseIterable, Identifiable {
        case groq = "Groq"
        case openAI = "OpenAI"
        case compatible = "Compatible API"
        case local = "Local"

        var id: String { rawValue }

        var usesCloudAPI: Bool { self != .local }
    }

    struct RemoteModelOption: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
    }

    static let groqModels = [
        RemoteModelOption(
            id: "whisper-large-v3-turbo",
            title: "Large v3 Turbo",
            detail: "Recommended for maximum speed"
        ),
        RemoteModelOption(
            id: "whisper-large-v3",
            title: "Large v3",
            detail: "Slower, sometimes more accurate"
        )
    ]

    static let openAIModels = [
        RemoteModelOption(
            id: "gpt-4o-mini-transcribe",
            title: "GPT-4o mini Transcribe",
            detail: "Recommended balance of speed and cost"
        ),
        RemoteModelOption(
            id: "gpt-4o-transcribe",
            title: "GPT-4o Transcribe",
            detail: "Higher accuracy"
        ),
        RemoteModelOption(
            id: "whisper-1",
            title: "Whisper 1",
            detail: "Legacy compatibility"
        )
    ]

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
    @Published var targetLanguage: String {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "targetLanguage") }
    }
    @Published var transcriptionProvider: TranscriptionProvider {
        didSet {
            UserDefaults.standard.set(transcriptionProvider.rawValue, forKey: "transcriptionProvider")
            if transcriptionProvider.usesCloudAPI {
                targetLanguage = "en"
            }
        }
    }
    @Published var groqAPIKey: String {
        didSet { APIKeyStore.saveKey(groqAPIKey, for: .groq) }
    }
    @Published var groqModel: String {
        didSet { UserDefaults.standard.set(groqModel, forKey: "groqModel") }
    }
    @Published var openAIAPIKey: String {
        didSet { APIKeyStore.saveKey(openAIAPIKey, for: .openAI) }
    }
    @Published var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "openAIModel") }
    }
    @Published var compatibleAPIKey: String {
        didSet { APIKeyStore.saveKey(compatibleAPIKey, for: .custom) }
    }
    @Published var compatibleEndpoint: String {
        didSet { UserDefaults.standard.set(compatibleEndpoint, forKey: "compatibleEndpoint") }
    }
    @Published var compatibleModel: String {
        didSet { UserDefaults.standard.set(compatibleModel, forKey: "compatibleModel") }
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
    @Published var newestOnTop: Bool {
        didSet { UserDefaults.standard.set(newestOnTop, forKey: "newestOnTop") }
    }
    @Published var battleModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(battleModeEnabled, forKey: "battleModeEnabled")
            if battleModeEnabled {
                newestOnTop = true
            }
        }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Ready"
    @Published private(set) var transcripts: [AttributedTranscript] = []
    @Published private(set) var partialTranscript: AttributedTranscript? = nil
    @Published private(set) var displayItems: [TranscriptDisplayItem] = []
    @Published private(set) var partialDisplayItem: TranscriptDisplayItem? = nil
    @Published private(set) var availableModels: [LocalModelOption] = []
    @Published private(set) var currentSpeaker: AttributedTranscript? = nil
    @Published private(set) var currentSpeakerLabel = "Unknown"
    @Published private(set) var currentSpeakerState: SpeakerDisplayState = .unknown
    @Published private(set) var speakerHighlightToken = UUID()
    @Published private(set) var permissionGranted: Bool = true
    @Published private(set) var detectedLanguage: String? = nil

    // OCR configuration
    @Published var enableSpeakerOCR: Bool {
        didSet {
            UserDefaults.standard.set(enableSpeakerOCR, forKey: "enableSpeakerOCR")
            handleOCRToggle()
        }
    }
    @Published var debugMode: Bool {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
    }
    @Published var showOriginalText: Bool {
        didSet { UserDefaults.standard.set(showOriginalText, forKey: "showOriginalText") }
    }
    @Published var showUntranslatedFallback: Bool {
        didSet { UserDefaults.standard.set(showUntranslatedFallback, forKey: "showUntranslatedFallback") }
    }
    @Published var showPartialSource: Bool {
        didSet { UserDefaults.standard.set(showPartialSource, forKey: "showPartialSource") }
    }

    // Debug view data
    @Published var currentOCRText = "None"
    @Published var activeCandidate = "None"
    @Published var candidateIsStale = false
    @Published var candidateVisibleDuration = 0.0
    @Published var lastTranscriptTiming = "None"
    @Published var lastAttributionConfidence = 0.0
    @Published var lastAttributionReason = "None"

    private var capture: SystemAudioCapture?
    private var scheduler: TranscriptionScheduler?
    private var transcriber: (any AudioTranscribing)?
    private var converter: PCMConverter?
    private var ringBuffer: AudioRingBuffer?
    private var startTask: Task<Void, Never>?

    // OCR modules
    private let ocrTracker = OCRSpeakerTracker()
    private var ocrDetector: OCRSpeakerDetector?
    private let regionSelector = OCRRegionSelector()

    init() {
        let defaults = UserDefaults.standard
        self.modelPath = Self.initialModelPath(storedPath: defaults.string(forKey: "modelPath"))
        self.sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? "auto"
        let storedProvider = defaults.string(forKey: "transcriptionProvider")
        let initialProvider: TranscriptionProvider
        if storedProvider == "Groq Free" {
            initialProvider = .groq
        } else {
            initialProvider = storedProvider.flatMap(TranscriptionProvider.init(rawValue:)) ?? .groq
        }
        self.transcriptionProvider = initialProvider
        self.groqAPIKey = APIKeyStore.loadKey(for: .groq)
        self.groqModel = defaults.string(forKey: "groqModel") ?? "whisper-large-v3-turbo"
        self.openAIAPIKey = APIKeyStore.loadKey(for: .openAI)
        self.openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-4o-mini-transcribe"
        self.compatibleAPIKey = APIKeyStore.loadKey(for: .custom)
        self.compatibleEndpoint = defaults.string(forKey: "compatibleEndpoint") ?? ""
        self.compatibleModel = defaults.string(forKey: "compatibleModel") ?? ""
        self.targetLanguage = initialProvider.usesCloudAPI
            ? "en"
            : (defaults.string(forKey: "targetLanguage") ?? "nl")
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

        self.enableSpeakerOCR = defaults.bool(forKey: "enableSpeakerOCR")
        self.debugMode = defaults.bool(forKey: "debugMode")
        self.showOriginalText = defaults.bool(forKey: "showOriginalText")
        self.showUntranslatedFallback = defaults.bool(forKey: "showUntranslatedFallback")
        self.showPartialSource = defaults.bool(forKey: "showPartialSource")
        let storedBattleMode = defaults.bool(forKey: "battleModeEnabled")
        self.battleModeEnabled = storedBattleMode
        self.newestOnTop = true

        permissionGranted = true
        refreshAvailableModels()
    }

    /// Kept for the window lifecycle hook. We intentionally do not call the
    /// CoreGraphics screen-recording preflight API because it can repeatedly
    /// trigger macOS permission prompts for this ScreenCaptureKit audio flow.
    func refreshPermission() {
        permissionGranted = true
    }

    var canStart: Bool {
        !isRunning && !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var groqIsConfigured: Bool {
        !groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var openAIIsConfigured: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var compatibleAPIIsConfigured: Bool {
        !compatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.isHTTPAudioEndpoint(compatibleEndpoint)
            && !compatibleModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isHTTPAudioEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return url.scheme == "https" || url.scheme == "http"
    }

    var selectedRemoteModelDetail: String? {
        switch transcriptionProvider {
        case .groq:
            return Self.groqModels.first(where: { $0.id == groqModel })?.detail
        case .openAI:
            return Self.openAIModels.first(where: { $0.id == openAIModel })?.detail
        case .compatible, .local:
            return nil
        }
    }

    var activeProviderDescription: String {
        switch transcriptionProvider {
        case .groq:
            return groqIsConfigured ? "Groq first · local fallback" : "Add a Groq key · local only"
        case .openAI:
            return openAIIsConfigured ? "OpenAI first · local fallback" : "Add an OpenAI key · local only"
        case .compatible:
            return compatibleAPIIsConfigured
                ? "Compatible API first · local fallback"
                : "Add endpoint, model and key · local only"
        case .local:
            return "Local Whisper · offline"
        }
    }

    var hasBundledModel: Bool {
        Self.bundledModelPath() != nil
    }

    var recommendedModel: LocalModelOption? {
        LocalModelAdvisor.recommendedModel(in: availableModels)
    }

    var selectedModel: LocalModelOption? {
        availableModels.first(where: { $0.path == URL(fileURLWithPath: modelPath).standardizedFileURL.path })
    }

    var hardwareSummary: String {
        LocalModelAdvisor.hardwareSummary
    }

    var modelRecommendationText: String {
        "\(LocalModelAdvisor.recommendedTier.displayName) · \(LocalModelAdvisor.recommendationReason)"
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
            refreshAvailableModels()
        }
    }

    func useRecommendedModel() {
        guard let recommendedModel else {
            chooseModel()
            return
        }
        modelPath = recommendedModel.path
        statusText = "Recommended model selected"
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
        refreshAvailableModels()
    }

    private func refreshAvailableModels() {
        availableModels = LocalModelAdvisor.discoverModels(currentPath: modelPath)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openGroqConsole() {
        if let url = URL(string: "https://console.groq.com/keys") {
            NSWorkspace.shared.open(url)
        }
    }

    func openOpenAIConsole() {
        if let url = URL(string: "https://platform.openai.com/api-keys") {
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

        transcripts.removeAll()
        partialTranscript = nil
        displayItems.removeAll()
        partialDisplayItem = nil
        currentSpeaker = nil
        currentSpeakerLabel = "Unknown"
        currentSpeakerState = .unknown
        detectedLanguage = nil
        isRunning = true
        statusText = "Starting..."
        appendLine("Starting translation engine...")

        let settings = EngineSettings(
            modelPath: model,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            transcriptionProvider: transcriptionProvider,
            groqAPIKey: groqAPIKey,
            groqModel: groqModel,
            openAIAPIKey: openAIAPIKey,
            openAIModel: openAIModel,
            compatibleAPIKey: compatibleAPIKey,
            compatibleEndpoint: compatibleEndpoint,
            compatibleModel: compatibleModel,
            threads: threads,
            silenceThreshold: Float(silenceThreshold),
            preset: preset,
            battleModeEnabled: battleModeEnabled
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

        stopOCR()
        ocrTracker.reset()

        // Clear debug metrics
        currentOCRText = "None"
        activeCandidate = "None"
        candidateIsStale = false
        candidateVisibleDuration = 0.0
        currentSpeaker = nil
        partialTranscript = nil
        partialDisplayItem = nil
        currentSpeakerLabel = "Unknown"
        currentSpeakerState = .unknown
        detectedLanguage = nil

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
        transcripts.removeAll()
        partialTranscript = nil
        displayItems.removeAll()
        partialDisplayItem = nil
        currentSpeaker = nil
        currentSpeakerLabel = "Unknown"
        currentSpeakerState = .unknown
    }

    func copyTranscript() {
        let text = visibleHistoryItems
            .compactMap(primaryText)
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func startEngine(_ settings: EngineSettings) async {
        do {
            statusText = "Loading model"
            appendLine("Loading whisper model: \(settings.modelPath)")

            let localTranscriber = try await Task.detached(priority: .userInitiated) {
                try WhisperTranscriber(
                    modelPath: settings.modelPath,
                    language: settings.effectiveSourceLanguage,
                    translateToEnglish: settings.usesLocalWhisperTranslation,
                    realtimeMode: true,
                    threadCount: settings.threads
                )
            }.value

            let loadedTranscriber: any AudioTranscribing
            if let remoteTranscriber = try settings.makeRemoteTranscriber() {
                loadedTranscriber = FallbackAudioTranscriber(
                    primary: remoteTranscriber,
                    fallback: localTranscriber
                )
            } else {
                loadedTranscriber = localTranscriber
            }

            if Task.isCancelled {
                isRunning = false
                statusText = "Stopped"
                return
            }

            let sampleRate = 16_000
            let ringBuffer = AudioRingBuffer(sampleRate: sampleRate, maxDurationSeconds: settings.ringBufferSeconds)
            let converter = PCMConverter(targetSampleRate: Double(sampleRate), targetChannels: 1)
            let scheduler = TranscriptionScheduler(
                ringBuffer: ringBuffer,
                transcriber: loadedTranscriber,
                chunkSeconds: settings.chunkSeconds,
                overlapSeconds: settings.overlapSeconds,
                sampleRate: sampleRate,
                silenceThresholdRMS: settings.silenceThreshold,
                realtimeUtteranceMode: true,
                utteranceEndSilenceSeconds: settings.utteranceEndSilenceSeconds,
                utteranceMaxSeconds: settings.utteranceMaxSeconds,
                battleModeEnabled: settings.lowLatencyAudioEnabled,
                targetLanguage: settings.targetLanguage,
                partialTranscriptsEnabled: !settings.usesRemote,
                verbose: false,
                onOutput: { [weak self] transcript in
                    Task { @MainActor in
                        self?.appendTranscript(transcript)
                        self?.refreshDebugInfo()
                    }
                }
            )
            scheduler.voiceSpeakerTracker = VoiceSpeakerTracker(maxSpeakers: 4)

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

            // Start OCR detector if enabled
            if enableSpeakerOCR {
                let detector = OCRSpeakerDetector(tracker: ocrTracker, profile: GameProfileManager.shared.activeProfile)
                detector.delegate = self
                ocrDetector = detector

                scheduler.speakerTracker = ocrTracker
                scheduler.enableSpeakerAttribution = true
                scheduler.activeProfile = GameProfileManager.shared.activeProfile

                try await detector.start()
                appendLine("OCR Screen Capture started.")
            }

            statusText = "Starting capture"
            if settings.usesRemote {
                appendLine("\(settings.providerDisplayName) ready with local \(URL(fileURLWithPath: settings.modelPath).deletingPathExtension().lastPathComponent) fallback.")
                if !settings.battleModeEnabled {
                    appendLine("Fast cloud endpointing enabled automatically.")
                }
            } else {
                appendLine("Local model loaded.")
            }
            if settings.battleModeEnabled {
                appendLine(settings.usesRemote
                    ? "Battle Mode enabled: short cloud requests with a loss-resistant transcript queue."
                    : "Battle Mode enabled: short local chunks with live partials and a loss-resistant transcript queue.")
                if !settings.usesRemote && settings.targetLanguage != "en" {
                    appendLine("Local Whisper can only translate to English; target \(settings.targetLanguage.uppercased()) will show original speech until an external translator is configured.")
                }
            }

            try await capture.start()

            if Task.isCancelled {
                await capture.stop()
                isRunning = false
                statusText = "Stopped"
                clearEngineReferences(keepTranscriber: false)
                return
            }

            scheduler.start()
            statusText = "Listening · \(settings.providerDisplayName)"
            appendLine("Listening to system audio...")
            appendLine("Audio: 16000 Hz mono Float32")
            appendLine(settings.battleModeEnabled ? "Buffer: battle low-latency" : "Buffer: realtime")
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
        return "./models/ggml-base.bin"
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
        guard let modelsURL = Bundle.main.resourceURL?.appendingPathComponent("models", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(
                at: modelsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return nil }

        let preferredNames = ["ggml-base.bin", "ggml-small.bin", "ggml-tiny.bin"]
        for preferredName in preferredNames {
            if let match = files.first(where: { $0.lastPathComponent == preferredName }) {
                return match.standardizedFileURL.path
            }
        }
        return files.first(where: { $0.pathExtension.lowercased() == "bin" })?.standardizedFileURL.path
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
        [
            "./models/ggml-base.bin", "models/ggml-base.bin",
            "./models/ggml-small.bin", "models/ggml-small.bin"
        ].contains(path)
    }

    private func appendTranscript(_ transcript: AttributedTranscript) {
        if transcript.isPartial {
            partialTranscript = transcript
            partialDisplayItem = TranscriptDisplayItem(transcript: transcript)
            updateCurrentSpeaker(from: transcript)
            return
        }

        partialTranscript = nil
        partialDisplayItem = nil
        // Update currentSpeaker for the banner (only real utterances, not system messages)
        updateCurrentSpeaker(from: transcript)
        if let language = transcript.detectedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !language.isEmpty {
            detectedLanguage = Locale(identifier: language).language.languageCode?.identifier.lowercased()
                ?? language.lowercased()
        }
        if newestOnTop {
            transcripts.insert(transcript, at: 0)
            if transcripts.count > 500 {
                transcripts.removeLast(transcripts.count - 500)
            }
        } else {
            transcripts.append(transcript)
            if transcripts.count > 500 {
                transcripts.removeFirst(transcripts.count - 500)
            }
        }

        guard !transcript.isSystemMessage else { return }
        displayItems.insert(TranscriptDisplayItem(transcript: transcript), at: 0)
        if displayItems.count > 15 {
            displayItems.removeLast(displayItems.count - 15)
        }
    }

    var visibleHistoryItems: [TranscriptDisplayItem] {
        Array(displayItems.filter { primaryText(for: $0) != nil }.prefix(15))
    }

    var liveDisplayItem: TranscriptDisplayItem? {
        if let partialDisplayItem {
            if partialDisplayItem.translatedText != nil || shouldShowPartialSource {
                return partialDisplayItem
            }
            return nil
        }
        return visibleHistoryItems.first
    }

    var isLiveTranslationPending: Bool {
        isRunning && partialDisplayItem != nil && liveDisplayItem == nil
    }

    var shouldShowPartialSource: Bool {
        debugMode || showPartialSource
    }

    func primaryText(for item: TranscriptDisplayItem) -> String? {
        if let translatedText = item.translatedText {
            return translatedText
        }
        if item.isPartial && shouldShowPartialSource {
            return item.originalText
        }
        if showUntranslatedFallback {
            return item.originalText
        }
        return nil
    }

    func debugMetadata(for item: TranscriptDisplayItem) -> String {
        var parts: [String] = []
        parts.append("source \(item.detectedLanguage ?? sourceLanguage)")
        parts.append("target \(targetLanguage)")
        if let latencyMs = item.latencyMs {
            parts.append("\(latencyMs) ms")
        }
        if item.isPartial {
            parts.append("partial")
        }
        if let speakerLabel = item.speakerLabel {
            parts.append("speaker \(speakerLabel) \(Int((item.speakerConfidence * 100).rounded()))%")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func updateCurrentSpeaker(from transcript: AttributedTranscript) {
        guard !transcript.isSystemMessage else { return }

        let label = speakerLabel(for: transcript)
        let changed = label != currentSpeakerLabel || transcript.speakerState != currentSpeakerState
        currentSpeaker = transcript
        currentSpeakerLabel = label
        currentSpeakerState = transcript.speakerState
        if changed {
            speakerHighlightToken = UUID()
        }
    }

    private func speakerLabel(for transcript: AttributedTranscript) -> String {
        switch transcript.speakerState {
        case .identified:
            return transcript.speakerLabel
        case .unknown:
            return "Unknown"
        case .multiple:
            return "Multiple speakers"
        case .stale:
            return transcript.speakerLabel.isEmpty ? "Stale" : transcript.speakerLabel
        case .lowConfidence:
            return transcript.speakerLabel.isEmpty ? "Unknown ?" : "\(transcript.speakerLabel) ?"
        }
    }

    // Legacy convenience used only for status messages during startup
    private func appendLine(_ text: String) {
        appendTranscript(.system(text))
    }

    // MARK: - OCR Helpers

    private func handleOCRToggle() {
        guard isRunning else { return }
        if enableSpeakerOCR {
            startOCR()
        } else {
            stopOCR()
        }
    }

    private func startOCR() {
        guard ocrDetector == nil else { return }
        let detector = OCRSpeakerDetector(tracker: ocrTracker, profile: GameProfileManager.shared.activeProfile)
        detector.delegate = self
        ocrDetector = detector

        scheduler?.speakerTracker = ocrTracker
        scheduler?.enableSpeakerAttribution = true
        scheduler?.activeProfile = GameProfileManager.shared.activeProfile

        Task {
            do {
                try await detector.start()
                appendLine("OCR Screen Capture started.")
            } catch {
                appendLine("Failed to start OCR Screen Capture: \(error.localizedDescription)")
            }
        }
    }

    private func stopOCR() {
        guard let detector = ocrDetector else { return }
        ocrDetector = nil
        scheduler?.enableSpeakerAttribution = false

        Task {
            try? await detector.stop()
            appendLine("OCR Screen Capture stopped.")
        }
    }

    func selectRegion() {
        let wasRunningOCR = ocrDetector != nil
        if wasRunningOCR {
            stopOCR()
        }

        regionSelector.startSelection(
            onSelected: { [weak self] rect in
                guard let self = self else { return }
                var profile = GameProfileManager.shared.activeProfile
                profile.ocrRegion = rect
                GameProfileManager.shared.saveProfile(profile)
                self.appendLine("New OCR region selected: \(rect)")

                if wasRunningOCR {
                    self.startOCR()
                }
            },
            onCancelled: { [weak self] in
                guard let self = self else { return }
                self.appendLine("Region selection cancelled.")
                if wasRunningOCR {
                    self.startOCR()
                }
            }
        )
    }

    func refreshDebugInfo() {
        guard let scheduler = scheduler else { return }
        if let attr = scheduler.lastAttributionResult {
            lastAttributionConfidence = attr.confidence
            lastAttributionReason = attr.reason
        }
        if let start = scheduler.lastSegmentStart, let end = scheduler.lastSegmentEnd {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            lastTranscriptTiming = "\(formatter.string(from: start)) - \(formatter.string(from: end)) (\(String(format: "%.2fs", end.timeIntervalSince(start))))"
        }
    }
    func updateActiveProfile(_ profile: GameProfile) {
        if isRunning && enableSpeakerOCR {
            Task {
                await ocrDetector?.updateProfile(profile)
                scheduler?.activeProfile = profile
            }
        }
    }
}

extension TranslatorViewModel: OCRSpeakerDetectorDelegate {
    nonisolated public func didDetectSpeakers(_ speakers: [(username: String, confidence: Double)], rawText: [String]) {
        Task { @MainActor in
            self.currentOCRText = rawText.joined(separator: ", ")
            if self.currentOCRText.isEmpty { self.currentOCRText = "None" }

            if let activeState = self.ocrTracker.getCurrentActiveStates().first {
                self.activeCandidate = activeState.username
                self.candidateIsStale = activeState.continuousVisibleDuration > GameProfileManager.shared.activeProfile.staleThreshold
                self.candidateVisibleDuration = activeState.continuousVisibleDuration
            } else {
                self.activeCandidate = "None"
                self.candidateIsStale = false
                self.candidateVisibleDuration = 0.0
            }

            self.refreshDebugInfo()
        }
    }
}

private struct EngineSettings {
    let modelPath: String
    let sourceLanguage: String
    let targetLanguage: String
    let transcriptionProvider: TranslatorViewModel.TranscriptionProvider
    let groqAPIKey: String
    let groqModel: String
    let openAIAPIKey: String
    let openAIModel: String
    let compatibleAPIKey: String
    let compatibleEndpoint: String
    let compatibleModel: String
    let threads: Int
    let silenceThreshold: Float
    let preset: TranslatorViewModel.Preset
    let battleModeEnabled: Bool

    var usesRemote: Bool {
        switch transcriptionProvider {
        case .groq:
            return !groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openAI:
            return !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .compatible:
            return !compatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && isHTTPAudioEndpoint(compatibleEndpoint)
                && !compatibleModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .local:
            return false
        }
    }

    var providerDisplayName: String {
        usesRemote ? transcriptionProvider.rawValue : "Local"
    }

    func makeRemoteTranscriber() throws -> (any AudioTranscribing)? {
        guard usesRemote else { return nil }
        switch transcriptionProvider {
        case .groq:
            return try GroqTranscriber(
                apiKey: groqAPIKey,
                language: effectiveSourceLanguage,
                model: groqModel
            )
        case .openAI:
            return try RemoteAudioTranscriber(
                providerName: "OpenAI",
                apiKey: openAIAPIKey,
                endpoint: "https://api.openai.com/v1/audio/translations",
                model: openAIModel,
                inputLanguage: effectiveSourceLanguage,
                prompt: "Translate spoken game chat into concise, natural English. Preserve names, commands, numbers, and urgency. Do not explain.",
                timeoutSeconds: 2.8
            )
        case .compatible:
            return try RemoteAudioTranscriber(
                providerName: "Compatible API",
                apiKey: compatibleAPIKey,
                endpoint: compatibleEndpoint,
                model: compatibleModel,
                inputLanguage: effectiveSourceLanguage,
                prompt: "Translate spoken game chat into concise, natural English. Preserve names, commands, numbers, and urgency. Do not explain.",
                timeoutSeconds: 2.8
            )
        case .local:
            return nil
        }
    }

    var effectiveSourceLanguage: String {
        sourceLanguage
    }

    private func isHTTPAudioEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return url.scheme == "https" || url.scheme == "http"
    }

    var usesLocalWhisperTranslation: Bool {
        targetLanguage == "en"
    }

    var lowLatencyAudioEnabled: Bool {
        battleModeEnabled || usesRemote
    }

    var utteranceEndSilenceSeconds: Double {
        if usesRemote { return 0.28 }
        if battleModeEnabled { return 0.22 }
        switch preset {
        case .gameChat: return 0.45
        case .quality: return 0.75
        }
    }

    var utteranceMaxSeconds: Double {
        if usesRemote { return 5.0 }
        if battleModeEnabled { return 3.0 }
        switch preset {
        case .gameChat: return 5
        case .quality: return 9
        }
    }

    var chunkSeconds: Double {
        lowLatencyAudioEnabled ? 0.5 : 2.0
    }

    var overlapSeconds: Double {
        lowLatencyAudioEnabled ? 0.0 : 1.7
    }

    var ringBufferSeconds: Double {
        lowLatencyAudioEnabled ? 6 : 20
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
