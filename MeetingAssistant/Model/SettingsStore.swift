//
//  SettingsStore.swift
//  MeetingAssistant
//
//  Persists user preferences using UserDefaults with @Observable pattern.
//

import AppKit
import Carbon.HIToolbox
import Foundation

/// Persists user preferences
@MainActor
@Observable
final class SettingsStore {

    // MARK: - Recording Settings

    var countdownDuration: Int {
        get {
            access(keyPath: \.countdownDuration)
            let stored = UserDefaults.standard.integer(forKey: "countdownDuration")
            return stored > 0 ? stored : 5
        }
        set {
            withMutation(keyPath: \.countdownDuration) {
                UserDefaults.standard.set(newValue, forKey: "countdownDuration")
            }
        }
    }

    var includeSystemAudio: Bool {
        get {
            access(keyPath: \.includeSystemAudio)
            return UserDefaults.standard.object(forKey: "includeSystemAudio") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.includeSystemAudio) {
                UserDefaults.standard.set(newValue, forKey: "includeSystemAudio")
            }
        }
    }

    var autoRecordEnabled: Bool {
        get {
            access(keyPath: \.autoRecordEnabled)
            return UserDefaults.standard.object(forKey: "autoRecordEnabled") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.autoRecordEnabled) {
                UserDefaults.standard.set(newValue, forKey: "autoRecordEnabled")
            }
        }
    }

    // MARK: - Microphone Settings

    /// During-call stem mute: monitors AirPods stem presses during recording
    var airpodsStemMuteEnabled: Bool {
        get {
            access(keyPath: \.airpodsStemMuteEnabled)
            return UserDefaults.standard.object(forKey: "airpodsStemMuteEnabled") as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.airpodsStemMuteEnabled) {
                UserDefaults.standard.set(newValue, forKey: "airpodsStemMuteEnabled")
            }
        }
    }

    /// Always-on stem monitoring: keeps a mic tap to detect stem events anytime.
    /// Mutually exclusive with autoRecordEnabled (the mic tap would trigger auto-record).
    var alwaysOnStemMonitoring: Bool {
        get {
            access(keyPath: \.alwaysOnStemMonitoring)
            return UserDefaults.standard.object(forKey: "alwaysOnStemMonitoring") as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.alwaysOnStemMonitoring) {
                UserDefaults.standard.set(newValue, forKey: "alwaysOnStemMonitoring")
            }
        }
    }

    /// Keyboard shortcut for mute toggle
    var muteShortcutKeyCode: UInt32 {
        get {
            access(keyPath: \.muteShortcutKeyCode)
            let stored = UserDefaults.standard.object(forKey: "muteShortcutKeyCode")
            // Default: M key (kVK_ANSI_M = 46)
            return (stored as? UInt32) ?? UInt32(kVK_ANSI_M)
        }
        set {
            withMutation(keyPath: \.muteShortcutKeyCode) {
                UserDefaults.standard.set(newValue, forKey: "muteShortcutKeyCode")
            }
        }
    }

    var muteShortcutModifiers: UInt32 {
        get {
            access(keyPath: \.muteShortcutModifiers)
            let stored = UserDefaults.standard.object(forKey: "muteShortcutModifiers")
            // Default: ⌃⌥⌘ (Control + Option + Command)
            return (stored as? UInt32) ?? (UInt32(cmdKey | optionKey | controlKey))
        }
        set {
            withMutation(keyPath: \.muteShortcutModifiers) {
                UserDefaults.standard.set(newValue, forKey: "muteShortcutModifiers")
            }
        }
    }

    var muteShortcutEnabled: Bool {
        get {
            access(keyPath: \.muteShortcutEnabled)
            return UserDefaults.standard.object(forKey: "muteShortcutEnabled") as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.muteShortcutEnabled) {
                UserDefaults.standard.set(newValue, forKey: "muteShortcutEnabled")
            }
        }
    }

    /// Returns a human-readable string for the current shortcut
    var muteShortcutDisplayString: String {
        var parts: [String] = []
        let mods = muteShortcutModifiers
        if mods & UInt32(controlKey) != 0 { parts.append("⌃") }
        if mods & UInt32(optionKey) != 0 { parts.append("⌥") }
        if mods & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if mods & UInt32(cmdKey) != 0 { parts.append("⌘") }

        let keyName = keyCodeToString(muteShortcutKeyCode)
        parts.append(keyName)
        return parts.joined()
    }

    private func keyCodeToString(_ keyCode: UInt32) -> String {
        let keyMap: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_Space): "Space", UInt32(kVK_Delete): "⌫", UInt32(kVK_Escape): "⎋",
        ]
        return keyMap[keyCode] ?? "?"
    }

    // MARK: - Output Directory

    var defaultOutputDirectory: URL {
        URL.homeDirectory.appending(path: "Movies/MeetingAssistant")
    }

    private var customOutputDirectoryBookmark: Data? {
        get {
            access(keyPath: \.customOutputDirectoryBookmark)
            return UserDefaults.standard.data(forKey: "customOutputDirectoryBookmark")
        }
        set {
            withMutation(keyPath: \.customOutputDirectoryBookmark) {
                UserDefaults.standard.set(newValue, forKey: "customOutputDirectoryBookmark")
            }
        }
    }

    var hasCustomOutputDirectory: Bool {
        customOutputDirectoryBookmark != nil
    }

    var outputDirectory: URL {
        guard let bookmarkData = customOutputDirectoryBookmark else {
            return defaultOutputDirectory
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let newBookmark = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        customOutputDirectoryBookmark = newBookmark
                    }
                }
            }

            return url
        } catch {
            return defaultOutputDirectory
        }
    }

    func setCustomOutputDirectory(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            customOutputDirectoryBookmark = bookmarkData
        } catch {
            // Failed to create bookmark
        }
    }

    func resetOutputDirectory() {
        customOutputDirectoryBookmark = nil
    }

    // MARK: - File Generation

    /// Generates a temporary output URL for a new recording (will be renamed later)
    func generateTempOutputURL(withVideo: Bool) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        let timestamp = formatter.string(from: Date())
        let ext = withVideo ? "mov" : "m4a"
        let filename = "MeetingAssistant_\(timestamp).\(ext)"
        return outputDirectory.appending(path: filename)
    }
}
