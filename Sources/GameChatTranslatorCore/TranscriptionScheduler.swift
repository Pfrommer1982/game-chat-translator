import Foundation

public final class TranscriptionScheduler {
    private let ringBuffer: AudioRingBuffer
    private let transcriber: (any AudioTranscribing)?
    private let chunkSeconds: Double
    private let overlapSeconds: Double
    private let sampleRate: Int
    private let silenceThresholdRMS: Float
    private let realtimeUtteranceMode: Bool
    private let utteranceEndSilenceSeconds: Double
    private let utteranceMaxSeconds: Double
    private let battleModeEnabled: Bool
    private let targetLanguage: String?
    private let partialTranscriptsEnabled: Bool
    private let verbose: Bool
    private let onOutput: @Sendable (AttributedTranscript) -> Void
    private var isRunning = false
    private var isTranscribing = false
    private var recentNormalizedOutputs: [String] = []
    private var recentPrintedWords: [String] = []
    private var pendingOutput = ""
    private var pendingLanguage: String?
    private var isCapturingUtterance = false
    private var utteranceSamples: [Float] = []
    private var preRollSamples: [Float] = []
    private var speechCandidateSamples: [Float] = []
    private var trailingSilenceSeconds = 0.0
    private let transcriptionQueueLock = NSLock()

    private struct Utterance {
        let id: UInt64
        let samples: [Float]
        let startTime: Date
        let endTime: Date
        let voiceSampleTask: Task<VoiceSpeakerSample?, Never>?
    }
    private struct PendingPartialFinal {
        let utterance: Utterance
        let partialSampleCount: Int
    }
    private var queuedUtterances: [Utterance] = []
    private var isDrainingTranscriptionQueue = false
    private var nextUtteranceID: UInt64 = 0
    private var activeUtteranceID: UInt64 = 0
    private var partialUtteranceID: UInt64?
    private var partialSampleCount = 0
    private var pendingPartialFinal: PendingPartialFinal?

    public var speakerTracker: OCRSpeakerTracker?
    public var enableSpeakerAttribution: Bool = false
    public var activeProfile: GameProfile?
    public var voiceSpeakerTracker: VoiceSpeakerTracker?

    private var _lastAttributionResult: AttributionResult?
    private var _lastSegmentStart: Date?
    private var _lastSegmentEnd: Date?

    public var lastAttributionResult: AttributionResult? {
        transcriptionQueueLock.withLock { _lastAttributionResult }
    }
    public var lastSegmentStart: Date? {
        transcriptionQueueLock.withLock { _lastSegmentStart }
    }
    public var lastSegmentEnd: Date? {
        transcriptionQueueLock.withLock { _lastSegmentEnd }
    }

    private var pendingStartTime = Date()
    private var pendingEndTime = Date()
    private var utteranceStartTime = Date()
    private var isPartialTranscribing = false
    private var lastPartialRequestTime = Date.distantPast
    private var lastPartialNormalized = ""

    private var stepSeconds: Double {
        if realtimeUtteranceMode {
            return battleModeEnabled ? 0.1 : 0.2
        }
        return max(0.5, chunkSeconds - overlapSeconds)
    }

    public init(
        ringBuffer: AudioRingBuffer,
        transcriber: (any AudioTranscribing)?,
        chunkSeconds: Double = 5,
        overlapSeconds: Double = 0.5,
        sampleRate: Int = 16_000,
        silenceThresholdRMS: Float = 0.001,
        realtimeUtteranceMode: Bool = false,
        utteranceEndSilenceSeconds: Double = 0.55,
        utteranceMaxSeconds: Double = 6.0,
        battleModeEnabled: Bool = false,
        targetLanguage: String? = nil,
        partialTranscriptsEnabled: Bool = true,
        verbose: Bool = false,
        onOutput: @escaping @Sendable (AttributedTranscript) -> Void = { print($0.text) }
    ) {
        self.ringBuffer = ringBuffer
        self.transcriber = transcriber
        self.chunkSeconds = chunkSeconds
        self.overlapSeconds = overlapSeconds
        self.sampleRate = sampleRate
        self.silenceThresholdRMS = silenceThresholdRMS
        self.realtimeUtteranceMode = realtimeUtteranceMode
        self.utteranceEndSilenceSeconds = utteranceEndSilenceSeconds
        self.utteranceMaxSeconds = utteranceMaxSeconds
        self.battleModeEnabled = battleModeEnabled
        self.targetLanguage = targetLanguage?.lowercased()
        self.partialTranscriptsEnabled = partialTranscriptsEnabled
        self.verbose = verbose
        self.onOutput = onOutput
    }

