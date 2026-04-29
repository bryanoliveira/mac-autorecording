//
//  AudioAssetWriter.swift
//  MeetingAssistant
//
//  Coordinates writing of mic, system audio, and (optional) video to
//  per-stream sidecars under a `PartialRecording` directory. Each
//  audio stream is written as raw PCM with no container, which makes
//  the on-disk state crash-resilient: every byte that hits disk is a
//  sample, and the format is recorded in `meta.json` upfront.
//
//  Mixing into a single user-facing file is performed afterwards by
//  `RecordingMixer`, never on the capture queues.
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import VideoToolbox
import OSLog
import os

/// Receives capture sample buffers and routes each into a per-stream sidecar.
final class AudioAssetWriter: RecordingEngineSampleBufferDelegate, @unchecked Sendable {

    // MARK: - State

    private(set) var isWriting = false
    private(set) var partial: PartialRecording?
    private(set) var hasVideo = false

    /// When true, incoming samples are dropped (recording is paused).
    private let _isPaused = OSAllocatedUnfairLock(initialState: false)
    var isPaused: Bool {
        get { _isPaused.withLock { $0 } }
        set { _isPaused.withLock { $0 = newValue } }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "AudioAssetWriter")

    // MARK: - Writers

    private var micWriter: StreamPCMWriter?
    private var systemWriter: StreamPCMWriter?

    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var hasStartedVideoSession = false

    /// Guards access to `partial.metadata` (mutated from capture queues).
    private let metaLock = OSAllocatedUnfairLock()
    /// One-shot flags so we only persist the format/timestamp once each.
    private var micMetaPersisted = false
    private var systemMetaPersisted = false

    // MARK: - Setup

    /// Prepares the writers for an audio-only recording.
    func setupAudioOnly(partial: PartialRecording) throws {
        try setupCommon(partial: partial)
        hasVideo = false
        logger.info("Writers configured for audio-only at \(partial.directory.lastPathComponent)")
    }

    /// Prepares the writers for a video + audio recording.
    func setupWithVideo(partial: PartialRecording, videoSize: CGSize) throws {
        try setupCommon(partial: partial)
        hasVideo = true

        // Video sidecar: HEVC MOV with no audio track. Audio goes into the
        // PCM sidecars and is composed into the final MOV after mixing.
        guard let videoURL = partial.videoURL else {
            throw AssetWriterError.failedToCreateWriter
        }
        if FileManager.default.fileExists(atPath: videoURL.path()) {
            try FileManager.default.removeItem(at: videoURL)
        }

        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let videoSettings = createLowBitrateVideoSettings(size: videoSize)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw AssetWriterError.failedToCreateWriter
        }
        writer.add(input)

        let pbxAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(videoSize.width),
            kCVPixelBufferHeightKey as String: Int(videoSize.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pbxAttrs
        )

        self.videoWriter = writer
        self.videoInput = input
        self.pixelBufferAdaptor = adaptor

