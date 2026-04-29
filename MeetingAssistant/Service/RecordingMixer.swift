//
//  RecordingMixer.swift
//  MeetingAssistant
//
//  Reads the raw PCM sidecars (and optional video.mov) from a
//  PartialRecording and produces the user-facing output file:
//  a 16-bit / 16 kHz / mono WAV for audio-only recordings, or a
//  MOV that combines that mixed audio with the captured video.
//
//  All work happens off the main thread. Streams are pulled in
//  modest chunks so peak memory stays low even on long recordings.
//

import Foundation
import AVFoundation
import OSLog

enum RecordingMixerError: LocalizedError {
    case noAudioStreams
    case missingVideo
    case exportFailed(String)
    case unsupportedFormat
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioStreams: return "The recording is empty: no audio data was captured."
        case .missingVideo:   return "The recording is marked as video but the video file is missing."
        case .exportFailed(let msg): return "Video export failed: \(msg)"
        case .unsupportedFormat: return "The captured audio format is not supported."
        case .writerFailed(let msg): return "Failed to write the mixed audio: \(msg)"
        }
    }
}

/// Mixes a `PartialRecording` into a final user-facing file.
/// Marked `nonisolated` so the heavy lifting can run on a background
/// task without bouncing back to the main actor for every byte.
nonisolated final class RecordingMixer: Sendable {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "RecordingMixer")

    /// Output sample rate for the final file. 16 kHz is plenty for speech
    /// transcription and keeps the file small (~115 MB/hour for 16-bit mono).
    static let outputSampleRate: Double = 16000

    /// Mixes `partial` and writes the result to `partial.finalOutputURL`.
    /// Returns the URL the file was written to.
    func mix(_ partial: PartialRecording) async throws -> URL {
        let outputURL = partial.finalOutputURL
        try ensureWritable(url: outputURL)

        if partial.metadata.withVideo {
            return try await mixWithVideo(partial: partial, outputURL: outputURL)
        } else {
            return try await mixAudioOnly(partial: partial, outputURL: outputURL)
        }
    }

    // MARK: - Audio-only

    private func mixAudioOnly(partial: PartialRecording, outputURL: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try Self.runAudioMix(partial: partial, outputURL: outputURL)
        }.value
        return outputURL
    }

    /// Writes the mixed audio to `outputURL` (WAV, 16-bit/16 kHz/mono).
    private static func runAudioMix(partial: PartialRecording, outputURL: URL) throws {
        let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        )!

        // First-sample timestamps may be nil if a stream never received any
        // sample buffers. Treat that as "no offset" but still skip mixing it.
        let micStart = partial.metadata.mic.firstSampleSeconds
        let systemStart = partial.metadata.system.firstSampleSeconds
        let earliest = [micStart, systemStart].compactMap { $0 }.min() ?? 0

        let micReader = makeReader(
            url: partial.micURL,
            metadata: partial.metadata.mic,
            processingFormat: processingFormat,
            earliestSeconds: earliest
        )
        let systemReader = makeReader(
            url: partial.systemURL,
            metadata: partial.metadata.system,
            processingFormat: processingFormat,
            earliestSeconds: earliest
        )

        if micReader == nil && systemReader == nil {
            throw RecordingMixerError.noAudioStreams
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw RecordingMixerError.writerFailed(error.localizedDescription)
        }

        let chunkFrames: AVAudioFrameCount = 4096
        guard let mixed = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkFrames) else {
            throw RecordingMixerError.unsupportedFormat
        }

        while true {
            let micChunk = micReader?.readChunk(frameCapacity: chunkFrames)
            let systemChunk = systemReader?.readChunk(frameCapacity: chunkFrames)

            let micFrames = micChunk?.frameLength ?? 0
            let systemFrames = systemChunk?.frameLength ?? 0
            let frameLength = max(micFrames, systemFrames)
            if frameLength == 0 { break }

            mixed.frameLength = frameLength
            guard let dst = mixed.floatChannelData?[0] else {
                throw RecordingMixerError.unsupportedFormat
            }

            let micPtr = micChunk?.floatChannelData?[0]
            let sysPtr = systemChunk?.floatChannelData?[0]

            for i in 0..<Int(frameLength) {
                let m = (i < Int(micFrames) ? (micPtr?[i] ?? 0) : 0)
                let s = (i < Int(systemFrames) ? (sysPtr?[i] ?? 0) : 0)
                var sum = m + s
                if sum > 1.0 { sum = 1.0 }
                if sum < -1.0 { sum = -1.0 }
                dst[i] = sum
            }

            do {
                try outputFile.write(from: mixed)
            } catch {
                throw RecordingMixerError.writerFailed(error.localizedDescription)
            }
        }
    }

    private static func makeReader(
        url: URL,
        metadata: PartialAudioStream,
        processingFormat: AVAudioFormat,
        earliestSeconds: Double
    ) -> StreamReader? {
        guard let format = metadata.format else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path()),
              let size = attrs[.size] as? Int, size > 0 else {
            return nil
        }
        guard let inputFormat = makeAVAudioFormat(from: format) else { return nil }
        let leading = max(0, (metadata.firstSampleSeconds ?? earliestSeconds) - earliestSeconds)
        return StreamReader(
            url: url,
            inputFormat: inputFormat,
            processingFormat: processingFormat,
            leadingSilenceSeconds: leading
        )
    }

    private static func makeAVAudioFormat(from format: PCMStreamFormat) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = format.sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mChannelsPerFrame = format.channels
        asbd.mBitsPerChannel = format.bitDepth
        asbd.mBytesPerFrame = (format.bitDepth / 8) * format.channels
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerPacket = asbd.mBytesPerFrame
        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
        if format.isFloat { flags |= kAudioFormatFlagIsFloat }
        else              { flags |= kAudioFormatFlagIsSignedInteger }
        if format.isBigEndian { flags |= kAudioFormatFlagIsBigEndian }
        asbd.mFormatFlags = flags
        return AVAudioFormat(streamDescription: &asbd)
    }

    // MARK: - Video

    private func mixWithVideo(partial: PartialRecording, outputURL: URL) async throws -> URL {
        guard let videoURL = partial.videoURL,
              FileManager.default.fileExists(atPath: videoURL.path()) else {
            throw RecordingMixerError.missingVideo
        }

        // Mix audio into a temp WAV first.
        let tempAudio = partial.directory.appending(path: "mixed.wav")
        if FileManager.default.fileExists(atPath: tempAudio.path()) {
            try FileManager.default.removeItem(at: tempAudio)
        }
        try await Task.detached(priority: .userInitiated) {
            do {
                try Self.runAudioMix(partial: partial, outputURL: tempAudio)
            } catch RecordingMixerError.noAudioStreams {
                // Allow video-only recovery: leave tempAudio as nil sentinel.
            }
        }.value

        let composition = AVMutableComposition()

        // Video track from video.mov
        let videoAsset = AVURLAsset(url: videoURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first,
              let compVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw RecordingMixerError.exportFailed("video track unavailable")
        }
        let videoDuration = try await videoAsset.load(.duration)
        try compVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideoTrack,
            at: .zero
        )
        compVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        // Audio track from temp WAV (if it exists).
        if FileManager.default.fileExists(atPath: tempAudio.path()) {
            let audioAsset = AVURLAsset(url: tempAudio)
            let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            if let sourceAudioTrack = audioTracks.first,
               let compAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                let audioDuration = try await audioAsset.load(.duration)
                let audioRange = CMTimeRange(start: .zero, duration: min(audioDuration, videoDuration))
                try compAudioTrack.insertTimeRange(
                    audioRange,
                    of: sourceAudioTrack,
                    at: .zero
                )
            }
        }

        // Export the composition to outputURL as a passthrough .mov.
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingMixerError.exportFailed("export session unavailable")
        }
        try await exporter.export(to: outputURL, as: .mov)

        try? FileManager.default.removeItem(at: tempAudio)
        return outputURL
    }

    // MARK: - Helpers

    private func ensureWritable(url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - StreamReader

/// Reads a raw-PCM sidecar in chunks, sample-rate-converts to a target
/// format, and prepends leading silence to align with the earliest stream.
///
/// `@unchecked Sendable`: an instance is only used from a single
/// background `Task.detached` at a time. AVAudioConverter invokes the
/// input block synchronously on the calling thread, so the closure
/// capture is effectively single-threaded.
private nonisolated final class StreamReader: @unchecked Sendable {

    private let inputFormat: AVAudioFormat
    private let processingFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let handle: FileHandle?
    private let bytesPerFrame: Int
    private var leadingSilenceFrames: AVAudioFrameCount
    private var inputExhausted = false

    init?(url: URL, inputFormat: AVAudioFormat, processingFormat: AVAudioFormat, leadingSilenceSeconds: Double) {
        guard let converter = AVAudioConverter(from: inputFormat, to: processingFormat) else {
            return nil
        }
        self.inputFormat = inputFormat
        self.processingFormat = processingFormat
        self.converter = converter
        self.handle = try? FileHandle(forReadingFrom: url)
        self.bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        self.leadingSilenceFrames = AVAudioFrameCount(max(0, leadingSilenceSeconds * processingFormat.sampleRate).rounded())
        if handle == nil { inputExhausted = true }
    }

    /// Returns a buffer with up to `frameCapacity` frames in `processingFormat`.
    /// Returns nil once the stream is fully drained (silence + samples).
    func readChunk(frameCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if leadingSilenceFrames == 0 && inputExhausted { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCapacity) else {
            return nil
        }
        buffer.frameLength = 0
        guard let dst = buffer.floatChannelData?[0] else { return nil }

        // Drain leading silence first.
        if leadingSilenceFrames > 0 {
            let s = min(frameCapacity, leadingSilenceFrames)
            for i in 0..<Int(s) { dst[i] = 0 }
            buffer.frameLength = s
            leadingSilenceFrames -= s
            if buffer.frameLength == frameCapacity {
                return buffer
            }
        }

        // Fill the remaining capacity from the file.
        if !inputExhausted {
            let remaining = frameCapacity - buffer.frameLength
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: remaining) else {
                return buffer.frameLength > 0 ? buffer : nil
            }
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { [weak self] needed, statusPtr in
                guard let self else {
                    statusPtr.pointee = .endOfStream
                    return nil
                }
                return self.provideInput(framesNeeded: needed, status: statusPtr)
            }
            if status == .error || error != nil {
                inputExhausted = true
            }
            let appended = outBuf.frameLength
            if appended > 0, let src = outBuf.floatChannelData?[0] {
                let dstStart = Int(buffer.frameLength)
                for i in 0..<Int(appended) {
                    dst[dstStart + i] = src[i]
                }
                buffer.frameLength += appended
            }
            if status == .endOfStream && appended == 0 {
                inputExhausted = true
            }
        }

        if buffer.frameLength == 0 {
            return nil
        }
        return buffer
    }

    private func provideInput(framesNeeded: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        guard !inputExhausted, let handle else {
            status.pointee = .endOfStream
            return nil
        }
        let bytesToRead = max(1, Int(framesNeeded)) * bytesPerFrame
        let data: Data
        do {
            data = try handle.read(upToCount: bytesToRead) ?? Data()
        } catch {
            inputExhausted = true
            status.pointee = .endOfStream
            return nil
        }
        if data.isEmpty {
            inputExhausted = true
            status.pointee = .endOfStream
            return nil
        }
        let frames = AVAudioFrameCount(data.count / bytesPerFrame)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else {
            inputExhausted = true
            status.pointee = .endOfStream
            return nil
        }
        buf.frameLength = frames
        let abl = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        abl[0].mDataByteSize = UInt32(data.count)
        if let dst = abl[0].mData {
            data.copyBytes(to: dst.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
        status.pointee = .haveData
        return buf
    }
}
