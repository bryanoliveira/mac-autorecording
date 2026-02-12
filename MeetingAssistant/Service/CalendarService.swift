//
//  CalendarService.swift
//  MeetingAssistant
//
//  Accesses the user's default calendar to match recordings
//  with calendar events for automatic file naming.
//

import EventKit
import Foundation
import OSLog

/// Service for matching recordings with calendar events
@MainActor
@Observable
final class CalendarService {

    // MARK: - Properties

    private(set) var hasCalendarAccess = false

    private let eventStore = EKEventStore()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "CalendarService")

    // MARK: - Permission

    /// Requests full calendar access
    func requestAccess() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            hasCalendarAccess = granted
            logger.info("Calendar access: \(granted)")
        } catch {
            hasCalendarAccess = false
            logger.error("Calendar access request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Event Matching

    /// Finds the calendar event that best matches the given recording time
    /// - Parameters:
    ///   - date: The start time of the recording
    /// - Returns: The matching event, if any
    func matchingEvent(around date: Date) -> EKEvent? {
        guard hasCalendarAccess else { return nil }

        // Search window: 30 minutes before to 30 minutes after
        let windowStart = date.addingTimeInterval(-30 * 60)
        let windowEnd = date.addingTimeInterval(30 * 60)

        let predicate = eventStore.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)

        // Find the event with the best overlap
        // Prefer events that started closest to (but before) the recording start
        let sortedEvents = events
            .filter { !$0.isAllDay } // Skip all-day events
            .sorted { event1, event2 in
                let diff1 = abs(event1.startDate.timeIntervalSince(date))
                let diff2 = abs(event2.startDate.timeIntervalSince(date))
                return diff1 < diff2
            }

        return sortedEvents.first
    }

    // MARK: - Filename Generation

    /// Generates a recording filename based on the datetime and optional calendar event
    /// - Parameters:
    ///   - date: The recording start time
    ///   - fileExtension: The file extension (e.g., "m4a" or "mov")
    /// - Returns: A sanitized filename
    func generateFilename(for date: Date, fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm"
        let timestamp = formatter.string(from: date)

        if let event = matchingEvent(around: date), let title = event.title, !title.isEmpty {
            let sanitizedTitle = sanitizeForFilename(title)
            return "\(timestamp)_\(sanitizedTitle).\(fileExtension)"
        }

        return "\(timestamp)_Recording.\(fileExtension)"
    }

    /// Renames a recording file based on calendar event matching
    /// - Parameters:
    ///   - url: The current file URL
    ///   - recordingStartDate: When the recording started
    /// - Returns: The new URL after renaming, or the original if no rename needed
    func renameRecording(at url: URL, recordingStartDate: Date) -> URL {
        let fileExtension = url.pathExtension
        let newFilename = generateFilename(for: recordingStartDate, fileExtension: fileExtension)
        let newURL = url.deletingLastPathComponent().appending(path: newFilename)

        // Don't rename if it would create a conflict
        guard !FileManager.default.fileExists(atPath: newURL.path()) else {
            logger.warning("File already exists at target rename path, skipping rename")
            return url
        }

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            logger.info("Renamed recording to: \(newFilename)")
            return newURL
        } catch {
            logger.error("Failed to rename recording: \(error.localizedDescription)")
            return url
        }
    }

    // MARK: - Helpers

    private func sanitizeForFilename(_ string: String) -> String {
        // Remove characters that are invalid in filenames
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = string
            .components(separatedBy: invalidCharacters)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacing(" ", with: "_")

        // Limit length to avoid overly long filenames
        if sanitized.count > 80 {
            return String(sanitized.prefix(80))
        }

        return sanitized.isEmpty ? "Recording" : sanitized
    }
}
