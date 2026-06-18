import Foundation
import ScreenCaptureKit
import Vision
import AppKit
import CoreGraphics

public final class OCRSpeakerDetector: NSObject, SCStreamOutput {
    private let tracker: OCRSpeakerTracker
    private var currentProfile: GameProfile
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "GameChatTranslator.OCRSpeakerDetector", qos: .userInitiated)
    
    public weak var delegate: OCRSpeakerDetectorDelegate?
    private var lastOCRTime = Date.distantPast
    
    public init(tracker: OCRSpeakerTracker, profile: GameProfile) {
        self.tracker = tracker
        self.currentProfile = profile
        super.init()
    }
    
    /// Starts capturing the screen region and running OCR.
    public func start() async throws {
        // Stop any active capture stream first
        try? await stop()
        
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayFound
        }
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        
        // Convert region from Cocoa (bottom-left origin) to ScreenCaptureKit (top-left origin)
        let cocoaRegion = currentProfile.ocrRegion
        let scRegion = convertCocoaRectToDisplayRect(cocoaRegion)
        
        configuration.sourceRect = scRegion
        
        // Scale dimensions to actual display pixels (supporting Retina display)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        configuration.width = Int(cocoaRegion.size.width * scale)
        configuration.height = Int(cocoaRegion.size.height * scale)
        
        // Set frame rate interval based on profile OCR FPS
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(1.0, currentProfile.ocrFPS)))
        
        // Avoid capturing the cursor
        configuration.showsCursor = false
        
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        
        self.stream = stream
    }
    
    /// Stops the capture stream.
    public func stop() async throws {
        guard let stream = self.stream else { return }
        try await stream.stopCapture()
        self.stream = nil
    }
    
    /// Updates the active profile configuration dynamically.
    public func updateProfile(_ profile: GameProfile) async {
        self.currentProfile = profile
        
        // Re-start the capture stream to apply new region/FPS settings if active
        if stream != nil {
            do {
                try await start()
            } catch {
                print("Failed to restart OCR capture stream with new profile: \(error)")
            }
        }
    }
    
    private func convertCocoaRectToDisplayRect(_ cocoaRect: CGRect) -> CGRect {
        // Main screen height in points
        let mainScreenHeight = NSScreen.main?.frame.height ?? 1080.0
        
        // Cocoa origin is bottom-left, ScreenCaptureKit is top-left
        let scY = mainScreenHeight - cocoaRect.origin.y - cocoaRect.size.height
        
        return CGRect(
            x: cocoaRect.origin.x,
            y: scY,
            width: cocoaRect.size.width,
            height: cocoaRect.size.height
        )
    }
    
    // MARK: - SCStreamOutput Delegate
    
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        
        // Rate limit OCR processing based on configured FPS
        let now = Date()
        let intervalSeconds = 1.0 / max(1.0, currentProfile.ocrFPS)
        guard now.timeIntervalSince(lastOCRTime) >= (intervalSeconds - 0.05) else {
            return
        }
        lastOCRTime = now
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        performLocalOCR(on: imageBuffer)
    }
    
    private func performLocalOCR(on imageBuffer: CVImageBuffer) {
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: imageBuffer, options: [:])
        
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self = self else { return }
            guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else { return }
            
            var detected: [(username: String, confidence: Double)] = []
            var rawStrings: [String] = []
            
            // Build regex from profile
            let regex = try? NSRegularExpression(pattern: self.currentProfile.usernameRegex, options: [])
            
            for observation in observations {
                guard let topCandidate = observation.topCandidates(1).first else { continue }
                let text = topCandidate.string
                rawStrings.append(text)
                
                let confidence = Double(topCandidate.confidence)
                
                if let extracted = self.extractUsername(from: text, regex: regex) {
                    detected.append((username: extracted, confidence: confidence))
                }
            }
            
            // Update the tracker
            self.tracker.update(detected: detected, at: Date(), profile: self.currentProfile)
            
            // Notify delegate
            self.delegate?.didDetectSpeakers(detected, rawText: rawStrings)
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        
        try? requestHandler.perform([request])
    }
    
    private func extractUsername(from text: String, regex: NSRegularExpression?) -> String? {
        guard let regex = regex else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        
        // If there is a capture group, extract the first one
        if match.numberOfRanges > 1 {
            let groupRange = match.range(at: 1)
            if groupRange.location != NSNotFound, let subRange = Range(groupRange, in: text) {
                let matchedText = String(text[subRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                return matchedText.isEmpty ? nil : matchedText
            }
        }
        
        // Fallback to full match
        if let subRange = Range(match.range, in: text) {
            let matchedText = String(text[subRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return matchedText.isEmpty ? nil : matchedText
        }
        
        return nil
    }
}

public protocol OCRSpeakerDetectorDelegate: AnyObject {
    func didDetectSpeakers(_ speakers: [(username: String, confidence: Double)], rawText: [String])
}
