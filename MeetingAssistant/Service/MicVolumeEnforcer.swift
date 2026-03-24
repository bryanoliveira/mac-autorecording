//
//  MicVolumeEnforcer.swift
//  MeetingAssistant
//
//  Ensures the system input volume stays at 100% while recording.
//  Periodically checks and corrects the volume via AppleScript.
//  The user handles muting through their meeting program.
//

import Foundation
import OSLog

/// Service that keeps the mic volume at 100% during recording
@MainActor
@Observable
final class MicVolumeEnforcer {

    // MARK: - Properties

    private(set) var isEnforcing = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "MicVolumeEnforcer")
    private var enforcementTimer: Timer?

    // MARK: - Volume Enforcement

    /// Starts enforcing 100% input volume. Call when recording begins.
    func startEnforcingVolume() {
        guard !isEnforcing else { return }
        isEnforcing = true

        // Set immediately
        ensureFullVolume()

        // Then check every 3 seconds to correct any drift
        enforcementTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ensureFullVolume()
            }
        }

        logger.info("🎙️ Volume enforcement started")
    }

    /// Stops enforcing volume. Call when recording ends.
    func stopEnforcingVolume() {
        guard isEnforcing else { return }
        isEnforcing = false

        enforcementTimer?.invalidate()
        enforcementTimer = nil

        logger.info("🎙️ Volume enforcement stopped")
    }

    // MARK: - Private

    private func ensureFullVolume() {
        let current = getSystemInputVolume()
        if current < 100 {
            setSystemInputVolume(100)
            logger.info("🎙️ Input volume corrected: \(current) → 100")
        }
    }

    // MARK: - AppleScript Helpers

    /// Gets the current system input volume (0–100)
    private func getSystemInputVolume() -> Int {
        let script = NSAppleScript(source: "input volume of (get volume settings)")
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let value = result?.int32Value {
            return Int(value)
        }
        return 100
    }

    /// Sets the system input volume (0–100) via AppleScript
    private func setSystemInputVolume(_ volume: Int) {
        let clamped = max(0, min(100, volume))
        let script = NSAppleScript(source: "set volume input volume \(clamped)")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript error: \(error)")
        }
    }
}
