//
//  PermissionService.swift
//  MeetingAssistant
//
//  Checks and requests system permissions for microphone,
//  screen recording, and calendar access.
//

import AVFoundation
import CoreGraphics
import EventKit
import Foundation
import OSLog
import AppKit

/// Service for checking and requesting system permissions
@MainActor
@Observable
final class PermissionService {

    // MARK: - Permission States

    enum PermissionState {
        case unknown
        case granted
        case denied
    }

    private(set) var microphoneState: PermissionState = .unknown
    private(set) var screenRecordingState: PermissionState = .unknown
    private(set) var calendarState: PermissionState = .unknown

    var allRequiredPermissionsGranted: Bool {
        microphoneState == .granted && screenRecordingState == .granted
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "PermissionService")

    // MARK: - Initialization

    init() {
        updatePermissionStates()
    }

    // MARK: - Check Permissions

    func updatePermissionStates() {
        microphoneState = checkMicrophonePermission()
        screenRecordingState = checkScreenRecordingPermission()
        calendarState = checkCalendarPermission()
    }

    private func checkMicrophonePermission() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .unknown
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    private func checkScreenRecordingPermission() -> PermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    private func checkCalendarPermission() -> PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .unknown
        case .denied, .restricted, .writeOnly: return .denied
        @unknown default: return .unknown
        }
    }

    // MARK: - Request Permissions

    func requestPermissions() async {
        // Microphone
        if microphoneState != .granted {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneState = granted ? .granted : .denied
        }

        // Screen recording
        if screenRecordingState != .granted {
            let granted = CGRequestScreenCaptureAccess()
            screenRecordingState = granted ? .granted : .denied
        }

        // Calendar
        if calendarState != .granted {
            do {
                let granted = try await EKEventStore().requestFullAccessToEvents()
                calendarState = granted ? .granted : .denied
            } catch {
                calendarState = .denied
            }
        }

        logger.info("Permissions - Mic: \(String(describing: self.microphoneState)), Screen: \(String(describing: self.screenRecordingState)), Calendar: \(String(describing: self.calendarState))")
    }

    // MARK: - Open Settings

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
