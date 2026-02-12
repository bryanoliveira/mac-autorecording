//
//  AirPodsMuteService.swift
//  MeetingAssistant
//
//  Implements system-wide mic mute via AppleScript and detects
//  AirPods stem press for mute/unmute.
//
//  STEM DETECTION ON macOS:
//  AVAudioSession is iOS-only. On macOS, the equivalent of
//  configuring a voiceChat audio session is enabling voice
//  processing on AVAudioEngine's input node. This tells
//  the audio system that our app is a communication app,
//  making macOS route AirPods stem events to our handler.
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

    func startAlwaysOnMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        savedInputVolume = getSystemInputVolume()
        if savedInputVolume < 5 { savedInputVolume = 100 }

        // 1. Start audio engine with voice processing enabled
        startAudioEngineTap()

        // 2. Register stem handler after engine is running
        registerStemHandlerIfNeeded()

        logger.info("Always-on stem monitoring started")
    }

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

    func toggleMute() {
        applyMuteState(muted: !isMuted, fromStemHandler: false)
    }

    // MARK: - Stem Handler

    private func registerStemHandlerIfNeeded() {
        guard !hasRegisteredHandler else { return }

        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { [weak self] requestedMute in
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

    /// Starts AVAudioEngine with voice processing enabled on the input node.
    /// Voice processing (kAudioUnitSubType_VoiceProcessingIO) is the macOS
    /// equivalent of AVAudioSession's .voiceChat mode — it tells macOS
    /// that this app is a communication app, enabling stem event routing.
    private func startAudioEngineTap() {
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()

        // Enable voice processing BEFORE accessing inputNode format.
        // This switches the audio unit from RemoteIO to VoiceProcessingIO,
        // which is what makes macOS route AirPods stem events to us.
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            logger.info("✅ Voice processing enabled on input node")
        } catch {
            logger.error("❌ Failed to enable voice processing: \(error.localizedDescription)")
            // Continue anyway — stem detection may not work but at least
            // the engine tap will keep a mic session alive
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.warning("Invalid audio format — cannot start engine tap")
            return
        }

        // Silent tap — discard audio, keep session alive
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

    private func applyMuteState(muted: Bool, fromStemHandler: Bool) {
        // Guard: prevent re-entrant loops
        guard !isProcessingMuteChange else {
            logger.debug("Skipping re-entrant mute change")
            return
        }

        // Guard: no-op if state already matches
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

        // Sync with AVAudioApplication (only if handler registered)
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
