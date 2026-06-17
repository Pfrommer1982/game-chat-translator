import AVFoundation
import CoreMedia
import Foundation

enum PCMConverterError: Error, LocalizedError {
    case missingFormatDescription
    case unsupportedFormat
    case blockBufferUnavailable(OSStatus)
    case converterCreationFailed
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFormatDescription:
            return "Audio sample buffer did not include a format description."
        case .unsupportedFormat:
            return "Unsupported audio format from ScreenCaptureKit."
        case .blockBufferUnavailable(let status):
            return "Could not access audio block buffer. OSStatus: \(status)"
        case .converterCreationFailed:
            return "Could not create AVAudioConverter for system audio."
        case .conversionFailed(let message):
            return "Audio conversion failed: \(message)"
        }
    }
}

final class PCMConverter {
    private let targetSampleRate: Double
    private let targetChannels: AVAudioChannelCount
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(targetSampleRate: Double = 16_000, targetChannels: AVAudioChannelCount = 1) {
        self.targetSampleRate = targetSampleRate
        self.targetChannels = targetChannels
    }

    func convert(_ sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              var streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            throw PCMConverterError.missingFormatDescription
        }

        guard let inputFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            throw PCMConverterError.unsupportedFormat
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return [] }

        let inputBuffer = try makePCMBuffer(from: sampleBuffer, format: inputFormat, frameCount: frameCount)
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        )!

        if inputFormat.sampleRate == targetSampleRate,
           inputFormat.channelCount == targetChannels,
           inputFormat.commonFormat == .pcmFormatFloat32,
           inputFormat.isInterleaved == false {
            return extractMonoFloatSamples(inputBuffer)
        }

        let activeConverter: AVAudioConverter
        if converter == nil || sourceFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw PCMConverterError.converterCreationFailed
            }
            converter = newConverter
            sourceFormat = inputFormat
            activeConverter = newConverter
        } else {
            activeConverter = converter!
        }

        let ratio = targetSampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up)) + 512
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw PCMConverterError.converterCreationFailed
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = activeConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return extractMonoFloatSamples(outputBuffer)
        case .error:
            throw PCMConverterError.conversionFailed(conversionError?.localizedDescription ?? "unknown converter error")
        @unknown default:
            throw PCMConverterError.conversionFailed("unknown converter status")
        }
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat, frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw PCMConverterError.unsupportedFormat
        }

        pcmBuffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )

        guard status == noErr else {
            throw PCMConverterError.blockBufferUnavailable(status)
        }

        return pcmBuffer
    }

    private func extractMonoFloatSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }

        if buffer.format.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        }

        var mono = Array(repeating: Float(0), count: frames)
        for channel in 0..<Int(buffer.format.channelCount) {
            let source = channelData[channel]
            for frame in 0..<frames {
                mono[frame] += source[frame]
            }
        }
        let divisor = Float(buffer.format.channelCount)
        for index in mono.indices {
            mono[index] /= divisor
        }
        return mono
    }
}
