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

    @Bindable var viewModel: MeetingRecorderViewModel

    var body: some View {
        TabView {
            GeneralSettingsView(viewModel: viewModel, settings: viewModel.settings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            MicrophoneSettingsView(viewModel: viewModel, settings: viewModel.settings)
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            RecoverySettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Recovery", systemImage: "arrow.uturn.backward.circle")
                }

            PermissionsSettingsView(permissionService: viewModel.permissionService)
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }
        }
        .frame(width: 520, height: 460)
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
                    Text("Audio: PCM 16-bit / 16 kHz / mono (~115 MB/hour)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Video: HEVC 500 kbps 15 fps (when enabled)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Mic and system audio are written to separate sidecar files while recording, then mixed into the final file when you stop. If the app crashes, the Recovery tab can rebuild the recording from those sidecars.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
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

// MARK: - Recovery Settings

/// Lists partial recordings left behind by previous crashes and offers
/// to mix them into final files (or discard them).
struct RecoverySettingsView: View {

    @Bindable var viewModel: MeetingRecorderViewModel

    var body: some View {
        Form {
            Section("Orphan Recordings") {
                if viewModel.orphanPartials.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Nothing to recover.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(viewModel.orphanPartials) { partial in
                        OrphanRow(viewModel: viewModel, partial: partial)
                    }

                    HStack {
                        Spacer()
                        Button("Recover All") {
                            Task { await viewModel.recoverAllOrphans() }
                        }
                        .controlSize(.small)
                        .disabled(!viewModel.recoveringPartialIDs.isEmpty)
                    }
                }

                HStack {
                    Spacer()
                    Button("Refresh") {
                        viewModel.refreshOrphans()
                    }
                    .controlSize(.small)
                }
            }

            Section("About Recovery") {
                Text("Each recording is captured into per-stream sidecar files (mic and system audio in raw PCM, plus optional video). When you stop, those sidecars are mixed into a single file. If the app exits unexpectedly while recording, the sidecars stay on disk and show up here so you can rebuild the file.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            viewModel.refreshOrphans()
        }
    }
}

private struct OrphanRow: View {
    @Bindable var viewModel: MeetingRecorderViewModel
    let partial: PartialRecording

    private var isWorking: Bool {
        viewModel.recoveringPartialIDs.contains(partial.id)
    }

    private var subtitle: String {
        let fm = DateFormatter()
        fm.dateStyle = .medium
        fm.timeStyle = .short
        let when = fm.string(from: partial.metadata.startedAt)
        let kind = partial.metadata.withVideo ? "Video + Audio" : "Audio"
        return "\(when) • \(kind)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: partial.metadata.withVideo ? "video.circle" : "waveform.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(partial.id)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Recover") {
                    Task { await viewModel.recoverPartial(partial) }
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    viewModel.discardPartial(partial)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Permissions Settings

struct PermissionsSettingsView: View {

    let permissionService: PermissionService

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

            Section("Diagnostics") {
                VStack(alignment: .leading, spacing: 4) {
                    diagRow("Mic", "\(permissionService.microphoneState)")
                    diagRow("Screen Recording", "\(permissionService.screenRecordingState)")
                    if let path = Bundle.main.executablePath {
                        diagRow("Binary", path)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            permissionService.updatePermissionStates()
        }
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .frame(width: 140, alignment: .trailing)
            Text(value)
                .foregroundStyle(.primary)
            Spacer()
        }
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

