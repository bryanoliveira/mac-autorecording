//
//  PartialRecordingStore.swift
//  MeetingAssistant
//
//  Manages the on-disk lifecycle of partial recordings:
//  creating fresh per-recording directories, listing orphans
//  left over by previous crashes, and cleaning them up after
//  a successful mix.
//

import Foundation
import OSLog

/// Owns the `.partial` folder under the user's recordings directory.
/// All access is synchronous and main-actor confined; the writers do
/// their own I/O on capture queues without touching this type.
@MainActor
final class PartialRecordingStore {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "PartialRecordingStore")

    /// Returns the parent `.partial` directory for the given output dir.
    func partialsRoot(in outputDirectory: URL) -> URL {
        outputDirectory.appending(path: ".partial")
    }

    /// Creates a fresh partial directory and writes initial metadata.
    /// `id` is also used as the directory name.
    func createPartial(
        id: String,
        in outputDirectory: URL,
        startedAt: Date,
        withVideo: Bool,
        finalOutputURL: URL,
        videoSize: CGSize?
    ) throws -> PartialRecording {
        let root = partialsRoot(in: outputDirectory)
        let directory = root.appending(path: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let mic = PartialAudioStream(file: "mic.pcm", format: nil, firstSampleSeconds: nil)
        let system = PartialAudioStream(file: "system.pcm", format: nil, firstSampleSeconds: nil)
        let video: PartialVideoStream? = withVideo
            ? PartialVideoStream(
                file: "video.mov",
                width: Double(videoSize?.width ?? 0),
                height: Double(videoSize?.height ?? 0),
                firstSampleSeconds: nil
            )
            : nil

        let metadata = PartialRecordingMetadata(
            id: id,
            startedAt: startedAt,
            withVideo: withVideo,
            finalOutputPath: finalOutputURL.path(percentEncoded: false),
            mic: mic,
            system: system,
            video: video,
            completed: false
        )

        let partial = PartialRecording(directory: directory, metadata: metadata)
        try partial.writeMetadata()
        logger.info("Created partial recording at \(directory.path(percentEncoded: false))")
        return partial
    }

    /// Lists every partial directory that has not been marked completed.
    /// Directories without a parseable `meta.json` are skipped (logged).
    func listOrphans(in outputDirectory: URL) -> [PartialRecording] {
        let root = partialsRoot(in: outputDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var orphans: [PartialRecording] = []
        for url in entries {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(), isDirectory: &isDir),
                  isDir.boolValue else { continue }
            do {
                let metadata = try PartialRecording.loadMetadata(at: url)
                guard !metadata.completed else { continue }
                orphans.append(PartialRecording(directory: url, metadata: metadata))
            } catch {
                logger.warning("Skipping partial at \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        orphans.sort { $0.metadata.startedAt < $1.metadata.startedAt }
        return orphans
    }

    /// Removes a partial directory after a successful mix.
    func delete(_ partial: PartialRecording) {
        do {
            try FileManager.default.removeItem(at: partial.directory)
            logger.info("Deleted partial \(partial.id)")
        } catch {
            logger.error("Failed to delete partial \(partial.id): \(error.localizedDescription)")
        }
    }

    /// Generates a stable id for a new recording.
    static func makeID(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return formatter.string(from: date)
    }
}
