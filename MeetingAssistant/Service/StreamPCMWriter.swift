//
//  StreamPCMWriter.swift
//  MeetingAssistant
//
//  Writes one capture stream's audio to a sidecar file as a flat
//  sequence of Float32 mono samples — no header, no container, just
//  4 bytes per sample. The writer downmixes any incoming layout
//  (interleaved or planar, mono or stereo, integer or float) into
//  this canonical form so the on-disk file is trivial to read back.
//
//  Crash resilience comes for free: every byte that hits disk is a
//  sample, and the format (sample rate) is recorded in `meta.json`
//  the first time we see it.
//

import Foundation
import AVFoundation
import CoreMedia
import os

/// Writes a single audio stream to disk as Float32 mono PCM.
final class StreamPCMWriter: @unchecked Sendable {

    let url: URL

    /// Format of the on-disk file (always Float32 mono at the input's
    /// native sample rate). Nil until the first sample buffer arrives.
    private(set) var format: PCMStreamFormat?
    /// Presentation time (seconds) of the first sample buffer.
    private(set) var firstSampleSeconds: Double?
    /// True once at least one sample has been written.
    private(set) var hasReceivedSample: Bool = false

    private var fileHandle: FileHandle?
    private let lock = OSAllocatedUnfairLock()
    private var closed = false

    /// Original input format details, captured on the first sample so we
    /// know how to interpret subsequent buffers.
    private var inputAsbd: AudioStreamBasicDescription?

    init(url: URL) throws {
        self.url = url
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path(), contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: url)
    }

    /// Appends `sampleBuffer`'s PCM payload (downmixed to mono Float32)
    /// to the file. Returns true if the on-disk format was just learned.
    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.withLockUnchecked {
            guard !closed, let handle = fileHandle else { return false }

            let learnedFormat: Bool
            if inputAsbd == nil {
                if let asbd = Self.extractASBD(from: sampleBuffer) {
                    inputAsbd = asbd
                    format = PCMStreamFormat(
                        sampleRate: asbd.mSampleRate,
                        channels: 1,
                        bitDepth: 32,
                        isFloat: true,
                        isBigEndian: false
                    )
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    if pts.isValid {
                        firstSampleSeconds = CMTimeGetSeconds(pts)
                    }
                    learnedFormat = true
                } else {
                    return false
                }
            } else {
                learnedFormat = false
            }

            guard let asbd = inputAsbd else { return learnedFormat }
            guard let monoFloats = Self.extractMonoFloat(from: sampleBuffer, asbd: asbd) else {
                return learnedFormat
            }
            if monoFloats.isEmpty { return learnedFormat }

            monoFloats.withUnsafeBufferPointer { ptr in
                let data = Data(buffer: ptr)
                do {
                    try handle.write(contentsOf: data)
                    hasReceivedSample = true
                } catch {
                    // Disk error — drop the sample. finishWriting() still closes cleanly.
                }
            }

            return learnedFormat
        }
    }

    func finishWriting() {
        lock.withLockUnchecked {
            guard !closed else { return }
            closed = true
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    // MARK: - Format extraction

    private static func extractASBD(from sampleBuffer: CMSampleBuffer) -> AudioStreamBasicDescription? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        return asbdPtr.pointee
    }

    /// Extracts mono Float32 samples from `sampleBuffer`, downmixing across
    /// channels and across interleaved/planar layouts as needed.
    private static func extractMonoFloat(from sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> [Float]? {
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return [] }

        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return nil }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample = Int(asbd.mBitsPerChannel) / 8
        guard bytesPerSample == 2 || bytesPerSample == 4 else { return nil }
        guard !isBigEndian else { return nil }  // Apple platforms are LE.

        // Pull the AudioBufferList out — handles both interleaved and planar.
        var ablSize: Int = 0
        var sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, ablSize > 0 else { return nil }

        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }
        let ablTyped = ablRaw.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablTyped,
            bufferListSize: ablSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard sizeStatus == noErr else { return nil }
        // Keep `blockBuffer` alive across the reads below.
        _ = blockBuffer

        let abl = UnsafeMutableAudioBufferListPointer(ablTyped)

        var output = [Float](repeating: 0, count: numFrames)

        if isNonInterleaved {
            // One AudioBuffer per channel; each is `numFrames` samples long.
            // Sum each channel's samples into `output`, then divide by channels.
            for channelIndex in 0..<min(Int(abl.count), channels) {
                let buf = abl[channelIndex]
                let expectedBytes = numFrames * bytesPerSample
                guard buf.mDataByteSize >= UInt32(expectedBytes), let data = buf.mData else { continue }
                accumulate(into: &output, from: data, frames: numFrames, isFloat: isFloat, bytesPerSample: bytesPerSample, stride: 1, offset: 0)
            }
        } else {
            // One AudioBuffer holds all channels interleaved.
            guard let buf = abl.first, let data = buf.mData else { return nil }
            for channelIndex in 0..<channels {
                accumulate(into: &output, from: data, frames: numFrames, isFloat: isFloat, bytesPerSample: bytesPerSample, stride: channels, offset: channelIndex)
            }
        }

        if channels > 1 {
            let inv = 1.0 / Float(channels)
            for i in 0..<numFrames { output[i] *= inv }
        }

        return output
    }

    /// Adds samples from `data` (with `stride` frames between successive
    /// samples and starting offset `offset`) into `output[i]`.
    /// Converts Int16 to Float32 by dividing by Int16.max.
    private static func accumulate(
        into output: inout [Float],
        from data: UnsafeMutableRawPointer,
        frames: Int,
        isFloat: Bool,
        bytesPerSample: Int,
        stride: Int,
        offset: Int
    ) {
        if isFloat && bytesPerSample == 4 {
            let typed = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                output[i] += typed[i * stride + offset]
            }
        } else if !isFloat && bytesPerSample == 2 {
            let typed = data.assumingMemoryBound(to: Int16.self)
            let scale: Float = 1.0 / 32768.0
            for i in 0..<frames {
                output[i] += Float(typed[i * stride + offset]) * scale
            }
        } else if !isFloat && bytesPerSample == 4 {
            let typed = data.assumingMemoryBound(to: Int32.self)
            let scale: Float = 1.0 / 2147483648.0
            for i in 0..<frames {
                output[i] += Float(typed[i * stride + offset]) * scale
            }
        }
    }
}
