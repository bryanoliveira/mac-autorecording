//
//  PermissionService.swift
//  MeetingAssistant
//
//  Checks and requests system permissions for microphone
//  and screen recording.
//

import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import AppKit

/// Service for checking and requesting system permissions
@MainActor
@Observable
final class PermissionService {

    // MARK: - Permission States

    enum PermissionState: CustomStringConvertible {
        case unknown
        case granted
        case denied

        var description: String {
            switch self {
            case .unknown: return "unknown"
            case .granted: return "granted"
            case .denied: return "denied"
            }
        }
    }

    private(set) var microphoneState: PermissionState = .unknown
    private(set) var screenRecordingState: PermissionState = .unknown

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
        logger.info("Permission states - Mic: \(self.microphoneState), Screen: \(self.screenRecordingState)")
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

    // MARK: - Request Permissions

    /// Requests only the microphone permission if not yet determined.
    /// Screen recording is only checked (on Sequoia there is no native dialog).
    func requestPermissions() async {
        updatePermissionStates()

        if microphoneState == .unknown {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneState = granted ? .granted : .denied
            logger.info("Mic permission prompted: \(granted)")
        }

        screenRecordingState = checkScreenRecordingPermission()

        logger.info("After requests - Mic: \(self.microphoneState), Screen: \(self.screenRecordingState)")
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
}
