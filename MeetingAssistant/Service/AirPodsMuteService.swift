//
//  AirPodsMuteService.swift
//  MeetingAssistant
//
//  Implements system-wide mic mute via AppleScript and detects
//  AirPods stem press for mute/unmute.
//
//  KEY DESIGN: Like MutePod, stem detection requires a continuously
//  running AVAudioEngine input tap to maintain an active audio session.
//  macOS only routes stem press events to apps with active audio sessions.
//  The tap can start at app launch ("always-on") or only during recording.
//

import AVFAudio
import CoreAudio
import Foundation
import OSLog

/// Service that provides mic mute/unmute and AirPods stem detection
@MainActor
@Observable
final class AirPodsMuteService {

    // MARK: - Properties

    private(set) var isMuted = false
    private(set) var isMonitoring = false

    /// Callback when mute state changes (from stem or manual toggle)
    var onMuteStateChanged: ((Bool) -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "AirPodsMuteService")
    private var savedInputVolume: Int = 100
    private var audioEngine: AVAudioEngine?
    private var hasRegisteredHandler = false

    // MARK: - Always-On Monitoring

    /// Starts continuous mic monitoring for stem detection.
    /// Call at app launch when the user wants always-on stem support.
    /// The AVAudioEngine tap keeps the audio session alive so macOS
    /// routes stem press events to our app (like MutePod does).
    func startAlwaysOnMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Capture current volume
        savedInputVolume = getSystemInputVolume()
        if savedInputVolume < 5 { savedInputVolume = 100 }

        // Register stem handler once
        registerStemHandlerIfNeeded()

        // Start audio engine tap — this is the key
        startAudioEngineTap()

        logger.info("Always-on stem monitoring started")
    }

    /// Stops continuous monitoring
    func stopAlwaysOnMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        stopAudioEngineTap()

        // Restore volume if muted
        if isMuted {
            setSystemInputVolume(savedInputVolume)
            isMuted = false
        }

        logger.info("Always-on stem monitoring stopped")
    }

    // MARK: - Manual Mute Toggle

    /// Toggles mute state — called from the UI mute button
    func toggleMute() {
        applyMuteState(muted: !isMuted)
    }

    // MARK: - Stem Handler

    private func registerStemHandlerIfNeeded() {
        guard !hasRegisteredHandler else { return }

        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { [weak self] requestedMute in
                // This runs on an arbitrary thread — dispatch to MainActor
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.logger.info("Stem press detected: mute=\(requestedMute)")
                    self.applyMuteState(muted: requestedMute)
                }
                return true  // Accept the mute gesture
            }
            hasRegisteredHandler = true
            logger.info("Stem press handler registered")
        } catch {
            logger.error("Failed to register stem handler: \(error.localizedDescription)")
        }
    }

    // MARK: - Audio Engine Tap

    /// Starts a silent AVAudioEngine input tap to keep our audio session active.
    /// This is analogous to what MutePod does — without an active audio session,
    /// macOS won't route AirPods stem events to our app.
    private func startAudioEngineTap() {
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.warning("Invalid audio format — cannot start engine tap")
            return
        }

        // Silent tap — we discard all audio data
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }

        do {
            try engine.start()
            audioEngine = engine
            logger.info("Audio engine tap started (format: \(format.sampleRate)Hz, \(format.channelCount)ch)")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    private func stopAudioEngineTap() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
            logger.info("Audio engine tap stopped")
        }
    }

    // MARK: - Mute Implementation (AppleScript)

    private func applyMuteState(muted: Bool) {
        if muted {
            let current = getSystemInputVolume()
            if current > 5 {
                savedInputVolume = current
            }
            setSystemInputVolume(0)
            logger.info("Mic muted (saved volume: \(self.savedInputVolume))")
        } else {
            setSystemInputVolume(savedInputVolume)
            logger.info("Mic unmuted (restored volume: \(self.savedInputVolume))")
        }

        isMuted = muted
        onMuteStateChanged?(muted)
    }

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

    /// Sets the system input volume (0–100)
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