    public func start() {
        guard transcriber != nil else { return }
        isRunning = true

        Task.detached { [weak self] in
            guard let self else { return }
            while self.isRunning {
                try? await Task.sleep(nanoseconds: UInt64(stepSeconds * 1_000_000_000))
                await self.tick()
            }
        }
    }

    public func stop() {
        isRunning = false
    }

    private func tick() async {
        guard let transcriber else { return }

        if realtimeUtteranceMode {
            await tickUtteranceMode()
            return
        }

        if isTranscribing {
            emit("Skipping chunk because transcription is still running.")
            return
        }

        let chunkEndTime = Date()
        let chunkStartTime = chunkEndTime.addingTimeInterval(-chunkSeconds)

        let chunk = ringBuffer.popChunk(seconds: chunkSeconds, keepingOverlap: overlapSeconds)
        guard !chunk.isEmpty else { return }

        let level = AudioLevelMeter.measure(chunk)
        let freshWindowSeconds = min(max(stepSeconds, 0.25), 1.0)
        let freshSampleCount = min(chunk.count, max(1, Int(freshWindowSeconds * Double(sampleRate))))
        let freshSamples = Array(chunk.suffix(freshSampleCount))
        let freshLevel = AudioLevelMeter.measure(freshSamples)

        guard freshLevel.rms >= silenceThresholdRMS else {
            if verbose {
                emit(String(format: "Skipping stale overlap: fresh rms %.6f, %.1f dBFS, threshold %.6f", freshLevel.rms, freshLevel.dbFS, silenceThresholdRMS))
            }
            flushPendingOutputIfUseful(force: true)
            return
        }

        let voiceActivity = VoiceActivityDetector.analyze(
            samples: freshSamples,
            sampleRate: sampleRate,
            rmsThreshold: silenceThresholdRMS
        )
        guard voiceActivity.hasLikelySpeech else {
            if verbose {
                emit(String(
                    format: "Skipping non-dialogue audio: speech frames %d/%d, ratio %.2f, fresh rms %.6f",
                    voiceActivity.speechFrameCount,
                    voiceActivity.totalFrameCount,
                    voiceActivity.speechFrameRatio,
                    freshLevel.rms
                ))
            }
            flushPendingOutputIfUseful(force: true)
            return
        }

        guard level.rms >= silenceThresholdRMS else {
            if verbose {
                emit(String(format: "Skipping silent chunk: rms %.6f, %.1f dBFS, threshold %.6f", level.rms, level.dbFS, silenceThresholdRMS))
            }
            flushPendingOutputIfUseful(force: true)
            return
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            if verbose {
                emit(String(format: "Transcribing %.1fs chunk: rms %.6f, %.1f dBFS", chunkSeconds, level.rms, level.dbFS))
            }
            let result = try await transcriber.transcribe(samples: chunk, sampleRate: sampleRate)
            guard !result.text.isEmpty else {
                if verbose {
                    let language = result.detectedLanguage ?? "unknown"
                    emit("[detected: \(language)] no speech text returned")
                }
                return
            }
            guard result.tokenCount == 0 || result.averageTokenProbability >= 0.38 else {
                if verbose {
                    emit(String(format: "Skipping low-confidence transcript: p %.2f, tokens %d, text: %@", result.averageTokenProbability, result.tokenCount, result.text))
                }
                return
            }
            let cleanedText = collapseRepeatedPhrases(in: result.text)
            let outputText = removeAlreadyPrintedPrefix(from: cleanedText)
            guard !outputText.isEmpty else {
                if verbose {
                    emit("Skipping fully overlapped transcript: \(result.text)")
                }
                return
            }

            let normalized = normalizeForRepeatDetection(outputText)
            guard !normalized.isEmpty else { return }
            guard !looksLikeDecoderPromptEcho(normalized) else {
                if verbose {
                    emit("Skipping decoder prompt echo: \(result.text)")
                }
                return
            }
            guard !looksLikeCommonSilenceHallucination(normalized) else {
                if verbose {
                    emit("Skipping common silence hallucination: \(result.text)")
                }
                return
            }
            if recentNormalizedOutputs.contains(normalized) {
                if verbose {
                    emit("Skipping repeated transcript: \(outputText)")
                }
                return
            }
            recentNormalizedOutputs.append(normalized)
            if recentNormalizedOutputs.count > 8 {
                recentNormalizedOutputs.removeFirst(recentNormalizedOutputs.count - 8)
            }
            bufferOutput(outputText, language: result.detectedLanguage, startTime: chunkStartTime, endTime: chunkEndTime)
        } catch {
            emit(.system("Transcription failed: \(error.localizedDescription)"))
        }
    }

