//
//  SettingsView.swift
//  MeetingAssistant
//
//  Settings window for configuring recording behavior,
//  microphone controls, output location, and permissions.
//

import SwiftUI
import Carbon.HIToolbox

struct SettingsView: View {

    let viewModel: MeetingRecorderViewModel

    var body: some View {
        TabView {
            GeneralSettingsView(viewModel: viewModel, settings: viewModel.settings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            MicrophoneSettingsView(viewModel: viewModel, settings: viewModel.settings)
                .tabItem {
                    Label("Microphone", systemImage: "mic")
                }

            PermissionsSettingsView(permissionService: viewModel.permissionService, calendarService: viewModel.calendarService)
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }
        }
        .frame(width: 480, height: 420)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {

    let viewModel: MeetingRecorderViewModel
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Recording") {
                HStack {
                    Text("Countdown before recording")
                    Spacer()
                    Picker("", selection: $settings.countdownDuration) {
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("8 seconds").tag(8)
                        Text("10 seconds").tag(10)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                Toggle("Include system audio", isOn: $settings.includeSystemAudio)

                Toggle("Auto-record on mic activity", isOn: $settings.autoRecordEnabled)

                if settings.autoRecordEnabled {
                    Text("Automatically starts recording when any app activates the microphone.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Output") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save recordings to")
                            .font(.system(size: 13))
                        Text(settings.outputDirectory.path(percentEncoded: false))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button("Change...") {
                        chooseOutputDirectory()
                    }
                    .controlSize(.small)
                }

                if settings.hasCustomOutputDirectory {
                    Button("Reset to Default") {
                        settings.resetOutputDirectory()
                    }
                    .controlSize(.small)
                }
            }

            Section("Info") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio: AAC 64 kbps mono (~30 MB/hour)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Video: HEVC 500 kbps 15 fps (when enabled)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Files named after matching calendar events")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose where to save meeting recordings"

        if panel.runModal() == .OK, let url = panel.url {
            settings.setCustomOutputDirectory(url)
        }
    }
}

// MARK: - Microphone Settings

struct MicrophoneSettingsView: View {

    let viewModel: MeetingRecorderViewModel
    @Bindable var settings: SettingsStore
    @State private var isRecordingShortcut = false

    var body: some View {
        Form {
            Section("Keyboard Shortcut") {
                Toggle("Enable pause/resume shortcut", isOn: $settings.muteShortcutEnabled)
                    .onChange(of: settings.muteShortcutEnabled) {
                        viewModel.updateGlobalHotkey()
                    }

                if settings.muteShortcutEnabled {
                    HStack {
                        Text("Shortcut")
                        Spacer()

                        if isRecordingShortcut {
                            Text("Press a key combination…")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        } else {
                            Button(settings.muteShortcutDisplayString) {
                                isRecordingShortcut = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .background(
                        ShortcutRecorderView(
                            isRecording: $isRecordingShortcut,
                            onShortcutCaptured: { keyCode, modifiers in
                                settings.muteShortcutKeyCode = keyCode
                                settings.muteShortcutModifiers = modifiers
                                viewModel.updateGlobalHotkey()
                            }
                        )
                    )

                    Text("Pauses and resumes the current recording. Works globally regardless of which app is focused.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Shortcut Recorder

/// Invisible NSView-based shortcut recorder that captures key events
struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onShortcutCaptured: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.onCapture = { keyCode, modifiers in
            onShortcutCaptured(keyCode, modifiers)
            isRecording = false
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureView, context: Context) {
        nsView.isCapturing = isRecording
        if isRecording {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

class ShortcutCaptureView: NSView {
    var isCapturing = false
    var onCapture: ((UInt32, UInt32) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else {
            super.keyDown(with: event)
            return
        }

        // Require at least one modifier key
        let flags = event.modifierFlags
        let hasModifier = flags.contains(.command) || flags.contains(.control) ||
                          flags.contains(.option) || flags.contains(.shift)

        guard hasModifier else { return }

        // Convert NSEvent modifier flags to Carbon modifier flags
        var carbonMods: UInt32 = 0
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }

        onCapture?(UInt32(event.keyCode), carbonMods)
    }
}

// MARK: - Permissions Settings

struct PermissionsSettingsView: View {

    let permissionService: PermissionService
    let calendarService: CalendarService

    var body: some View {
        Form {
            Section("Required Permissions") {
                PermissionRow(
                    title: "Microphone",
                    description: "Record meeting audio",
                    state: permissionService.microphoneState,
                    action: { permissionService.openMicrophoneSettings() }
                )

                PermissionRow(
                    title: "Screen Recording",
                    description: "Capture system audio and optional video",
                    state: permissionService.screenRecordingState,
                    action: { permissionService.openScreenRecordingSettings() }
                )
            }

            Section("Optional Permissions") {
                PermissionRow(
                    title: "Calendar",
                    description: "Name recordings after calendar events",
                    state: permissionService.calendarState,
                    action: { permissionService.openCalendarSettings() }
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let state: PermissionService.PermissionState
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch state {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Button("Open Settings") {
                    action()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            case .unknown:
                Text("Not requested")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
