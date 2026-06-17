import CoreMedia
import Foundation
import ScreenCaptureKit

enum SystemAudioCaptureError: Error, LocalizedError {
    case noDisplayFound
    case failedToAddOutput(Error)
    case failedToStart(Error)

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display was found for ScreenCaptureKit capture."
        case .failedToAddOutput(let error):
            return "Could not add ScreenCaptureKit audio output: \(error.localizedDescription)"
        case .failedToStart(let error):
            return """
            Could not start system audio capture: \(error.localizedDescription)

            macOS may require permission:
            System Settings -> Privacy & Security -> Screen & System Audio Recording

            Enable permission for the terminal app you are using, then run this command again.
            """
        }
    }
}

final class SystemAudioCapture: NSObject, SCStreamOutput {
    typealias AudioHandler = (CMSampleBuffer) -> Void

    private let queue = DispatchQueue(label: "SystemAudioTranscriber.ScreenCaptureKitAudio")
    private let onAudio: AudioHandler
    private var stream: SCStream?

    init(onAudio: @escaping AudioHandler) {
        self.onAudio = onAudio
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.width = 2
        configuration.height = 2

        if #available(macOS 13.2, *) {
            configuration.excludesCurrentProcessAudio = true
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        } catch {
            throw SystemAudioCaptureError.failedToAddOutput(error)
        }

        do {
            try await stream.startCapture()
        } catch {
            throw SystemAudioCaptureError.failedToStart(error)
        }

        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        onAudio(sampleBuffer)
    }
}

