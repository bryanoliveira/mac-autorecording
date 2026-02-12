//
//  AudioAssetWriter.swift
//  MeetingAssistant
//
//  Writes captured audio (and optional video) to disk using AVAssetWriter.
//  Optimized for lightweight, transcription-quality recordings.
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import VideoToolbox
import OSLog
import os

/// Writes captured media to disk — lightweight codec settings for meeting recordings
final class AudioAssetWriter: RecordingEngineSampleBufferDelegate, @unchecked Sendable {

    // MARK: - Properties

    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private(set) var isWriting = false
    private(set) var outputURL: URL?
    private(set) var hasVideo = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "AudioAssetWriter")

    private var hasStartedSession = false
    private var sessionStartTime: CMTime = .zero
    private var frameCount = 0

    private let lock = OSAllocatedUnfairLock()

    /// When true, mic samples are silenced (zero-filled) in the recording.
    /// Set by the ViewModel when the user mutes via UI or AirPods stem.
    private let _isMicMuted = OSAllocatedUnfairLock(initialState: false)
    var isMicMuted: Bool {
        get { _isMicMuted.withLock { $0 } }
        set { _isMicMuted.withLock { $0 = newValue } }
    }

    // MARK: - Setup

    /// Prepares the writer for audio-only recording
    func setupAudioOnly(url: URL, includeSystemAudio: Bool) throws {
        try prepareDirectory(for: url)

        assetWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)
        guard let assetWriter else {
            throw AssetWriterError.failedToCreateWriter
        }

        // Microphone track — lightweight AAC for speech
        let micSettings = createSpeechAudioSettings()
        microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
        microphoneInput?.expectsMediaDataInRealTime = true

        if let microphoneInput, assetWriter.canAdd(microphoneInput) {
            assetWriter.add(microphoneInput)
        }

        // System audio track
        if includeSystemAudio {
            let sysSettings = createSpeechAudioSettings()
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: sysSettings)
            audioInput?.expectsMediaDataInRealTime = true

            if let audioInput, assetWriter.canAdd(audioInput) {
                assetWriter.add(audioInput)
            }
        }

        outputURL = url
        hasVideo = false
        hasStartedSession = false
        sessionStartTime = .zero
        frameCount = 0

        logger.info("Writer configured for audio-only: \(url.lastPathComponent)")
    }

    /// Prepares the writer for video + audio recording
    func setupWithVideo(url: URL, videoSize: CGSize, includeSystemAudio: Bool) throws {
        try prepareDirectory(for: url)

        assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        guard let assetWriter else {
            throw AssetWriterError.failedToCreateWriter
        }

        // Video track — low bitrate HEVC for small file size
        let videoSettings = createLowBitrateVideoSettings(size: videoSize)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true

        if let videoInput, assetWriter.canAdd(videoInput) {
            assetWriter.add(videoInput)

            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(videoSize.width),
                kCVPixelBufferHeightKey as String: Int(videoSize.height)
            ]
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
        }

        // Mic track
        let micSettings = createSpeechAudioSettings()
        microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
        microphoneInput?.expectsMediaDataInRealTime = true
        if let microphoneInput, assetWriter.canAdd(microphoneInput) {
            assetWriter.add(microphoneInput)
        }

        // System audio track
        if includeSystemAudio {
            let sysSettings = createSpeechAudioSettings()
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: sysSettings)
            audioInput?.expectsMediaDataInRealTime = true
            if let audioInput, assetWriter.canAdd(audioInput) {
                assetWriter.add(audioInput)
            }
        }

        outputURL = url
        hasVideo = true
        hasStartedSession = false
        sessionStartTime = .zero
        frameCount = 0

        logger.info("Writer configured for video+audio: \(url.lastPathComponent)")
    }

    // MARK: - Writing

    func startWriting() throws {
        guard let assetWriter, assetWriter.status == .unknown else {
            throw AssetWriterError.writerNotReady
        }

        guard assetWriter.startWriting() else {
            throw AssetWriterError.failedToStartWriting(assetWriter.error)
        }

        isWriting = true
        logger.info("Writer started")
    }

    // MARK: - Sample Buffer Appending

    func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        lock.withLockUnchecked {
            guard let assetWriter,
                  assetWriter.status == .writing,
                  let audioInput,
                  audioInput.isReadyForMoreMediaData else { return }

            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            startSessionIfNeeded(at: time, writer: assetWriter)

            if !audioInput.append(sampleBuffer) {
                logger.error("Failed to append system audio sample")
            }
        }
    }

    func appendMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        lock.withLockUnchecked {
            guard let assetWriter,
                  assetWriter.status == .writing,
                  let microphoneInput,
                  microphoneInput.isReadyForMoreMediaData else { return }

            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            startSessionIfNeeded(at: time, writer: assetWriter)

            // When muted, write a silent copy of the buffer instead of the real audio.
            // This keeps timestamps correct while producing silence.
            if isMicMuted {
                if let silentBuffer = createSilentCopy(of: sampleBuffer) {
                    microphoneInput.append(silentBuffer)
                }
            } else {
                if !microphoneInput.append(sampleBuffer) {
                    logger.error("Failed to append microphone sample")
                }
            }
        }
    }

    func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
        // Check frame status
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete else { return }

        lock.withLockUnchecked {
            guard let assetWriter,
                  assetWriter.status == .writing,
                  let videoInput,
                  videoInput.isReadyForMoreMediaData,
                  let adaptor = pixelBufferAdaptor else { return }

            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            startSessionIfNeeded(at: time, writer: assetWriter)

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            if adaptor.append(pixelBuffer, withPresentationTime: time) {
                frameCount += 1
            } else {
                logger.error("Failed to append video frame")
            }
        }
    }

    private func startSessionIfNeeded(at time: CMTime, writer: AVAssetWriter) {
        if !hasStartedSession {
            writer.startSession(atSourceTime: time)
            sessionStartTime = time
            hasStartedSession = true
        }
    }

    // MARK: - Finalization

    func finishWriting() async throws -> URL {
        let (writerToFinish, url): (AVAssetWriter, URL)

        do {
            (writerToFinish, url) = try lock.withLockUnchecked {
                guard let assetWriter, isWriting else {
                    throw AssetWriterError.writerNotReady
                }
                guard let url = outputURL else {
                    throw AssetWriterError.noOutputURL
                }
                guard hasStartedSession else {
                    throw AssetWriterError.noDataWritten
                }

                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                microphoneInput?.markAsFinished()

                return (assetWriter, url)
            }
        } catch AssetWriterError.noDataWritten {
            cancel()
            throw AssetWriterError.noDataWritten
        }

        await writerToFinish.finishWriting()

        return try lock.withLockUnchecked {
            guard let assetWriter else {
                throw AssetWriterError.writerNotReady
            }

            if assetWriter.status == .failed {
                throw AssetWriterError.writingFailed(assetWriter.error)
            }

            isWriting = false
            hasStartedSession = false

            logger.info("Finished writing to: \(url.lastPathComponent)")

            // Clean up
            self.assetWriter = nil
            self.videoInput = nil
            self.pixelBufferAdaptor = nil
            self.audioInput = nil
            self.microphoneInput = nil

            return url
        }
    }

    func cancel() {
        lock.withLockUnchecked {
            assetWriter?.cancelWriting()
            isWriting = false
            hasStartedSession = false
            frameCount = 0

            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }

            assetWriter = nil
            videoInput = nil
            pixelBufferAdaptor = nil
            audioInput = nil
            microphoneInput = nil
            outputURL = nil

            logger.info("Writer cancelled")
        }
    }

    // MARK: - RecordingEngineSampleBufferDelegate

    func recordingEngine(_ engine: RecordingEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        appendAudioSample(sampleBuffer)
    }

    func recordingEngine(_ engine: RecordingEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer) {
        appendMicrophoneSample(sampleBuffer)
    }

    func recordingEngine(_ engine: RecordingEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        appendVideoSample(sampleBuffer)
    }

    // MARK: - Settings

    /// Speech-optimized AAC: 64 kbps, 44.1 kHz, mono (~30 MB/hour)
    private func createSpeechAudioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]
    }

    /// Low-bitrate HEVC video settings for meeting recordings
    private func createLowBitrateVideoSettings(size: CGSize) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 500_000, // 500 kbps — sufficient for screen content
                AVVideoExpectedSourceFrameRateKey: 15,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
            ] as [String: Any]
        ]
    }

    // MARK: - Helpers

    private func prepareDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Creates a silence-filled copy of an audio sample buffer (preserves timing)
    private func createSilentCopy(of sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        // Get the total size needed
        var totalSize: Int = 0
        CMSampleBufferGetSampleSizeArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: nil)

        if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            totalSize = CMBlockBufferGetDataLength(dataBuffer)
        } else {
            // Fallback: estimate from format
            let bytesPerSample = 2 // 16-bit PCM
            totalSize = numSamples * bytesPerSample
        }

        guard totalSize > 0 else { return nil }

        // Create a zero-filled block buffer
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalSize,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }

        // Fill with zeros (silence)
        status = CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: totalSize)
        guard status == noErr else { return nil }

        // Build a new sample buffer with the silent data
        var silentBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: numSamples,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &silentBuffer
        )

        return status == noErr ? silentBuffer : nil
    }
}

// MARK: - Errors

enum AssetWriterError: LocalizedError {
    case failedToCreateWriter
    case writerNotReady
    case failedToStartWriting(Error?)
    case writingFailed(Error?)
    case noOutputURL
    case noDataWritten

    var errorDescription: String? {
        switch self {
        case .failedToCreateWriter:
            return "Failed to create the asset writer."
        case .writerNotReady:
            return "The asset writer is not ready."
        case .failedToStartWriting(let error):
            return "Failed to start writing: \(error?.localizedDescription ?? "Unknown error")"
        case .writingFailed(let error):
            return "Writing failed: \(error?.localizedDescription ?? "Unknown error")"
        case .noOutputURL:
            return "No output URL configured."
        case .noDataWritten:
            return "No audio data was captured."
        }
    }
}
