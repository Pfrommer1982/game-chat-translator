import CoreMedia
import Foundation

struct AppConfiguration {
    let modelPath: String?
    let chunkSeconds: Double
    let bufferSeconds: Double
    let overlapSeconds: Double
    let language: String
    let translateToEnglish: Bool
    let realtime: Bool
    let threadCount: Int
    let utteranceEndSilenceSeconds: Double
    let utteranceMaxSeconds: Double
    let silenceThreshold: Float
    let verbose: Bool

    static func parse(arguments: [String]) throws -> AppConfiguration {
        var modelPath: String?
        var chunkSeconds: Double = 5
        var bufferSeconds: Double = 15
        var overlapSeconds: Double = 1
        var language = "auto"
        var translateToEnglish = false
        var realtime = false
        var threadCount = 4
        var utteranceEndSilenceSeconds = 0.55
        var utteranceMaxSeconds = 6.0
        var silenceThreshold: Float = 0.001
        var verbose = false

        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--model":
                index += 1
                guard index < arguments.count else { throw AppError.argument("--model requires a path") }
                modelPath = arguments[index]
            case "--chunk-seconds":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
                    throw AppError.argument("--chunk-seconds requires a positive number")
                }
                chunkSeconds = value
            case "--buffer-seconds":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
                    throw AppError.argument("--buffer-seconds requires a positive number")
                }
                bufferSeconds = value
            case "--overlap-seconds":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value >= 0 else {
                    throw AppError.argument("--overlap-seconds requires a non-negative number")
                }
                overlapSeconds = value
            case "--language":
                index += 1
                guard index < arguments.count else { throw AppError.argument("--language requires a value") }
                language = arguments[index]
            case "--translate-to":
                index += 1
                guard index < arguments.count else { throw AppError.argument("--translate-to requires a value") }
                let target = arguments[index].lowercased()
                guard target == "en" || target == "english" || target == "none" || target == "off" else {
                    throw AppError.argument("--translate-to currently supports only en or none")
                }
                translateToEnglish = target == "en" || target == "english"
            case "--realtime":
                realtime = true
                if chunkSeconds == 5 {
                    chunkSeconds = 2.0
                }
                if bufferSeconds == 15 {
                    bufferSeconds = 20.0
                }
                if overlapSeconds == 1 {
                    overlapSeconds = 1.7
                }
                if silenceThreshold == 0.001 {
                    silenceThreshold = 0.003
                }
            case "--utterance-end-silence":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
                    throw AppError.argument("--utterance-end-silence requires a positive number")
                }
                utteranceEndSilenceSeconds = value
            case "--utterance-max-seconds":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
                    throw AppError.argument("--utterance-max-seconds requires a positive number")
                }
                utteranceMaxSeconds = value
            case "--threads":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw AppError.argument("--threads requires a positive integer")
                }
                threadCount = value
            case "--silence-threshold":
                index += 1
                guard index < arguments.count, let value = Float(arguments[index]), value >= 0 else {
                    throw AppError.argument("--silence-threshold requires a non-negative number")
                }
                silenceThreshold = value
            case "--verbose":
                verbose = true
            case "--help", "-h":
                throw AppError.help
            default:
                throw AppError.argument("Unknown argument: \(arg)")
            }
            index += 1
        }

        return AppConfiguration(
            modelPath: modelPath,
            chunkSeconds: chunkSeconds,
            bufferSeconds: bufferSeconds,
            overlapSeconds: overlapSeconds,
            language: language,
            translateToEnglish: translateToEnglish,
            realtime: realtime,
            threadCount: threadCount,
            utteranceEndSilenceSeconds: utteranceEndSilenceSeconds,
            utteranceMaxSeconds: utteranceMaxSeconds,
            silenceThreshold: silenceThreshold,
            verbose: verbose
        )
    }
}

enum AppError: Error, LocalizedError {
    case argument(String)
    case help

    var errorDescription: String? {
        switch self {
        case .argument(let message):
            return message + "\n\n" + Self.usage
        case .help:
            return Self.usage
        }
    }

