//
//  AirPodsMuteService.swift
//  MeetingAssistant
//
//  Provides system-wide mic mute/unmute via AppleScript.
//  Lightweight: no audio engine, no background processing.
//  Only runs AppleScript when the user toggles mute.
//

import Foundation
import OSLog

/// Service that provides mic mute/unmute
@MainActor
@Observable
final class AirPodsMuteService {

    // MARK: - Properties

    private(set) var isMuted = false

    /// Callback when mute state changes
    var onMuteStateChanged: ((Bool) -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "AirPodsMuteService")
    private var savedInputVolume: Int = 100

    // MARK: - Mute Toggle

    func toggleMute() {
        let newState = !isMuted

        if newState {
            let current = getSystemInputVolume()
            if current > 5 {
                savedInputVolume = current
            }
            setSystemInputVolume(0)
            logger.info("🔇 Mic muted (saved volume: \(self.savedInputVolume))")
        } else {
            setSystemInputVolume(savedInputVolume)
            logger.info("🔊 Mic unmuted (restored volume: \(self.savedInputVolume))")
        }

        isMuted = newState
        onMuteStateChanged?(newState)
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
