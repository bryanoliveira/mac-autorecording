//
//  AirPodsMuteService.swift
//  MeetingAssistant
//
//  Implements system-wide mic mute via AppleScript and detects
//  AirPods stem press for mute/unmute.
//
//  KEY INSIGHT: The system routes stem press events to apps that:
//  1. Have an active audio input session (AVAudioEngine with input tap)
//  2. Have registered via setInputMuteStateChangeHandler
//
//  GOTCHA: Calling setInputMuted(_:) triggers the handler, so we must
//  guard against re-entrant loops. We use isProcessingMuteChange to
//  break the cycle: handler → applyMuteState → setInputMuted → handler.
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
    /// Guards against re-entrant handler loops
    private var isProcessingMuteChange = false

    // MARK: - Always-On Monitoring

    /// Starts continuous mic monitoring for stem detection.
    func startAlwaysOnMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Capture current volume
        savedInputVolume = getSystemInputVolume()
        if savedInputVolume < 5 { savedInputVolume = 100 }

        // 1. Start audio engine FIRST to establish active audio session
        startAudioEngineTap()

        // 2. Register stem handler AFTER engine is running
        //    Do NOT call setInputMuted here — it triggers the handler
        //    and causes an infinite loop before any real stem press.
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
        }

        logger.info("Always-on stem monitoring stopped")
    }

    // MARK: - Manual Mute Toggle

    /// Toggles mute state — called from the UI mute button or keyboard shortcut
    func toggleMute() {
        applyMuteState(muted: !isMuted, fromStemHandler: false)
    }

    // MARK: - Stem Handler

    private func registerStemHandlerIfNeeded() {
        guard !hasRegisteredHandler else { return }

        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { [weak self] requestedMute in
                // This callback runs on an arbitrary audio thread.
                // Return true synchronously to accept the gesture,
                // then dispatch the actual mute logic to MainActor.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.logger.info("🎧 Stem handler fired: mute=\(requestedMute)")
                    self.applyMuteState(muted: requestedMute, fromStemHandler: true)
                }
                return true
            }
            hasRegisteredHandler = true
            logger.info("✅ Stem handler registered")
        } catch {
            logger.error("❌ Failed to register stem handler: \(error.localizedDescription)")
        }
    }

    // MARK: - Audio Engine Tap

    private func startAudioEngineTap() {
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.warning("Invalid audio format — cannot start engine tap")
            return
        }

        // Silent tap — discard audio, but keep the session alive
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

    /// Applies the mute state. Guards against re-entrant calls from the handler loop.
    ///
    /// The loop happens because: handler fires → applyMuteState → setInputMuted → handler fires again.
    /// We break this with isProcessingMuteChange and by checking isMuted != muted.
    private func applyMuteState(muted: Bool, fromStemHandler: Bool) {
        // Guard 1: prevent re-entrant loops
        guard !isProcessingMuteChange else {
            logger.debug("Skipping re-entrant mute change")
            return
        }

        // Guard 2: no-op if state already matches
        guard isMuted != muted else {
            logger.debug("Mute state already \(muted) — skipping")
            return
        }

        isProcessingMuteChange = true
        defer { isProcessingMuteChange = false }

        // Apply system-wide mute via AppleScript
        if muted {
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

        // Sync with AVAudioApplication so the system tracks our mute state.
        // Only call if handler is registered (required by the API).
        if hasRegisteredHandler {
            do {
                try AVAudioApplication.shared.setInputMuted(muted)
            } catch {
                logger.warning("setInputMuted failed: \(error.localizedDescription)")
            }
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