    static let usage = """
    Usage:
      swift run SystemAudioTranscriber --model ./models/ggml-base.bin [options]

    Options:
      --model <path>              Enable milestone 2 transcription with a local whisper.cpp model.
      --chunk-seconds <number>    Transcription chunk size. Default: 5.
      --buffer-seconds <number>   Rolling RAM buffer size. Default: 15.
      --overlap-seconds <number>  Audio overlap between chunks. Default: 1.
      --language <auto|en|nl|de>  Whisper language. Default: auto.
      --translate-to <en|none>    Translate recognized speech to English locally. Default: none.
      --realtime                  Use lower-latency decoder defaults for live game chat.
      --threads <number>          Whisper CPU threads. Default: 4.
      --utterance-end-silence <s> Silence that ends a live utterance. Default: 0.55.
      --utterance-max-seconds <s> Max live utterance length. Default: 6.
      --silence-threshold <rms>   Skip chunks below RMS. Default: 0.001.
      --verbose                   Print audio level once per second and silence-skip details.

    Without --model, the app runs milestone 1 capture/debug mode only.
    """
}

do {
    let config = try AppConfiguration.parse(arguments: CommandLine.arguments)
    try await run(config)
} catch AppError.help {
    print(AppError.usage)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}

private func run(_ config: AppConfiguration) async throws {
    let sampleRate = 16_000
    let ringBuffer = AudioRingBuffer(sampleRate: sampleRate, maxDurationSeconds: config.bufferSeconds)
    let converter = PCMConverter(targetSampleRate: Double(sampleRate), targetChannels: 1)

    let transcriber: WhisperTranscriber?
    if let modelPath = config.modelPath {
        fputs("Loading whisper model: \(modelPath)\n", stderr)
        fflush(stderr)
        transcriber = try WhisperTranscriber(
            modelPath: modelPath,
            language: config.language,
            translateToEnglish: config.translateToEnglish,
            realtimeMode: config.realtime,
            threadCount: config.threadCount
        )
        fputs("Model loaded.\n", stderr)
        fflush(stderr)
    } else {
        transcriber = nil
    }

    let scheduler = TranscriptionScheduler(
        ringBuffer: ringBuffer,
        transcriber: transcriber,
        chunkSeconds: config.chunkSeconds,
        overlapSeconds: config.overlapSeconds,
        sampleRate: sampleRate,
        silenceThresholdRMS: config.silenceThreshold,
        realtimeUtteranceMode: config.realtime,
        utteranceEndSilenceSeconds: config.utteranceEndSilenceSeconds,
        utteranceMaxSeconds: config.utteranceMaxSeconds,
        verbose: config.verbose
    )

    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)

    let startedAt = Date()
    var lastDebugPrint = Date.distantPast
    var lastSilenceWarning = Date.distantPast
    var hasSeenNonSilentAudio = false

    let capture = SystemAudioCapture { sampleBuffer in
        do {
            let samples = try converter.convert(sampleBuffer)
            ringBuffer.append(samples)

            let level = AudioLevelMeter.measure(samples)
            if level.rms > 0.000_01 {
                hasSeenNonSilentAudio = true
            }

            let now = Date()
            if config.verbose,
               now.timeIntervalSince(lastDebugPrint) >= 1,
               let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
                lastDebugPrint = now
                let duration = Double(samples.count) / Double(sampleRate)
                print(String(
                    format: "sampleRate %.0f Hz, channels %u, buffer %.3fs, rms %.6f, %.1f dBFS, rolling %.2fs",
                    asbd.mSampleRate,
                    asbd.mChannelsPerFrame,
                    duration,
                    level.rms,
                    level.dbFS,
                    ringBuffer.durationSeconds
                ))
            }

            if !hasSeenNonSilentAudio,
               now.timeIntervalSince(startedAt) >= 5,
               now.timeIntervalSince(lastSilenceWarning) >= 5 {
                lastSilenceWarning = now
                print("No non-silent system audio detected yet. Make sure YouTube is audibly playing and this terminal has Screen & System Audio Recording permission.")
            }
        } catch {
            if config.verbose {
                print("PCM conversion skipped buffer: \(error.localizedDescription)")
            }
        }
    }

    print("Listening to system audio...")
    print("Audio: 16000 Hz mono Float32")
    print(String(format: "Buffer: %.1fs", config.chunkSeconds))

    scheduler.start()
    try await capture.start()

    await withCheckedContinuation { continuation in
        signalSource.setEventHandler {
            scheduler.stop()
            continuation.resume()
        }
        signalSource.resume()
    }

    await capture.stop()
}