    private func tickUtteranceMode() async {
        let fresh = ringBuffer.popChunk(seconds: stepSeconds, keepingOverlap: 0)
        guard !fresh.isEmpty else { return }

        let level = AudioLevelMeter.measure(fresh)
        // ScreenCaptureKit/AVAudioConverter can produce a low residual noise floor even
        // when the Mac is audibly silent. Never let that noise trigger a cloud request.
        let effectiveSpeechThreshold = max(silenceThresholdRMS, 0.006)
        let voiceActivity = VoiceActivityDetector.analyze(
            samples: fresh,
            sampleRate: sampleRate,
            rmsThreshold: effectiveSpeechThreshold
        )
        let hasSpeech = level.rms >= effectiveSpeechThreshold && voiceActivity.hasLikelySpeech

        if hasSpeech {
            if !isCapturingUtterance {
                speechCandidateSamples.append(contentsOf: fresh)
                let candidateDuration = Double(speechCandidateSamples.count) / Double(sampleRate)
                guard candidateDuration >= 0.20 else { return }

                isCapturingUtterance = true
                nextUtteranceID &+= 1
                activeUtteranceID = nextUtteranceID
                let preRollDuration = Double(preRollSamples.count) / Double(sampleRate)
                utteranceStartTime = Date().addingTimeInterval(-(preRollDuration + candidateDuration))
                utteranceSamples = preRollSamples + speechCandidateSamples
                speechCandidateSamples.removeAll(keepingCapacity: true)
            } else {
                utteranceSamples.append(contentsOf: fresh)
            }
            trailingSilenceSeconds = 0
            requestPartialTranscriptIfNeeded()

            if utteranceDuration >= utteranceMaxSeconds {
                await finishCurrentUtterance(reason: "max duration")
            }
        } else {
            speechCandidateSamples.removeAll(keepingCapacity: true)
            rememberPreRoll(fresh)

            guard isCapturingUtterance else {
                if verbose {
                    emit(.system(String(format: "Waiting for speech: rms %.6f, speech frames %d/%d", level.rms, voiceActivity.speechFrameCount, voiceActivity.totalFrameCount)))
                }
                return
            }

            utteranceSamples.append(contentsOf: fresh)
            trailingSilenceSeconds += stepSeconds

            if trailingSilenceSeconds >= utteranceEndSilenceSeconds {
                await finishCurrentUtterance(reason: "pause")
            }
        }
    }

    private var utteranceDuration: Double {
        Double(utteranceSamples.count) / Double(sampleRate)
    }

