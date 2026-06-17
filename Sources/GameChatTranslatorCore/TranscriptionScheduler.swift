import Foundation

public final class TranscriptionScheduler {
    private let ringBuffer: AudioRingBuffer
    private let transcriber: WhisperTranscriber?
    private let chunkSeconds: Double
    private let overlapSeconds: Double
    private let sampleRate: Int
    private let silenceThresholdRMS: Float
    private let realtimeUtteranceMode: Bool
    private let utteranceEndSilenceSeconds: Double
    private let utteranceMaxSeconds: Double
    private let verbose: Bool
    private let onOutput: @Sendable (String) -> Void
    private var isRunning = false
    private var isTranscribing = false
    private var recentNormalizedOutputs: [String] = []
    private var recentPrintedWords: [String] = []
    private var pendingOutput = ""
    private var pendingLanguage: String?
    private var isCapturingUtterance = false
    private var utteranceSamples: [Float] = []
    private var preRollSamples: [Float] = []
    private var trailingSilenceSeconds = 0.0
    private let transcriptionQueueLock = NSLock()
    private var queuedUtterances: [[Float]] = []
    private var isDrainingTranscriptionQueue = false

    private var stepSeconds: Double {
        realtimeUtteranceMode ? 0.2 : max(0.5, chunkSeconds - overlapSeconds)
    }

    public init(
        ringBuffer: AudioRingBuffer,
        transcriber: WhisperTranscriber?,
        chunkSeconds: Double = 5,
        overlapSeconds: Double = 0.5,
        sampleRate: Int = 16_000,
        silenceThresholdRMS: Float = 0.001,
        realtimeUtteranceMode: Bool = false,
        utteranceEndSilenceSeconds: Double = 0.55,
        utteranceMaxSeconds: Double = 6.0,
        verbose: Bool = false,
        onOutput: @escaping @Sendable (String) -> Void = { print($0) }
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
            if let language = result.detectedLanguage,
               isLikelyBadLanguageDetection(language) {
                if verbose {
                    emit("Skipping unlikely detected language \(language): \(outputText)")
                }
                return
            }
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
            bufferOutput(outputText, language: result.detectedLanguage)
        } catch {
            emit("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func tickUtteranceMode() async {
        let fresh = ringBuffer.popChunk(seconds: stepSeconds, keepingOverlap: 0)
        guard !fresh.isEmpty else { return }

        let level = AudioLevelMeter.measure(fresh)
        let voiceActivity = VoiceActivityDetector.analyze(
            samples: fresh,
            sampleRate: sampleRate,
            rmsThreshold: silenceThresholdRMS
        )
        let hasSpeech = level.rms >= silenceThresholdRMS && voiceActivity.hasLikelySpeech

        if hasSpeech {
            if !isCapturingUtterance {
                isCapturingUtterance = true
                utteranceSamples = preRollSamples
            }
            utteranceSamples.append(contentsOf: fresh)
            trailingSilenceSeconds = 0

            if utteranceDuration >= utteranceMaxSeconds {
                await finishCurrentUtterance(reason: "max duration")
            }
        } else {
            rememberPreRoll(fresh)

            guard isCapturingUtterance else {
                if verbose {
                    emit(String(format: "Waiting for speech: rms %.6f, speech frames %d/%d", level.rms, voiceActivity.speechFrameCount, voiceActivity.totalFrameCount))
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
        let maxSamples = Int(0.35 * Double(sampleRate))
        if preRollSamples.count > maxSamples {
            preRollSamples.removeFirst(preRollSamples.count - maxSamples)
        }
    }

    private func finishCurrentUtterance(reason: String) async {
        let samples = utteranceSamples
        let duration = Double(samples.count) / Double(sampleRate)
        isCapturingUtterance = false
        utteranceSamples.removeAll(keepingCapacity: true)
        trailingSilenceSeconds = 0
        preRollSamples.removeAll(keepingCapacity: true)

        guard duration >= 0.55 else {
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

        enqueueUtterance(samples)
    }

    private func enqueueUtterance(_ samples: [Float]) {
        var shouldStartDraining = false
        transcriptionQueueLock.withLock {
            queuedUtterances.append(samples)
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
            let nextUtterance: [Float]? = transcriptionQueueLock.withLock {
                if queuedUtterances.isEmpty {
                    isDrainingTranscriptionQueue = false
                    return nil
                }
                return queuedUtterances.removeFirst()
            }

            guard let samples = nextUtterance else { return }
            await transcribeAndPrint(samples)
        }
    }

    private func transcribeAndPrint(_ samples: [Float]) async {
        guard let transcriber else { return }

        do {
            let result = try await transcriber.transcribe(samples: samples, sampleRate: sampleRate)
            handleTranscriptResult(result)
        } catch {
            emit("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func handleTranscriptResult(_ result: TranscriptResult) {
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

        let outputText = collapseRepeatedPhrases(in: result.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeForRepeatDetection(outputText)
        guard !normalized.isEmpty else { return }

        if let language = result.detectedLanguage,
           isLikelyBadLanguageDetection(language) {
            if verbose {
                emit("Skipping unlikely detected language \(language): \(outputText)")
            }
            return
        }
        guard !looksLikeDecoderPromptEcho(normalized) else { return }
        guard !looksLikeCommonSilenceHallucination(normalized) else { return }
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
        rememberPrintedWords(outputText)

        let language = result.detectedLanguage ?? "unknown"
        emit("[detected: \(language)] \(outputText)")
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

    private func isLikelyBadLanguageDetection(_ language: String) -> Bool {
        let allowedLanguages: Set<String> = [
            "en", "nl", "de", "fr", "es", "it", "pt", "ru", "ar", "pl", "tr", "uk"
        ]
        return !allowedLanguages.contains(language.lowercased())
    }

    private func bufferOutput(_ text: String, language: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if pendingOutput.isEmpty {
            pendingOutput = trimmed
            pendingLanguage = language
        } else {
            pendingOutput += needsLeadingSpace(before: trimmed) ? " \(trimmed)" : trimmed
            pendingLanguage = pendingLanguage ?? language
        }

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

        let language = pendingLanguage ?? "unknown"
        emit("[detected: \(language)] \(trimmed)")
        rememberPrintedWords(trimmed)
        pendingOutput = ""
        pendingLanguage = nil
    }

    private func emit(_ line: String) {
        onOutput(line)
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
