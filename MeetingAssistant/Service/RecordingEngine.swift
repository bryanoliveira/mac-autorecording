//
//  RecordingEngine.swift
//  MeetingAssistant
//
//  Wraps ScreenCaptureKit to capture microphone audio, system audio,
//  and optionally a window/display for video recording.
//

import Foundation
import ScreenCaptureKit
import OSLog

/// Delegate for receiving capture events
@MainActor
protocol RecordingEngineDelegate: AnyObject {
    func recordingEngine(_ engine: RecordingEngine, didStopWithError error: Error?)
    func recordingEngine(_ engine: RecordingEngine, didUpdateFilter filter: SCContentFilter)
    func recordingEngineDidCancelPicker(_ engine: RecordingEngine)
}

/// Protocol for receiving sample buffers — called on capture queues
protocol RecordingEngineSampleBufferDelegate: AnyObject, Sendable {
    nonisolated func recordingEngine(_ engine: RecordingEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer)
    nonisolated func recordingEngine(_ engine: RecordingEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer)
    nonisolated func recordingEngine(_ engine: RecordingEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer)
}

/// Manages ScreenCaptureKit streams for meeting recording
@MainActor
final class RecordingEngine: NSObject {

    // MARK: - Properties

    weak var delegate: RecordingEngineDelegate?
    nonisolated(unsafe) weak var sampleBufferDelegate: RecordingEngineSampleBufferDelegate?

    private(set) var isCapturing = false
    private(set) var contentFilter: SCContentFilter?
    nonisolated(unsafe) private(set) var isVideoEnabled = false

    private var stream: SCStream?
    private let picker = SCContentSharingPicker.shared

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "RecordingEngine")

    // Queues for sample buffer handling
    private let audioSampleQueue = DispatchQueue(label: "com.meetingassistant.audioSampleQueue", qos: .userInteractive)
    private let microphoneSampleQueue = DispatchQueue(label: "com.meetingassistant.micSampleQueue", qos: .userInteractive)
    private let videoSampleQueue = DispatchQueue(label: "com.meetingassistant.videoSampleQueue", qos: .userInteractive)

    // MARK: - Initialization

    override init() {
        super.init()
        setupPicker()
    }

    // MARK: - Picker Management

    private func setupPicker() {
        picker.add(self)

        var config = SCContentSharingPickerConfiguration()
        config.allowsChangingSelectedContent = true
        config.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]

        if let bundleID = Bundle.main.bundleIdentifier {
            config.excludedBundleIDs = [bundleID]
        }

        picker.defaultConfiguration = config
    }

    /// Presents the system content sharing picker for optional video capture
    func presentPicker() {
        picker.isActive = true
        picker.present()
    }

    // MARK: - Audio-Only Capture

    /// Starts an audio-only capture (mic + system audio, no video)
    func startAudioOnlyCapture() async throws {
        guard !isCapturing else {
            throw RecordingError.captureAlreadyRunning
        }

        // Need a display filter for audio capture through ScreenCaptureKit
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecordingError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        contentFilter = filter
        isVideoEnabled = false

        let config = createAudioOnlyConfiguration()

        stream = SCStream(filter: filter, configuration: config, delegate: self)

        guard let stream else {
            throw RecordingError.failedToCreateStream
        }

        // SCK always generates video frames even in audio-only mode.
        // We must add a .screen output to prevent "SCStream output NOT found" errors.
        // The frames are simply discarded (isVideoEnabled = false).
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoSampleQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioSampleQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneSampleQueue)

        try await stream.startCapture()
        isCapturing = true

        logger.info("Audio-only capture started")
    }

    // MARK: - Video Capture

    /// Starts a video + audio capture with the previously selected content filter
    /// Returns the video size used for the stream configuration
    @discardableResult
    func startVideoCapture(with filter: SCContentFilter) async throws -> CGSize {
        guard !isCapturing else {
            throw RecordingError.captureAlreadyRunning
        }

        contentFilter = filter
        isVideoEnabled = true

        let videoSize = await getContentSize(from: filter)
        let config = createVideoConfiguration(videoSize: videoSize)

        stream = SCStream(filter: filter, configuration: config, delegate: self)

        guard let stream else {
            throw RecordingError.failedToCreateStream
        }

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoSampleQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioSampleQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneSampleQueue)

        try await stream.startCapture()
        isCapturing = true

        logger.info("Video capture started (size: \(videoSize.width)x\(videoSize.height))")
        return videoSize
    }

    /// Stops the current capture
    func stopCapture() async throws {
        guard let stream, isCapturing else { return }

        try await stream.stopCapture()
        self.stream = nil
        isCapturing = false
        isVideoEnabled = false

        logger.info("Capture stopped")
    }

    // MARK: - Configuration

    private func createAudioOnlyConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()

        // Minimum video settings — ScreenCaptureKit requires a display filter.
        // Using 2x2 causes -10877 errors on some hardware; 64x64 is safe.
        config.width = 64
        config.height = 64
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum

        // Audio is captured at each stream's native sample rate. Forcing
        // config.sampleRate only affects system audio and creates a
        // cross-stream rate mismatch with the mic, so we skip it.
        //
        // We DO request mono via channelCount because system audio is
        // otherwise delivered as non-interleaved stereo, and mixing that
        // requires special handling. Asking SCK to downmix to mono is
        // simpler and fine for transcription-quality recordings.
        config.capturesAudio = true
        config.channelCount = 1
        config.captureMicrophone = true
        config.showsCursor = false
        config.captureResolution = .nominal

        return config
    }

    private func createVideoConfiguration(videoSize: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()

        config.width = Int(videoSize.width)
        config.height = Int(videoSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15) // 15 fps — enough for meetings
        config.showsCursor = true
        config.scalesToFit = true  // Scale content to fill the frame — prevents small-in-corner

        // Audio at native rates, mono; see createAudioOnlyConfiguration.
        config.capturesAudio = true
        config.channelCount = 1
        config.captureMicrophone = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureResolution = .best  // Use full resolution to match config dimensions

        return config
    }

    // MARK: - Helpers

    func getContentSize(from filter: SCContentFilter) async -> CGSize {
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)

        if rect.width > 0 && rect.height > 0 {
            // Use retina-scaled dimensions so .best resolution fills the frame
            let w = rect.width * scale
            let h = rect.height * scale
            // Ensure even dimensions (required by most video codecs)
            return CGSize(width: Double(Int(w) & ~1), height: Double(Int(h) & ~1))
        }

        if let screen = NSScreen.main {
            return CGSize(
                width: screen.frame.width * screen.backingScaleFactor,
                height: screen.frame.height * screen.backingScaleFactor
            )
        }

        return CGSize(width: 1920, height: 1080)
    }

    func deactivatePicker() {
        picker.isActive = false
    }

    deinit {
        picker.remove(self)
    }
}

