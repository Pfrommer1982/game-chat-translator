import Foundation
import Testing
@testable import GameChatTranslatorCore

@Suite("Automatic source language")
struct AutomaticLanguageSchedulerTests {
    private final class NamedLanguageTranscriber: AudioTranscribing {
        func transcribe(samples: [Float], sampleRate: Int) async throws -> TranscriptResult {
            TranscriptResult(
                text: "Move left now.",
                detectedLanguage: "English",
                durationSeconds: Double(samples.count) / Double(sampleRate),
                averageTokenProbability: 1,
                tokenCount: 3
            )
        }
    }

    private final class RecordingTranscriber: AudioTranscribing, @unchecked Sendable {
        private let lock = NSLock()
        private var sampleCounts: [Int] = []

        func transcribe(samples: [Float], sampleRate: Int) async throws -> TranscriptResult {
            lock.synchronized {
                sampleCounts.append(samples.count)
            }
            return TranscriptResult(
                text: "Keep the sentence together.",
                detectedLanguage: "English",
                durationSeconds: Double(samples.count) / Double(sampleRate),
                averageTokenProbability: 1,
                tokenCount: 4
            )
        }

        var recordedSampleCounts: [Int] {
            lock.synchronized { sampleCounts }
        }
    }

    private final class DelayedSequenceTranscriber: AudioTranscribing, @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0