        logger.info("Writers configured for video+audio at \(partial.directory.lastPathComponent)")
    }

    private func setupCommon(partial: PartialRecording) throws {
        try FileManager.default.createDirectory(at: partial.directory, withIntermediateDirectories: true)
        self.partial = partial
        self.micMetaPersisted = false
        self.systemMetaPersisted = false
        self.hasStartedVideoSession = false
        self.videoWriter = nil
        self.videoInput = nil
        self.pixelBufferAdaptor = nil
        self.micWriter = try StreamPCMWriter(url: partial.micURL)
        self.systemWriter = try StreamPCMWriter(url: partial.systemURL)
    }

    // MARK: - Lifecycle

    func startWriting() throws {
        if let videoWriter {
            guard videoWriter.status == .unknown else {
                throw AssetWriterError.writerNotReady
            }
            guard videoWriter.startWriting() else {
                throw AssetWriterError.failedToStartWriting(videoWriter.error)
            }
        }
        isWriting = true
        logger.info("Writers started")
    }

    /// Closes all writers and returns the partial. The caller is responsible
    /// for invoking `RecordingMixer` to produce the final output file.
    func finishWriting() async throws -> PartialRecording {
        guard isWriting, var partial = self.partial else {
            throw AssetWriterError.writerNotReady
        }

        let micHasData = micWriter?.hasReceivedSample == true
        let systemHasData = systemWriter?.hasReceivedSample == true

        // Drain any final metadata into the partial before persisting.
        metaLock.withLockUnchecked {
            if let mic = self.micWriter, !self.micMetaPersisted {
                partial.metadata.mic.format = mic.format
                partial.metadata.mic.firstSampleSeconds = mic.firstSampleSeconds
                self.micMetaPersisted = true
            }
            if let sys = self.systemWriter, !self.systemMetaPersisted {
                partial.metadata.system.format = sys.format
                partial.metadata.system.firstSampleSeconds = sys.firstSampleSeconds
                self.systemMetaPersisted = true
            }
        }

        micWriter?.finishWriting()
        systemWriter?.finishWriting()
        micWriter = nil
        systemWriter = nil

        if let videoWriter, let videoInput {
            videoInput.markAsFinished()
            await videoWriter.finishWriting()
            self.videoWriter = nil
            self.videoInput = nil
            self.pixelBufferAdaptor = nil
        }

        try partial.writeMetadata()
        self.partial = partial
        isWriting = false

        guard micHasData || systemHasData else {
            throw AssetWriterError.noDataWritten
        }

        return partial
    }

    /// Cancels the current recording and removes the partial directory.
    func cancel() {
        micWriter?.finishWriting()
        systemWriter?.finishWriting()
        micWriter = nil
        systemWriter = nil

        if let videoWriter {
            videoWriter.cancelWriting()
        }
        videoWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil

        if let partial {
            try? FileManager.default.removeItem(at: partial.directory)
        }
        self.partial = nil
        isWriting = false
        hasStartedVideoSession = false
        logger.info("Writers cancelled")
    }

    // MARK: - RecordingEngineSampleBufferDelegate

    func recordingEngine(_ engine: RecordingEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard !isPaused, let writer = systemWriter else { return }
        let learned = writer.append(sampleBuffer)
        if learned { persistSystemMetadata(format: writer.format, firstSeconds: writer.firstSampleSeconds) }
    }

    func recordingEngine(_ engine: RecordingEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard !isPaused, let writer = micWriter else { return }
        let learned = writer.append(sampleBuffer)
        if learned { persistMicMetadata(format: writer.format, firstSeconds: writer.firstSampleSeconds) }
    }

    func recordingEngine(_ engine: RecordingEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard !isPaused, let videoWriter, let videoInput, let adaptor = pixelBufferAdaptor else { return }
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }

        guard videoInput.isReadyForMoreMediaData else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !hasStartedVideoSession {
            videoWriter.startSession(atSourceTime: time)
            hasStartedVideoSession = true
            persistVideoFirstTime(time: CMTimeGetSeconds(time))
        }

        if !adaptor.append(pixelBuffer, withPresentationTime: time) {
            logger.error("Failed to append video frame")
        }
    }

    // MARK: - Metadata persistence

    /// Persists mic format/timestamp on the first sample. Safe to call from any thread.
    private func persistMicMetadata(format: PCMStreamFormat?, firstSeconds: Double?) {
        let toWrite: PartialRecording? = metaLock.withLockUnchecked {
            guard !self.micMetaPersisted, var p = self.partial else { return nil }
            self.micMetaPersisted = true
            p.metadata.mic.format = format
            p.metadata.mic.firstSampleSeconds = firstSeconds
            self.partial = p
            return p
        }
        if let toWrite { try? toWrite.writeMetadata() }
    }

    private func persistSystemMetadata(format: PCMStreamFormat?, firstSeconds: Double?) {
        let toWrite: PartialRecording? = metaLock.withLockUnchecked {
            guard !self.systemMetaPersisted, var p = self.partial else { return nil }
            self.systemMetaPersisted = true
            p.metadata.system.format = format
            p.metadata.system.firstSampleSeconds = firstSeconds
            self.partial = p
            return p
        }
        if let toWrite { try? toWrite.writeMetadata() }
    }

    private func persistVideoFirstTime(time: Double) {
        let toWrite: PartialRecording? = metaLock.withLockUnchecked {
            guard var p = self.partial, p.metadata.video?.firstSampleSeconds == nil else { return nil }
            p.metadata.video?.firstSampleSeconds = time
            self.partial = p
            return p
        }
        if let toWrite { try? toWrite.writeMetadata() }
    }

    // MARK: - Settings

    /// Low-bitrate HEVC video settings for meeting recordings.
    private func createLowBitrateVideoSettings(size: CGSize) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 500_000,
                AVVideoExpectedSourceFrameRateKey: 15,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
            ] as [String: Any]
        ]
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
