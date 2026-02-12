//
//  GlobalHotkeyService.swift
//  MeetingAssistant
//
//  Registers a system-wide keyboard shortcut for mute/unmute.
//  Uses Carbon RegisterEventHotKey for true global hotkeys that work
//  regardless of which app is focused.
//

import Carbon.HIToolbox
import Foundation
import OSLog

/// Manages a global keyboard shortcut for mic mute/unmute
@MainActor
final class GlobalHotkeyService {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeetingAssistant", category: "GlobalHotkeyService")
    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var isRegistered = false

    /// Callback when the hotkey is pressed
    var onHotkeyPressed: (() -> Void)?

    /// Registers the global hotkey with the given key code and modifier flags
    /// Uses Carbon event handler for true global hotkeys.
    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        // Set up Carbon event handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // We need a stable reference to self for the C callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    service.onHotkeyPressed?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        guard status == noErr else {
            logger.error("Failed to install event handler: \(status)")
            return
        }

        // Register the hotkey
        let hotkeyID = EventHotKeyID(signature: OSType(0x4D41_5354), id: 1) // "MAST"
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if registerStatus == noErr {
            isRegistered = true
            logger.info("Global hotkey registered (keyCode: \(keyCode), modifiers: \(modifiers))")
        } else {
            logger.error("Failed to register hotkey: \(registerStatus)")
            // Clean up the event handler
            if let ref = eventHandlerRef {
                RemoveEventHandler(ref)
                eventHandlerRef = nil
            }
        }
    }

    /// Unregisters the current global hotkey
    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        isRegistered = false
    }

    deinit {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
    }
}