    private func rememberPreRoll(_ samples: [Float]) {
        preRollSamples.append(contentsOf: samples)
        let preRollSeconds = battleModeEnabled ? 0.25 : 0.35
        let maxSamples = Int(preRollSeconds * Double(sampleRate))
        if preRollSamples.count > maxSamples {
            preRollSamples.removeFirst(preRollSamples.count - maxSamples)
        }
    }

    private func finishCurrentUtterance(reason: String) async {
        let samples = utteranceSamples
        let utteranceID = activeUtteranceID
        let duration = Double(samples.count) / Double(sampleRate)
        let capturedTrailingSilence = trailingSilenceSeconds
        isCapturingUtterance = false
        utteranceSamples.removeAll(keepingCapacity: true)
        trailingSilenceSeconds = 0
        preRollSamples.removeAll(keepingCapacity: true)
        speechCandidateSamples.removeAll(keepingCapacity: true)
        lastPartialNormalized = ""

        let minimumDuration = battleModeEnabled ? 0.20 : 0.45
        guard duration >= minimumDuration else {
            if verbose {
                emit(String(format: "Skipping too-short utterance %.2fs", duration))
            }
            return
        }

        let level = AudioLevelMeter.measure(samples)
        guard level.rms >= silenceThresholdRMS else {
            if verbose {
                emit(String(format: "Skipping quiet utterance %.2fs: rms %.6f", duration, level.rms))
            }
            return
        }

        if verbose {
            emit(String(format: "Queueing utterance %.2fs (%@): rms %.6f, %.1f dBFS", duration, reason, level.rms, level.dbFS))
        }

        let endTime = reason == "pause" ? Date().addingTimeInterval(-capturedTrailingSilence) : Date()
        let voiceSampleRate = sampleRate
        let voiceSampleTask = voiceSpeakerTracker.map { tracker in
            Task.detached(priority: .userInitiated) {
                tracker.prepare(samples: samples, sampleRate: voiceSampleRate)
            }
        }
        let utterance = Utterance(
            id: utteranceID,
            samples: samples,
            startTime: utteranceStartTime,
            endTime: endTime,
            voiceSampleTask: voiceSampleTask
        )

        let deferredToPartial: Bool = transcriptionQueueLock.withLock {
            guard battleModeEnabled,
                  isPartialTranscribing,
                  partialUtteranceID == utteranceID else { return false }
            pendingPartialFinal = PendingPartialFinal(
                utterance: utterance,
                partialSampleCount: partialSampleCount
            )
            return true
        }
        if !deferredToPartial {
            enqueueUtterance(utterance)
        }
    }

    private func enqueueUtterance(_ utterance: Utterance) {
        var shouldStartDraining = false
        transcriptionQueueLock.withLock {
            queuedUtterances.append(utterance)
            if !isDrainingTranscriptionQueue {
                isDrainingTranscriptionQueue = true
                shouldStartDraining = true
            }
        }

        if shouldStartDraining {
            Task.detached { [weak self] in
                await self?.drainTranscriptionQueue()
            }
        }
    }

    private func drainTranscriptionQueue() async {
        while true {
            let nextUtterance: Utterance? = transcriptionQueueLock.withLock {
                if queuedUtterances.isEmpty {
                    isDrainingTranscriptionQueue = false
                    return nil
                }
                return queuedUtterances.removeFirst()
            }

            guard let utterance = nextUtterance else { return }
            await transcribeAndPrint(
                utterance.samples,
                startTime: utterance.startTime,
                endTime: utterance.endTime,
                voiceSampleTask: utterance.voiceSampleTask
            )
        }
    }