        func transcribe(samples: [Float], sampleRate: Int) async throws -> TranscriptResult {
            try await Task.sleep(nanoseconds: 1_100_000_000)
            let call = lock.synchronized {
                callCount += 1
                return callCount
            }
            return TranscriptResult(
                text: "Line \(call)",
                detectedLanguage: "en",
                durationSeconds: Double(samples.count) / Double(sampleRate),
                averageTokenProbability: 1,
                tokenCount: 2
            )
        }
    }

    private final class NoSpeechTranscriber: AudioTranscribing {
        func transcribe(samples: [Float], sampleRate: Int) async throws -> TranscriptResult {
            TranscriptResult(
                text: "Thank you for watching.",
                detectedLanguage: "en",
                durationSeconds: Double(samples.count) / Double(sampleRate),
                averageTokenProbability: 0.95,
                noSpeechProbability: 0.82,
                tokenCount: 4
            )
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [AttributedTranscript] = []

        func append(_ value: AttributedTranscript) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var transcripts: [AttributedTranscript] {
            lock.lock()
            defer { lock.unlock() }
            return values.filter { !$0.isSystemMessage }
        }
    }

    @Test("Provider language names are not discarded")
    func emitsProviderLanguageNames() async throws {
        let sampleRate = 16_000
        let ringBuffer = AudioRingBuffer(sampleRate: sampleRate, maxDurationSeconds: 3)
        let collector = OutputCollector()
        let scheduler = TranscriptionScheduler(
            ringBuffer: ringBuffer,
            transcriber: NamedLanguageTranscriber(),
            sampleRate: sampleRate,
            silenceThresholdRMS: 0.001,
            realtimeUtteranceMode: true,
            utteranceEndSilenceSeconds: 0.4,
            utteranceMaxSeconds: 2,
            targetLanguage: "en",
            partialTranscriptsEnabled: false,
            onOutput: { collector.append($0) }
        )

        let voice = (0..<Int(0.8 * Double(sampleRate))).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)) * 0.2)
        }
        ringBuffer.append(voice + Array(repeating: 0, count: Int(0.8 * Double(sampleRate))))
        scheduler.start()
        defer { scheduler.stop() }

        for _ in 0..<30 where collector.transcripts.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(collector.transcripts.first?.translatedText == "Move left now.")
        #expect(collector.transcripts.first?.detectedLanguage == "English")
    }

    @Test("Whisper no-speech results are not emitted")
    func rejectsNoSpeechHallucinations() async throws {
        let sampleRate = 16_000
        let ringBuffer = AudioRingBuffer(sampleRate: sampleRate, maxDurationSeconds: 3)
        let collector = OutputCollector()
        let scheduler = TranscriptionScheduler(
            ringBuffer: ringBuffer,
            transcriber: NoSpeechTranscriber(),
            sampleRate: sampleRate,
            silenceThresholdRMS: 0.001,
            realtimeUtteranceMode: true,
            utteranceEndSilenceSeconds: 0.22,
            utteranceMaxSeconds: 2,
            targetLanguage: "en",
            partialTranscriptsEnabled: false,
            onOutput: { collector.append($0) }
        )

        ringBuffer.append(utterance(sampleRate: sampleRate))
        scheduler.start()
        defer { scheduler.stop() }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(collector.transcripts.isEmpty)
    }

    @Test("Low converter noise never reaches the transcriber")
    func rejectsResidualSilenceNoise() async throws {
        let sampleRate = 16_000
        let ringBuffer = AudioRingBuffer(sampleRate: sampleRate, maxDurationSeconds: 3)
        let transcriber = RecordingTranscriber()
        let scheduler = TranscriptionScheduler(
            ringBuffer: ringBuffer,
            transcriber: transcriber,
            sampleRate: sampleRate,
            silenceThresholdRMS: 0.001,
            realtimeUtteranceMode: true,
            utteranceEndSilenceSeconds: 0.22,
            partialTranscriptsEnabled: false
        )

        let residualNoise = (0..<sampleRate).map { index in
            Float(sin(2 * Double.pi * 120 * Double(index) / Double(sampleRate)) * 0.004)
        }
        ringBuffer.append(residualNoise)
        scheduler.start()
        defer { scheduler.stop() }
        try await Task.sleep(nanoseconds: 1_200_000_000)

        #expect(transcriber.recordedSampleCounts.isEmpty)
    }

    @Test("Brief pauses do not split a battle-mode sentence")
    func keepsBriefPausesInsideUtterance() async throws {
        let sampleRate = 16_000
        let ringBuffer = AudioRingBuffer(sampleRate: sampleRate, maxDurationSeconds: 3)
        let transcriber = RecordingTranscriber()
        let collector = OutputCollector()
        let scheduler = TranscriptionScheduler(
            ringBuffer: ringBuffer,
            transcriber: transcriber,
            sampleRate: sampleRate,
            silenceThresholdRMS: 0.001,
            realtimeUtteranceMode: true,
            utteranceEndSilenceSeconds: 0.25,
            utteranceMaxSeconds: 4,
            battleModeEnabled: true,
            targetLanguage: "en",
            partialTranscriptsEnabled: false,
            onOutput: { collector.append($0) }
        )

        func tone(seconds: Double) -> [Float] {
            (0..<Int(seconds * Double(sampleRate))).map { index in
                Float(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)) * 0.2)
            }
        }

        let briefPause = Array(repeating: Float(0), count: Int(0.2 * Double(sampleRate)))
        let finalPause = Array(repeating: Float(0), count: Int(0.5 * Double(sampleRate)))
        ringBuffer.append(tone(seconds: 0.5) + briefPause + tone(seconds: 0.5) + finalPause)
        scheduler.start()
        defer { scheduler.stop() }

        for _ in 0..<30 where transcriber.recordedSampleCounts.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(transcriber.recordedSampleCounts.count == 1)
        #expect((transcriber.recordedSampleCounts.first ?? 0) >= Int(1.3 * Double(sampleRate)))
    }

    @Test("Repeated gameplay commands are not discarded as duplicates")
    func keepsRepeatedCommands() async throws {
        let sampleRate = 16_000
        let ringBuffer = AudioRingBuffer(sampleRate: sampleRate, maxDurationSeconds: 4)
        let collector = OutputCollector()
        let scheduler = TranscriptionScheduler(
            ringBuffer: ringBuffer,
            transcriber: NamedLanguageTranscriber(),
            sampleRate: sampleRate,
            silenceThresholdRMS: 0.001,
            realtimeUtteranceMode: true,
            utteranceEndSilenceSeconds: 0.22,
            utteranceMaxSeconds: 3,
            battleModeEnabled: true,
            targetLanguage: "en",
            partialTranscriptsEnabled: false,
            onOutput: { collector.append($0) }
        )
        scheduler.start()
        defer { scheduler.stop() }

        ringBuffer.append(utterance(sampleRate: sampleRate))
        for _ in 0..<30 where collector.transcripts.count < 1 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        ringBuffer.append(utterance(sampleRate: sampleRate))
        for _ in 0..<30 where collector.transcripts.count < 2 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(collector.transcripts.count == 2)
    }

    @Test("Battle mode preserves short utterances while transcription is busy")
    func preservesQueuedUtterances() async throws {
        let sampleRate = 16_000
        let ringBuffer = AudioRingBuffer(sampleRate: sampleRate, maxDurationSeconds: 5)
        let collector = OutputCollector()
        let scheduler = TranscriptionScheduler(
            ringBuffer: ringBuffer,
            transcriber: DelayedSequenceTranscriber(),
            sampleRate: sampleRate,
            silenceThresholdRMS: 0.001,
            realtimeUtteranceMode: true,
            utteranceEndSilenceSeconds: 0.22,
            utteranceMaxSeconds: 3,
            battleModeEnabled: true,
            targetLanguage: "en",
            partialTranscriptsEnabled: false,
            onOutput: { collector.append($0) }
        )

        let audio = utterance(sampleRate: sampleRate)
            + utterance(sampleRate: sampleRate)
            + utterance(sampleRate: sampleRate)
        ringBuffer.append(audio)
        scheduler.start()
        defer { scheduler.stop() }

        for _ in 0..<60 where collector.transcripts.count < 3 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(collector.transcripts.map(\.originalText) == ["Line 1", "Line 2", "Line 3"])
    }

    private func utterance(sampleRate: Int) -> [Float] {
        let voice = (0..<Int(0.32 * Double(sampleRate))).map { index in
            Float(sin(2 * Double.pi * 180 * Double(index) / Double(sampleRate)) * 0.18)
        }
        return voice + Array(repeating: 0, count: Int(0.52 * Double(sampleRate)))
    }
}

private extension NSLock {
    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
