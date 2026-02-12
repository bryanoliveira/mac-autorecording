//
//  MicMonitorService.swift
//  MeetingAssistant
//
//  Monitors the default system microphone using CoreAudio HAL
//  to detect when any application starts or stops using it.
//

import Foundation
import CoreAudio
import OSLog

/// Service that monitors the default input device to detect mic usage changes
@MainActor
@Observable
final class MicMonitorService {

    // MARK: - Properties

    private(set) var isMicInUse = false
    private(set) var defaultInputDeviceID: AudioDeviceID = kAudioObjectUnknown

    /// Callback fired when mic transitions from inactive → active
    var onMicBecameActive: (() -> Void)?
    /// Callback fired when mic transitions from active → inactive
    var onMicBecameInactive: (() -> Void)?

    private var isMonitoring = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "MicMonitorService")

    // Store references for listener removal
    private var micRunningListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    // MARK: - Public Methods

    /// Starts monitoring the default input device for mic usage
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Get initial default input device
        updateDefaultInputDevice()

        // Listen for default input device changes
        installDefaultDeviceListener()

        // Listen for mic running state on current device
        installMicRunningListener()

        // Check initial state
        checkMicRunningState()

        logger.info("Mic monitoring started")
    }

    /// Stops monitoring
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        removeDefaultDeviceListener()
        removeMicRunningListener()

        logger.info("Mic monitoring stopped")
    }

    // MARK: - Private Methods

    private func updateDefaultInputDevice() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )

        if status == noErr {
            if deviceID != defaultInputDeviceID {
                // Device changed — remove old listener, install new one
                removeMicRunningListener()
                defaultInputDeviceID = deviceID
                installMicRunningListener()
                checkMicRunningState()
                logger.info("Default input device changed to: \(deviceID)")
            }
        } else {
            logger.error("Failed to get default input device: \(status)")
        }
    }

    private func checkMicRunningState() {
        guard defaultInputDeviceID != kAudioObjectUnknown else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            defaultInputDeviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            &isRunning
        )

        if status == noErr {
            let nowInUse = isRunning != 0
            if nowInUse != isMicInUse {
                let wasInUse = isMicInUse
                isMicInUse = nowInUse
                logger.info("Mic state changed: \(wasInUse) → \(nowInUse)")

                if nowInUse {
                    onMicBecameActive?()
                } else {
                    onMicBecameInactive?()
                }
            }
        } else {
            logger.error("Failed to check mic running state: \(status)")
        }
    }

    // MARK: - Listener Installation

    private func installDefaultDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateDefaultInputDevice()
            }
        }
        defaultDeviceListenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )

        if status != noErr {
            logger.error("Failed to install default device listener: \(status)")
        }
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
        defaultDeviceListenerBlock = nil
    }

    private func installMicRunningListener() {
        guard defaultInputDeviceID != kAudioObjectUnknown else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.checkMicRunningState()
            }
        }
        micRunningListenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            defaultInputDeviceID,
            &propertyAddress,
            DispatchQueue.main,
            block
        )

        if status != noErr {
            logger.error("Failed to install mic running listener: \(status)")
        }
    }

    private func removeMicRunningListener() {
        guard defaultInputDeviceID != kAudioObjectUnknown,
              let block = micRunningListenerBlock else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            defaultInputDeviceID,
            &propertyAddress,
            DispatchQueue.main,
            block
        )
        micRunningListenerBlock = nil
    }

    deinit {
        // Listeners are already removed by stopMonitoring if called
    }
}