    private func requestPartialTranscriptIfNeeded() {
        guard battleModeEnabled, partialTranscriptsEnabled, let transcriber else { return }

        let now = Date()
        guard utteranceDuration >= 0.45,
              now.timeIntervalSince(lastPartialRequestTime) >= 0.45 else { return }

        var shouldStart = false
        transcriptionQueueLock.withLock {
            if !isPartialTranscribing {
                isPartialTranscribing = true
                partialUtteranceID = activeUtteranceID
                partialSampleCount = utteranceSamples.count
                lastPartialRequestTime = now
                shouldStart = true
            }
        }
        guard shouldStart else { return }

        let samples = utteranceSamples
        let utteranceID = activeUtteranceID
        let startTime = utteranceStartTime
        let endTime = now

        Task.detached(priority: .userInitiated) { [weak self, transcriber] in
            do {
                let result = try await transcriber.transcribe(samples: samples, sampleRate: self?.sampleRate ?? 16_000)
                await self?.handlePartialTranscriptResult(
                    result,
                    startTime: startTime,
                    endTime: endTime,
                    utteranceID: utteranceID
                )
            } catch {
                self?.finishFailedPartial(for: utteranceID)
                if self?.verbose == true {
                    self?.emit(.system("Partial transcription failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func handlePartialTranscriptResult(
        _ result: TranscriptResult,
        startTime: Date,
        endTime: Date,
        utteranceID: UInt64
    ) async {
        let pendingFinal = finishPartialState(for: utteranceID)

        if let pendingFinal {
            let uncoveredSamples = max(0, pendingFinal.utterance.samples.count - pendingFinal.partialSampleCount)
            let maxUncoveredSamples = Int(0.30 * Double(sampleRate))
            let resultIsUsable = !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && result.noSpeechProbability < 0.40
                && (result.tokenCount == 0 || result.averageTokenProbability >= 0.38)
            if uncoveredSamples <= maxUncoveredSamples && resultIsUsable {
                let voiceSample = await pendingFinal.utterance.voiceSampleTask?.value
                handleTranscriptResult(
                    result,
                    startTime: pendingFinal.utterance.startTime,
                    endTime: pendingFinal.utterance.endTime,
                    voiceSample: voiceSample
                )
                return
            }
            enqueueUtterance(pendingFinal.utterance)
        }

        let outputText = collapseRepeatedPhrases(in: result.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeForRepeatDetection(outputText)
        guard result.noSpeechProbability < 0.40,
              !normalized.isEmpty,
              normalized != lastPartialNormalized,
              !looksLikeDecoderPromptEcho(normalized),
              !looksLikeCommonSilenceHallucination(normalized) else { return }

        lastPartialNormalized = normalized
        emit(makeTranscript(
            originalText: outputText,
            translatedText: translatedText(for: outputText, detectedLanguage: result.detectedLanguage),
            detectedLanguage: result.detectedLanguage,
            isPartial: true,
            startTime: startTime,
            endTime: endTime
        ))
    }

    private func finishPartialState(for utteranceID: UInt64) -> PendingPartialFinal? {
        transcriptionQueueLock.withLock {
            isPartialTranscribing = false
            if partialUtteranceID == utteranceID {
                partialUtteranceID = nil
                partialSampleCount = 0
            }
            guard pendingPartialFinal?.utterance.id == utteranceID else { return nil }
            defer { self.pendingPartialFinal = nil }
            return pendingPartialFinal
        }
    }

    private func finishFailedPartial(for utteranceID: UInt64) {
        let pendingFinal = finishPartialState(for: utteranceID)
        if let pendingFinal {
            enqueueUtterance(pendingFinal.utterance)
        }
    }

    private func transcribeAndPrint(
        _ samples: [Float],
        startTime: Date,
        endTime: Date,
        voiceSampleTask: Task<VoiceSpeakerSample?, Never>?
    ) async {
        guard let transcriber else { return }

        do {
            let result = try await transcriber.transcribe(samples: samples, sampleRate: sampleRate)
            let voiceSample = await voiceSampleTask?.value
            handleTranscriptResult(
                result,
                startTime: startTime,
                endTime: endTime,
                voiceSample: voiceSample
            )
        } catch {
            emit(.system("Transcription failed: \(error.localizedDescription)"))
        }
    }

    private func handleTranscriptResult(
        _ result: TranscriptResult,
        startTime: Date,
        endTime: Date,
        voiceSample: VoiceSpeakerSample? = nil
    ) {
        guard result.noSpeechProbability < 0.40 else {
            if verbose {
                emit(String(format: "Skipping no-speech result: p %.2f, text: %@", result.noSpeechProbability, result.text))
            }
            return
        }

        guard !result.text.isEmpty else {
            if verbose {
                let language = result.detectedLanguage ?? "unknown"
                emit("[detected: \(language)] no speech text returned")
            }
            return
        }

        let minimumTokenProbability: Float = battleModeEnabled ? 0.25 : 0.38
        guard result.tokenCount == 0 || result.averageTokenProbability >= minimumTokenProbability else {
            if verbose {
                emit(String(format: "Skipping low-confidence transcript: p %.2f, tokens %d, text: %@", result.averageTokenProbability, result.tokenCount, result.text))
            }
            return
        }

        let outputText = collapseRepeatedPhrases(in: result.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeForRepeatDetection(outputText)
        guard !normalized.isEmpty else { return }

        guard !looksLikeDecoderPromptEcho(normalized) else { return }
        guard !looksLikeCommonSilenceHallucination(normalized) else { return }
        if !realtimeUtteranceMode, recentNormalizedOutputs.contains(normalized) {
            if verbose {
                emit("Skipping repeated transcript: \(outputText)")
            }
            return
        }

        recentNormalizedOutputs.append(normalized)
        if recentNormalizedOutputs.count > 8 {
            recentNormalizedOutputs.removeFirst(recentNormalizedOutputs.count - 8)
        }
        rememberPrintedWords(outputText)

        let voiceAttribution = voiceSample.flatMap { voiceSpeakerTracker?.attribute(sample: $0) }
        if let voiceAttribution {
            emit(.voiceAttributed(
                voiceAttribution,
                originalText: outputText,
                translatedText: translatedText(for: outputText, detectedLanguage: result.detectedLanguage),
                detectedLanguage: result.detectedLanguage,
                startTime: startTime.timeIntervalSinceReferenceDate,
                endTime: endTime.timeIntervalSinceReferenceDate
            ))
        } else if enableSpeakerAttribution, let tracker = speakerTracker, let profile = activeProfile {
            let overlapping = tracker.getStatesOverlapping(from: startTime, to: endTime)
            let attr = SpeakerAttributionScorer.attribute(
                speechStart: startTime,
                speechEnd: endTime,
                states: overlapping,
                profile: profile
            )

            transcriptionQueueLock.withLock {
                _lastAttributionResult = attr
                _lastSegmentStart = startTime
                _lastSegmentEnd = endTime
            }

            emit(makeAttributedTranscript(
                attribution: attr,
                originalText: outputText,
                translatedText: translatedText(for: outputText, detectedLanguage: result.detectedLanguage),
                detectedLanguage: result.detectedLanguage,
                isPartial: false,
                startTime: startTime,
                endTime: endTime,
                profile: profile,
                overlappingStates: overlapping
            ))
        } else {
            emit(makeTranscript(
                originalText: outputText,
                translatedText: translatedText(for: outputText, detectedLanguage: result.detectedLanguage),
                detectedLanguage: result.detectedLanguage,
                isPartial: false,
                startTime: startTime,
                endTime: endTime
            ))
        }
    }

    private func normalizeForRepeatDetection(_ text: String) -> String {
        text
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func collapseRepeatedPhrases(in text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return text }

        var changed = true
        while changed {
            changed = false
            var index = 0

            while index < words.count {
                let maxPhraseLength = min(6, (words.count - index) / 2)
                var removed = false

                if maxPhraseLength > 0 {
                    for length in stride(from: maxPhraseLength, through: 1, by: -1) {
                        let first = Array(words[index..<(index + length)]).map(normalizeWord)
                        let second = Array(words[(index + length)..<(index + 2 * length)]).map(normalizeWord)

                        if !first.contains(""), wordsMatch(first, second) {
                            words.removeSubrange((index + length)..<(index + 2 * length))
                            changed = true
                            removed = true
                            break
                        }
                    }
                }

                if !removed {
                    index += 1
                }
            }
        }

        return words.joined(separator: " ")
    }

    private func removeAlreadyPrintedPrefix(from text: String) -> String {
        let originalWords = text.split(separator: " ").map(String.init)
        let normalizedWords = originalWords.map(normalizeWord).filter { !$0.isEmpty }
        guard !normalizedWords.isEmpty, !recentPrintedWords.isEmpty else {
            return text
        }

        let maxOverlap = min(normalizedWords.count, recentPrintedWords.count, 24)
        var bestOverlap = 0
        if maxOverlap > 0 {
            for count in stride(from: maxOverlap, through: 1, by: -1) {
                let tail = Array(recentPrintedWords.suffix(count))
                let prefix = Array(normalizedWords.prefix(count))
                if wordsMatch(tail, prefix) {
                    bestOverlap = count
                    break
                }
            }
        }

        guard bestOverlap > 0 else {
            return text
        }

        let remaining = originalWords.dropFirst(bestOverlap).joined(separator: " ")
        return remaining.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rememberPrintedWords(_ text: String) {
        let words = text
            .split(separator: " ")
            .map { normalizeWord(String($0)) }
            .filter { !$0.isEmpty }

        recentPrintedWords.append(contentsOf: words)
        if recentPrintedWords.count > 80 {
            recentPrintedWords.removeFirst(recentPrintedWords.count - 80)
        }
    }

    private func normalizeWord(_ word: String) -> String {
        word
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func wordsMatch(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            if !wordsAreSimilar(left, right) {
                return false
            }
        }
        return true
    }

    private func wordsAreSimilar(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs {
            return true
        }
        if lhs.count >= 5, rhs.count >= 5, levenshteinDistance(lhs, rhs, maxDistance: 1) <= 1 {
            return true
        }
        return false
    }

    private func levenshteinDistance(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if abs(left.count - right.count) > maxDistance {
            return maxDistance + 1
        }

        var previous = Array(0...right.count)
        for i in 1...left.count {
            var current = [i] + Array(repeating: 0, count: right.count)
            var rowMinimum = current[0]

            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
                rowMinimum = min(rowMinimum, current[j])
            }

            if rowMinimum > maxDistance {
                return maxDistance + 1
            }
            previous = current
        }

        return previous[right.count]
    }

    private func looksLikeDecoderPromptEcho(_ normalizedText: String) -> Bool {
        normalizedText.contains("ignore game music") ||
            normalizedText.contains("gunshots explosions") ||
            normalizedText.contains("clear spoken voice chat")
    }

    private func looksLikeCommonSilenceHallucination(_ normalizedText: String) -> Bool {
        normalizedText.contains("thank you for watching") ||
            normalizedText.contains("thanks for watching") ||
            normalizedText.contains("have a nice day") ||
            normalizedText.contains("dont forget to subscribe") ||
            normalizedText.contains("like and subscribe")
    }

    private func bufferOutput(_ text: String, language: String?, startTime: Date, endTime: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if pendingOutput.isEmpty {
            pendingOutput = trimmed
            pendingLanguage = language
            pendingStartTime = startTime
        } else {
            pendingOutput += needsLeadingSpace(before: trimmed) ? " \(trimmed)" : trimmed
            pendingLanguage = pendingLanguage ?? language
        }
        pendingEndTime = endTime

        flushPendingOutputIfUseful(force: false)
    }

    private func flushPendingOutputIfUseful(force: Bool) {
        let trimmed = pendingOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let words = trimmed.split(separator: " ")
        let endsWithSentencePunctuation = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
        let endsWithPartialWord = trimmed.hasSuffix("-")

        if endsWithPartialWord && !force {
            return
        }

        let shouldFlush =
            (endsWithSentencePunctuation && words.count >= 3) ||
            words.count >= 7 ||
            (force && words.count >= 3)

        guard shouldFlush else { return }

        if enableSpeakerAttribution, let tracker = speakerTracker, let profile = activeProfile {
            let overlapping = tracker.getStatesOverlapping(from: pendingStartTime, to: pendingEndTime)
            let attr = SpeakerAttributionScorer.attribute(
                speechStart: pendingStartTime,
                speechEnd: pendingEndTime,
                states: overlapping,
                profile: profile
            )

            transcriptionQueueLock.withLock {
                _lastAttributionResult = attr
                _lastSegmentStart = pendingStartTime
                _lastSegmentEnd = pendingEndTime
            }

            emit(makeAttributedTranscript(
                attribution: attr,
                originalText: trimmed,
                translatedText: translatedText(for: trimmed, detectedLanguage: pendingLanguage),
                detectedLanguage: pendingLanguage,
                isPartial: false,
                startTime: pendingStartTime,
                endTime: pendingEndTime,
                profile: profile,
                overlappingStates: overlapping
            ))
        } else {
            emit(makeTranscript(
                originalText: trimmed,
                translatedText: translatedText(for: trimmed, detectedLanguage: pendingLanguage),
                detectedLanguage: pendingLanguage,
                isPartial: false,
                startTime: pendingStartTime,
                endTime: pendingEndTime
            ))
        }
        rememberPrintedWords(trimmed)
        pendingOutput = ""
        pendingLanguage = nil
    }

    private func emit(_ transcript: AttributedTranscript) {
        onOutput(transcript)
    }

    private func makeTranscript(
        originalText: String,
        translatedText: String?,
        detectedLanguage: String?,
        isPartial: Bool,
        startTime: Date,
        endTime: Date
    ) -> AttributedTranscript {
        if enableSpeakerAttribution, let tracker = speakerTracker, let profile = activeProfile {
            let overlapping = tracker.getStatesOverlapping(from: startTime, to: endTime)
            let attr = SpeakerAttributionScorer.attribute(
                speechStart: startTime,
                speechEnd: endTime,
                states: overlapping,
                profile: profile
            )

            transcriptionQueueLock.withLock {
                _lastAttributionResult = attr
                _lastSegmentStart = startTime
                _lastSegmentEnd = endTime
            }

            return makeAttributedTranscript(
                attribution: attr,
                originalText: originalText,
                translatedText: translatedText,
                detectedLanguage: detectedLanguage,
                isPartial: isPartial,
                startTime: startTime,
                endTime: endTime,
                profile: profile,
                overlappingStates: overlapping
            )
        }

        return .unattributed(
            originalText: originalText,
            translatedText: translatedText,
            detectedLanguage: detectedLanguage,
            isPartial: isPartial,
            startTime: startTime.timeIntervalSinceReferenceDate,
            endTime: endTime.timeIntervalSinceReferenceDate
        )
    }

    private func makeAttributedTranscript(
        attribution: AttributionResult,
        originalText: String,
        translatedText: String?,
        detectedLanguage: String?,
        isPartial: Bool,
        startTime: Date,
        endTime: Date,
        profile: GameProfile,
        overlappingStates: [SpeakerState]
    ) -> AttributedTranscript {
        let hadStale = overlappingStates.contains(where: { $0.continuousVisibleDuration > profile.staleThreshold })
        return .from(
            result: attribution,
            originalText: originalText,
            translatedText: translatedText,
            detectedLanguage: detectedLanguage,
            isPartial: isPartial,
            startTime: startTime.timeIntervalSinceReferenceDate,
            endTime: endTime.timeIntervalSinceReferenceDate,
            profile: profile,
            hadStaleCandidate: hadStale
        )
    }

    private func translatedText(for text: String, detectedLanguage: String?) -> String? {
        guard let targetLanguage else { return nil }
        if targetLanguage == "en" {
            return text
        }
        guard detectedLanguage?.lowercased() == targetLanguage else { return nil }
        return text
    }

    /// Emits a plain-text system/verbose message as a system AttributedTranscript.
    private func emit(_ text: String) {
        onOutput(.system(text))
    }


    private func needsLeadingSpace(before text: String) -> Bool {
        guard let first = text.first else { return false }
        return first != "." && first != "," && first != "!" && first != "?"
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
