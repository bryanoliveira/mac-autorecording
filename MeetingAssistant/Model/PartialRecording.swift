//
//  PartialRecording.swift
//  MeetingAssistant
//
//  Describes an in-progress or interrupted recording captured to a
//  per-stream sidecar layout. Each stream (mic, system, video) writes
//  to its own file so a crash leaves a recoverable on-disk state — no
//  finalization of any container is required for the audio sidecars.
//
//  Layout on disk:
//    <output_dir>/.partial/<id>/
//        meta.json     -- this struct, encoded
//        mic.pcm       -- raw interleaved PCM (mic, native rate/format)
//        system.pcm    -- raw interleaved PCM (system audio, native rate/format)
//        video.mov     -- video track only (no audio), when withVideo == true
//

import Foundation

/// Describes a single PCM stream's on-disk format. Bytes in the .pcm
/// file are interleaved samples in this format, packed end-to-end with
/// no header.
nonisolated struct PCMStreamFormat: Codable, Equatable, Sendable {
    var sampleRate: Double
    var channels: UInt32
    var bitDepth: UInt32
    var isFloat: Bool
    var isBigEndian: Bool

    var bytesPerFrame: UInt32 { (bitDepth / 8) * channels }
}

/// One audio stream within a partial recording.
nonisolated struct PartialAudioStream: Codable, Equatable, Sendable {
    /// Filename relative to the partial directory.
    var file: String
    /// Sample format. May be nil until the first sample buffer arrives.
    var format: PCMStreamFormat?
    /// Presentation time of the first sample buffer, in seconds, on the
    /// shared capture clock. Used by the mixer to align tracks.
    var firstSampleSeconds: Double?
}

/// One video stream within a partial recording.
nonisolated struct PartialVideoStream: Codable, Equatable, Sendable {
    var file: String
    var width: Double
    var height: Double
    var firstSampleSeconds: Double?
}

/// All metadata persisted in `meta.json` for a partial recording.
nonisolated struct PartialRecordingMetadata: Codable, Equatable, Sendable {
    /// Stable id; matches the parent directory name.
    var id: String
    /// Wall-clock time the recording started.
    var startedAt: Date
    /// True when the user requested screen capture in addition to audio.
    var withVideo: Bool
    /// Absolute path of the final mixed output file. Used by recovery
    /// so we know where to put the recovered file.
    var finalOutputPath: String

    var mic: PartialAudioStream
    var system: PartialAudioStream
    var video: PartialVideoStream?

    /// Set to true after the mixer successfully writes the final file
    /// and we are about to delete the partial. Anything still on disk
    /// without this flag is an orphan and a candidate for recovery.
    var completed: Bool = false
}

/// A handle to a partial recording's directory and its metadata.
nonisolated struct PartialRecording: Identifiable, Equatable, Sendable {
    let directory: URL
    var metadata: PartialRecordingMetadata

    var id: String { metadata.id }

    var metadataURL: URL { directory.appending(path: "meta.json") }
    var micURL: URL { directory.appending(path: metadata.mic.file) }
    var systemURL: URL { directory.appending(path: metadata.system.file) }
    var videoURL: URL? {
        guard let v = metadata.video else { return nil }
        return directory.appending(path: v.file)
    }
    var finalOutputURL: URL { URL(fileURLWithPath: metadata.finalOutputPath) }

    /// Encodes `metadata` to `meta.json` atomically.
    func writeMetadata() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: [.atomic])
    }

    /// Reads `meta.json` from `directory`.
    static func loadMetadata(at directory: URL) throws -> PartialRecordingMetadata {
        let url = directory.appending(path: "meta.json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PartialRecordingMetadata.self, from: data)
    }
}
