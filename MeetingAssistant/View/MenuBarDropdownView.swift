//
//  MenuBarDropdownView.swift
//  MeetingAssistant
//
//  The main menu bar dropdown interface showing recording status,
//  controls, and quick access to settings.
//

import SwiftUI

struct MenuBarDropdownView: View {

    let viewModel: MeetingRecorderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Status header
            statusHeader
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 12)

            // Main content based on state
            Group {
                if viewModel.isRecording {
                    recordingControls
                } else {
                    idleContent
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 12)

            // Mic controls — always visible
            micControls
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()
                .padding(.horizontal, 12)

            // Bottom actions
            bottomActions
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    // MARK: - Status Header

    @ViewBuilder
    private var statusHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.4), radius: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))

                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Muted badge in header
            if viewModel.isMuted {
                Label("Muted", systemImage: "mic.slash.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.1), in: Capsule())
            }
        }
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .idle:
            return viewModel.isMicInUse ? .orange : .green
        case .countdown:
            return .orange
        case .waitingForContentSelection:
            return .blue
        case .recording:
            return .red
        case .stopping:
            return .yellow
        }
    }

    private var statusTitle: String {
        switch viewModel.state {
        case .idle:
            return "Monitoring"
        case .countdown:
            return "Starting in \(viewModel.countdownRemaining)..."
        case .waitingForContentSelection:
            return "Selecting Content..."
        case .recording:
            return "Recording"
        case .stopping:
            return "Saving..."
        }
    }

    private var statusSubtitle: String {
        switch viewModel.state {
        case .idle:
            if !viewModel.settings.autoRecordEnabled {
                return "Auto-record disabled"
            }
            return viewModel.isMicInUse ? "Mic in use" : "Idle — waiting for mic"
        case .countdown:
            return "Mic activity detected"
        case .waitingForContentSelection:
            return "Choose a window or display"
        case .recording:
            let mode = viewModel.isVideoMode ? "Video + Audio" : "Audio only"
            return "\(viewModel.formattedDuration) • \(mode)"
        case .stopping:
            return "Finalizing recording..."
        }
    }

    // MARK: - Recording Controls

    @ViewBuilder
    private var recordingControls: some View {
        VStack(spacing: 6) {
            // Duration display
            HStack {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)

                Text(viewModel.formattedDuration)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))

                Spacer()
            }
            .padding(.vertical, 4)

            Divider()

            MenuBarActionButton(
                title: "Stop & Save",
                systemImage: "stop.fill",
                accentColor: .red
            ) {
                Task {
                    await viewModel.stopRecording()
                }
            }

            MenuBarActionButton(
                title: "Discard Recording",
                systemImage: "trash",
                accentColor: .orange
            ) {
                Task {
                    await viewModel.discardRecording()
                }
            }
        }
    }

    // MARK: - Idle Content

    @ViewBuilder
    private var idleContent: some View {
        VStack(spacing: 4) {
            // Auto-record toggle
            Toggle(isOn: Bindable(viewModel.settings).autoRecordEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("Auto-record on mic use")
                        .font(.system(size: 13))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            // Manual record button
            if !viewModel.isInCountdown && !viewModel.isWaitingForContent {
                MenuBarActionButton(
                    title: "Start Recording",
                    systemImage: "record.circle",
                    accentColor: .red
                ) {
                    viewModel.startManualRecording()
                    dismiss()
                }
            }

            // Permission warnings
            if !viewModel.permissionService.allRequiredPermissionsGranted {
                permissionWarning
            }
        }
    }

    // MARK: - Mic Controls (Always Visible)

    @ViewBuilder
    private var micControls: some View {
        VStack(spacing: 4) {
            // Mute/Unmute button — always available
            MenuBarActionButton(
                title: viewModel.isMuted ? "Unmute Microphone" : "Mute Microphone",
                systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                accentColor: viewModel.isMuted ? .orange : .blue
            ) {
                viewModel.toggleMicMute()
            }

            // Shortcut hint
            if viewModel.settings.muteShortcutEnabled {
                HStack {
                    Spacer()
                    Text(viewModel.settings.muteShortcutDisplayString)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
            }

            // Always-on stem toggle
            Toggle(isOn: Bindable(viewModel.settings).alwaysOnStemMonitoring) {
                HStack(spacing: 10) {
                    Image(systemName: "airpodspro")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("AirPods stem mute")
                        .font(.system(size: 13))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .onChange(of: viewModel.settings.alwaysOnStemMonitoring) {
                if viewModel.settings.alwaysOnStemMonitoring && viewModel.settings.autoRecordEnabled {
                    viewModel.settings.autoRecordEnabled = false
                }
                viewModel.updateStemMonitoring()
            }
        }
    }

    // MARK: - Permission Warning

    @ViewBuilder
    private var permissionWarning: some View {
        VStack(spacing: 4) {
            Divider()

            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 12))

                Text("Missing permissions")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                SettingsLink {
                    Text("Fix")
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Bottom Actions

    @ViewBuilder
    private var bottomActions: some View {
        VStack(spacing: 2) {
            MenuBarActionButton(
                title: "Open Recordings Folder",
                systemImage: "folder"
            ) {
                viewModel.openOutputFolder()
            }

            SettingsLink {
                HStack(spacing: 10) {
                    Image(systemName: "gear")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.8))
                        .frame(width: 18)
                    Text("Settings...")
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.vertical, 2)

            MenuBarActionButton(
                title: "Quit MeetingAssistant",
                systemImage: "power"
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - Reusable Button Style

struct MenuBarActionButton: View {
    let title: String
    var systemImage: String? = nil
    var accentColor: Color = .primary
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isDisabled ? Color.gray.opacity(0.3) : accentColor.opacity(0.8))
                        .frame(width: 18)
                }

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isDisabled ? Color.gray.opacity(0.5) : Color.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered && !isDisabled ? accentColor.opacity(0.1) : .clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
