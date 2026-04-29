//
//  MeetingRecorderViewModel.swift
//  MeetingAssistant
//
//  Central view model orchestrating all services.
//  Implements the auto-recording flow:
//    mic active → countdown → record → manual stop
//
//  Recordings are written to a per-recording sidecar directory while
//  capturing, then mixed into the final user-facing file when stopped.
//  Sidecar directories left over from a previous crash are surfaced
//  for manual recovery.
//

import Foundation
import ScreenCaptureKit
import AppKit
import OSLog

/// Main view model managing the meeting recording lifecycle
@MainActor
@Observable
final class MeetingRecorderViewModel {

    // MARK: - State

    enum RecordingState: Equatable {
        case idle
        case countdown(remaining: Int)
        case waitingForContentSelection
        case recording
        case paused
        case stopping
    }

    // MARK: - Published Properties

    private(set) var state: RecordingState = .idle
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var lastError: Error?
    private(set) var isVideoMode = false

    /// Partial recording directories left over from previous crashes.
    /// Refreshed on launch and after each recovery action.
    private(set) var orphanPartials: [PartialRecording] = []
    /// IDs of partials currently being recovered (so the UI can show progress).
    private(set) var recoveringPartialIDs: Set<String> = []

    var hasOrphans: Bool { !orphanPartials.isEmpty }

    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }
    var isRecordingOrPaused: Bool { state == .recording || state == .paused }
    var isInCountdown: Bool {
        if case .countdown = state { return true }
        return false
    }
    var isWaitingForContent: Bool { state == .waitingForContentSelection }

    var formattedDuration: String {
        let hours = Int(recordingDuration) / 3600
        let minutes = (Int(recordingDuration) % 3600) / 60
        let seconds = Int(recordingDuration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    var countdownRemaining: Int {
        if case .countdown(let remaining) = state { return remaining }
        return 0
    }

    // MARK: - Dependencies

    let settings: SettingsStore
    let permissionService: PermissionService
    let micVolumeEnforcer: MicVolumeEnforcer
    private let micMonitorService: MicMonitorService
    private let recordingEngine: RecordingEngine
    private let assetWriter: AudioAssetWriter
    private let partialStore: PartialRecordingStore
    private let mixer: RecordingMixer
    private let globalHotkeyService: GlobalHotkeyService

    var isMicInUse: Bool { micMonitorService.isMicInUse }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "MeetingRecorderViewModel")

    // MARK: - Private State

    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var recordingStartDate: Date?
    /// Accumulated duration before the current timer segment (for pause/resume)
    private var accumulatedDuration: TimeInterval = 0
    private var countdownTimer: Timer?
    private var pendingVideoMode = false
    private var isManualTrigger = false
    private var showPopupCallback: (() -> Void)?
    private var hidePopupCallback: (() -> Void)?
    private var currentPartial: PartialRecording?

    // MARK: - Initialization

    init() {
        self.settings = SettingsStore()
        self.permissionService = PermissionService()
        self.micVolumeEnforcer = MicVolumeEnforcer()
        self.micMonitorService = MicMonitorService()
        self.recordingEngine = RecordingEngine()
        self.assetWriter = AudioAssetWriter()
        self.partialStore = PartialRecordingStore()
        self.mixer = RecordingMixer()
        self.globalHotkeyService = GlobalHotkeyService()

        recordingEngine.delegate = self
        recordingEngine.sampleBufferDelegate = assetWriter

        setupMicMonitorCallbacks()
        setupGlobalHotkey()
    }

    // MARK: - Setup

    func setPopupCallbacks(show: @escaping () -> Void, hide: @escaping () -> Void) {
        showPopupCallback = show
        hidePopupCallback = hide
    }

    private func setupMicMonitorCallbacks() {
        micMonitorService.onMicBecameActive = { [weak self] in
            guard let self else { return }
            guard self.settings.autoRecordEnabled else { return }
            guard self.state == .idle else { return }

            self.logger.info("Mic became active — starting countdown")
            self.isManualTrigger = false
            self.startCountdown()
        }

        // Mic becoming inactive no longer stops recording.
        // The user stops recording manually or via the UI.
        micMonitorService.onMicBecameInactive = { [weak self] in
            guard let self else { return }

            if self.isInCountdown && !self.isManualTrigger {
                // Mic went inactive during auto-triggered countdown — cancel
                self.cancelCountdown()
            }
            // NOTE: We intentionally do NOT stop a recording when the mic
            // goes inactive. This allows switching mics/headphones mid-meeting
            // without breaking the recording.
        }
    }

    // MARK: - Permission Methods

    func requestPermissionsOnLaunch() async {
        await permissionService.requestPermissions()
    }

    func startMonitoring() {
        micMonitorService.startMonitoring()

        // Start global hotkey if enabled
        if settings.muteShortcutEnabled {
            globalHotkeyService.register(
                keyCode: settings.muteShortcutKeyCode,
                modifiers: settings.muteShortcutModifiers
            )
        }

        refreshOrphans()
        logger.info("Monitoring started")
    }

    func stopMonitoring() {
        micMonitorService.stopMonitoring()
        globalHotkeyService.unregister()
    }

    /// Call when keyboard shortcut settings change
    func updateGlobalHotkey() {
        globalHotkeyService.unregister()
        if settings.muteShortcutEnabled {
            globalHotkeyService.register(
                keyCode: settings.muteShortcutKeyCode,
                modifiers: settings.muteShortcutModifiers
            )
        }
    }

    private func setupGlobalHotkey() {
        globalHotkeyService.onHotkeyPressed = { [weak self] in
            self?.togglePauseResume()
        }
    }

    // MARK: - Countdown

    /// Starts a countdown, either from mic detection or manual trigger
    func startCountdown() {
        let duration = settings.countdownDuration
        state = .countdown(remaining: duration)
        pendingVideoMode = false

        showPopupCallback?()

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard case .countdown(let remaining) = self.state else { return }

                if remaining <= 1 {
                    // Countdown finished — start recording
                    self.countdownTimer?.invalidate()
                    self.countdownTimer = nil
                    await self.startRecording(withVideo: self.pendingVideoMode)
                } else {
                    self.state = .countdown(remaining: remaining - 1)
                }
            }
        }
    }

    /// Called from the popup to dismiss/cancel the recording
    func dismissCountdown() {
        cancelCountdown()
    }

    /// Called from the popup to switch to video recording mode
    /// Pauses the countdown and shows "Waiting for content selection"
    func switchToVideoMode() {
        // Stop the countdown timer
        countdownTimer?.invalidate()
        countdownTimer = nil

        pendingVideoMode = true
        state = .waitingForContentSelection

        // Present the content picker for window/display selection
        recordingEngine.presentPicker()
    }

    /// Called from the popup to start recording immediately (skip countdown)
    func startNow() {
        countdownTimer?.invalidate()
        countdownTimer = nil

        Task {
            await startRecording(withVideo: pendingVideoMode)
        }
    }

    /// Triggers the countdown from a manual action (e.g., menu bar button)
    func startManualRecording() {
        guard state == .idle else { return }
        isManualTrigger = true
        startCountdown()
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        state = .idle
        pendingVideoMode = false
        isManualTrigger = false
        recordingEngine.deactivatePicker()
        hidePopupCallback?()
        logger.info("Countdown cancelled")
    }

    // MARK: - Recording

    func startRecording(withVideo: Bool) async {
        guard state == .idle || isInCountdown || isWaitingForContent else { return }

        do {
            state = .recording
            isVideoMode = withVideo
            lastError = nil
            let startedAt = Date()
            recordingStartDate = startedAt

            let id = PartialRecordingStore.makeID(for: startedAt)
            let finalOutputURL = settings.generateFinalOutputURL(id: id, withVideo: withVideo)

            if withVideo, let filter = recordingEngine.contentFilter {
                let videoSize = await recordingEngine.getContentSize(from: filter)
                let partial = try partialStore.createPartial(
                    id: id,
                    in: settings.outputDirectory,
                    startedAt: startedAt,
                    withVideo: true,
                    finalOutputURL: finalOutputURL,
                    videoSize: videoSize
                )
                currentPartial = partial
                try assetWriter.setupWithVideo(partial: partial, videoSize: videoSize)
                try assetWriter.startWriting()
                try await recordingEngine.startVideoCapture(with: filter)
            } else {
                let partial = try partialStore.createPartial(
                    id: id,
                    in: settings.outputDirectory,
                    startedAt: startedAt,
                    withVideo: false,
                    finalOutputURL: finalOutputURL,
                    videoSize: nil
                )
                currentPartial = partial
                try assetWriter.setupAudioOnly(partial: partial)
                try assetWriter.startWriting()
                try await recordingEngine.startAudioOnlyCapture()
            }

            startTimer()
            micVolumeEnforcer.startEnforcingVolume()
            hidePopupCallback?()

            logger.info("Recording started (id: \(id), video: \(withVideo))")

        } catch {
            state = .idle
            lastError = error
            assetWriter.cancel()
            currentPartial = nil
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() async {
        guard isRecordingOrPaused else { return }

        state = .stopping
        stopTimer()
        micVolumeEnforcer.stopEnforcingVolume()

        do {
            try await recordingEngine.stopCapture()
            let partial = try await assetWriter.finishWriting()
            let outputURL = try await mixer.mix(partial)
            partialStore.delete(partial)
            currentPartial = nil

            state = .idle
            recordingDuration = 0
            accumulatedDuration = 0
            isManualTrigger = false
            recordingStartDate = nil

            logger.info("Recording saved to \(outputURL.lastPathComponent)")

        } catch {
            state = .idle
            lastError = error
            // Don't cancel: the partial files are intact and can be
            // recovered later. They will appear as orphans on next launch
            // (and immediately, via refreshOrphans below).
            currentPartial = nil
            refreshOrphans()
            logger.error("Failed to stop/mix recording: \(error.localizedDescription)")
        }
    }

    /// Discards the current recording (from popup or menu bar)
    func discardRecording() async {
        guard isRecordingOrPaused else { return }

        state = .stopping
        stopTimer()
        micVolumeEnforcer.stopEnforcingVolume()

        do {
            try await recordingEngine.stopCapture()
        } catch {
            logger.error("Error stopping capture: \(error.localizedDescription)")
        }

        assetWriter.cancel()
        currentPartial = nil
        state = .idle
        recordingDuration = 0
        accumulatedDuration = 0
        recordingStartDate = nil
        isManualTrigger = false
        hidePopupCallback?()

        logger.info("Recording discarded")
    }

    // MARK: - Pause / Resume

    /// Toggles pause/resume if currently recording or paused
    func togglePauseResume() {
        if isRecording {
            pauseRecording()
        } else if isPaused {
            resumeRecording()
        }
    }

    /// Pauses the recording — capture continues but samples are dropped
    func pauseRecording() {
        guard isRecording else { return }

        // Accumulate elapsed time from the current segment
        if let startTime = recordingStartTime {
            accumulatedDuration += Date().timeIntervalSince(startTime)
        }
        stopTimer()

        state = .paused
        assetWriter.isPaused = true

        logger.info("Recording paused at \(self.formattedDuration)")
    }

    /// Resumes the recording after a pause
    func resumeRecording() {
        guard isPaused else { return }

        state = .recording
        assetWriter.isPaused = false

        // Restart the timer from now, keeping the accumulated duration
        startTimer()

        logger.info("Recording resumed")
    }

    // MARK: - Timer

    private func startTimer() {
        recordingStartTime = Date()

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(startTime)
            }
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - Orphan Recovery

    /// Refreshes the list of orphan partial recordings, excluding any
    /// recording currently in progress.
    func refreshOrphans() {
        let activeID = currentPartial?.id
        orphanPartials = partialStore
            .listOrphans(in: settings.outputDirectory)
            .filter { $0.id != activeID }
    }

    /// Mixes a single orphan partial into its final output file. Removes
    /// the partial directory on success.
    func recoverPartial(_ partial: PartialRecording) async {
        guard !recoveringPartialIDs.contains(partial.id) else { return }
        recoveringPartialIDs.insert(partial.id)
        defer {
            recoveringPartialIDs.remove(partial.id)
            refreshOrphans()
        }

        do {
            let url = try await mixer.mix(partial)
            partialStore.delete(partial)
            logger.info("Recovered partial \(partial.id) → \(url.lastPathComponent)")
        } catch {
            lastError = error
            logger.error("Failed to recover partial \(partial.id): \(error.localizedDescription)")
        }
    }

    /// Recovers all known orphan partials sequentially.
    func recoverAllOrphans() async {
        for partial in orphanPartials {
            await recoverPartial(partial)
        }
    }

    /// Removes an orphan partial without attempting to recover it.
    func discardPartial(_ partial: PartialRecording) {
        partialStore.delete(partial)
        refreshOrphans()
    }

    // MARK: - Helpers

    /// Opens the output folder in Finder
    func openOutputFolder() {
        let dir = settings.outputDirectory
        // Ensure the directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path())
    }
}

// MARK: - RecordingEngineDelegate

extension MeetingRecorderViewModel: RecordingEngineDelegate {

    func recordingEngine(_ engine: RecordingEngine, didStopWithError error: Error?) {
        if isRecordingOrPaused {
            logger.error("Recording stopped unexpectedly: \(error?.localizedDescription ?? "unknown")")
            Task {
                await stopRecording()
            }
        }
    }

    func recordingEngine(_ engine: RecordingEngine, didUpdateFilter filter: SCContentFilter) {
        logger.info("Content filter updated for video recording")

        if isWaitingForContent {
            // User selected content — start recording immediately with video
            pendingVideoMode = true
            Task {
                await startRecording(withVideo: true)
            }
        } else if isInCountdown {
            // Content selected while countdown is still running — mark video mode
            pendingVideoMode = true
        }
    }

    func recordingEngineDidCancelPicker(_ engine: RecordingEngine) {
        if isWaitingForContent {
            // User cancelled picker — fall back to audio, restart countdown
            pendingVideoMode = false
            let duration = settings.countdownDuration
            state = .countdown(remaining: duration)

            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard case .countdown(let remaining) = self.state else { return }

                    if remaining <= 1 {
                        self.countdownTimer?.invalidate()
                        self.countdownTimer = nil
                        await self.startRecording(withVideo: false)
                    } else {
                        self.state = .countdown(remaining: remaining - 1)
                    }
                }
            }

            logger.info("Picker cancelled, back to audio countdown")
        } else {
            pendingVideoMode = false
            logger.info("Picker cancelled, staying in audio mode")
        }
    }
}
