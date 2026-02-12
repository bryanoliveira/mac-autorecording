//
//  AirPodsMuteService.swift
//  MeetingAssistant
//
//  Implements system-wide mic mute via AppleScript and detects
//  AirPods stem press for mute/unmute.
//
//  KEY INSIGHT: The system only routes stem press events to apps that:
//  1. Have an active audio input session (AVAudioEngine with input tap)
//  2. Have registered via setInputMuteStateChangeHandler
//  3. Keep AVAudioApplication.shared.isInputMuted in sync with the mute state
//
//  Without calling setInputMuted(_:), the system doesn't consider
//  our app as properly handling mute state, and won't route events.
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
    /// Must start the audio engine FIRST, then register the handler.
    func startAlwaysOnMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Capture current volume
        savedInputVolume = getSystemInputVolume()
        if savedInputVolume < 5 { savedInputVolume = 100 }

        // 1. Start audio engine FIRST to establish active audio session
        startAudioEngineTap()

        // 2. Initialize the system mute state tracking
        do {
            try AVAudioApplication.shared.setInputMuted(false)
            logger.info("Initialized isInputMuted = false")
        } catch {
            logger.warning("Could not initialize isInputMuted: \(error.localizedDescription)")
        }

        // 3. Register stem handler AFTER engine is running
        registerStemHandlerIfNeeded()

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
            // Sync the system state
            try? AVAudioApplication.shared.setInputMuted(false)
        }

        logger.info("Always-on stem monitoring stopped")
    }

    // MARK: - Manual Mute Toggle

    /// Toggles mute state — called from the UI mute button or keyboard shortcut
    func toggleMute() {
        applyMuteState(muted: !isMuted)
    }

    // MARK: - Stem Handler

    private func registerStemHandlerIfNeeded() {
        guard !hasRegisteredHandler else { return }

        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { [weak self] requestedMute in
                // This callback runs on an arbitrary audio thread.
                // We must dispatch to MainActor for our @MainActor properties,
                // but return true synchronously to accept the gesture.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.logger.info("🎧 Stem press detected: mute=\(requestedMute)")
                    self.applyMuteState(muted: requestedMute)
                }
                return true  // Accept the mute gesture immediately
            }
            hasRegisteredHandler = true
            logger.info("✅ Stem press handler registered successfully")
        } catch {
            logger.error("❌ Failed to register stem handler: \(error.localizedDescription)")
        }
    }

    // MARK: - Audio Engine Tap

    /// Starts a silent AVAudioEngine input tap to maintain an active audio session.
    /// This is what makes macOS route stem events to our app.
    private func startAudioEngineTap() {
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.warning("Invalid audio format — cannot start engine tap")
            return
        }

        // Silent tap — discard all audio data, but keep the session alive
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }

        do {
            try engine.start()
            audioEngine = engine
            logger.info("Audio engine tap started (\(format.sampleRate)Hz, \(format.channelCount)ch)")
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

    // MARK: - Mute Implementation

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

        // CRITICAL: Sync with AVAudioApplication so the system knows our mute state.
        // Without this, stem events won't be routed to our handler on subsequent presses.
        do {
            try AVAudioApplication.shared.setInputMuted(muted)
        } catch {
            logger.warning("Could not sync isInputMuted: \(error.localizedDescription)")
        }

        isMuted = muted
        onMuteStateChanged?(muted)
    }

    /// Gets the current system input volume (0–100) via AppleScript
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