// MARK: - SCContentSharingPickerObserver

extension RecordingEngine: SCContentSharingPickerObserver {

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            self.contentFilter = filter
            self.delegate?.recordingEngine(self, didUpdateFilter: filter)
            logger.info("Content filter updated from picker")
            picker.isActive = false
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            self.contentFilter = nil
            self.delegate?.recordingEngineDidCancelPicker(self)
            logger.info("Picker cancelled")
            picker.isActive = false
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            logger.error("Picker failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - SCStreamDelegate

extension RecordingEngine: SCStreamDelegate {

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            self.isCapturing = false
            self.stream = nil
            self.delegate?.recordingEngine(self, didStopWithError: error)
            logger.error("Stream stopped with error: \(error.localizedDescription)")
        }
    }
}

// MARK: - SCStreamOutput

extension RecordingEngine: SCStreamOutput {

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // Only forward video frames if we're actually in video mode.
            // In audio-only mode, we add a .screen output to prevent SCK errors,
            // but we simply discard the frames.
            if isVideoEnabled {
                sampleBufferDelegate?.recordingEngine(self, didOutputVideoSampleBuffer: sampleBuffer)
            }
        case .audio:
            sampleBufferDelegate?.recordingEngine(self, didOutputAudioSampleBuffer: sampleBuffer)
        case .microphone:
            sampleBufferDelegate?.recordingEngine(self, didOutputMicrophoneSampleBuffer: sampleBuffer)
        @unknown default:
            break
        }
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case captureAlreadyRunning
    case noDisplayFound
    case failedToCreateStream
    case screenRecordingPermissionDenied
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .captureAlreadyRunning:
            return "A capture session is already in progress."
        case .noDisplayFound:
            return "No display found for capture."
        case .failedToCreateStream:
            return "Failed to create the capture stream."
        case .screenRecordingPermissionDenied:
            return "Screen recording permission is required."
        case .microphonePermissionDenied:
            return "Microphone permission is required."
        }
    }
}
