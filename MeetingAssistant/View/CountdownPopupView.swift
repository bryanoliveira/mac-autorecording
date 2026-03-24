//
//  CountdownPopupView.swift
//  MeetingAssistant
//
//  Floating popup that appears when mic activity is detected.
//  Shows a countdown, and lets the user dismiss, start immediately,
//  switch to video recording mode, or pause/resume during recording.
//

import SwiftUI

struct CountdownPopupView: View {

    let viewModel: MeetingRecorderViewModel
    @State private var showingDiscardAlert = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            header

            if viewModel.isInCountdown {
                countdownContent
            } else if viewModel.isWaitingForContent {
                waitingContent
            } else if viewModel.isRecordingOrPaused {
                recordingContent
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor.opacity(0.5), radius: 4)

            Text(statusTitle)
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            if viewModel.isPaused {
                Image(systemName: "pause.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 12))
            }
        }
    }

    private var statusColor: Color {
        if viewModel.isPaused { return .yellow }
        if viewModel.isRecording { return .red }
        if viewModel.isWaitingForContent { return .blue }
        return .orange
    }

    private var statusTitle: String {
        if viewModel.isPaused { return "Paused" }
        if viewModel.isRecording { return "Recording" }
        if viewModel.isWaitingForContent { return "Waiting for Content Selection" }
        return "Mic Activity Detected"
    }

    // MARK: - Countdown Content

    @ViewBuilder
    private var countdownContent: some View {
        VStack(spacing: 14) {
            // Countdown number
            Text("Recording in \(viewModel.countdownRemaining)...")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.default, value: viewModel.countdownRemaining)

            // Action buttons
            HStack(spacing: 10) {
                Button("Dismiss") {
                    viewModel.dismissCountdown()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    viewModel.switchToVideoMode()
                } label: {
                    Label("Add Video", systemImage: "video.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("Start Now") {
                    viewModel.startNow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Waiting for Content Selection

    @ViewBuilder
    private var waitingContent: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Select a window, app, or display to record...")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            Button("Cancel") {
                viewModel.dismissCountdown()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    // MARK: - Recording Content

    @ViewBuilder
    private var recordingContent: some View {
        VStack(spacing: 12) {
            HStack {
                Text(viewModel.formattedDuration)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: viewModel.isPaused ? "pause.fill" : (viewModel.isVideoMode ? "video.fill" : "waveform"))
                        .font(.system(size: 11))
                    Text(viewModel.isPaused ? "Paused" : (viewModel.isVideoMode ? "Video" : "Audio"))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: .capsule)
            }

            if showingDiscardAlert {
                VStack(spacing: 12) {
                    Text("Discard this recording?")
                        .font(.system(size: 13, weight: .medium))
                    
                    HStack(spacing: 10) {
                        Button("Cancel") {
                            withAnimation { showingDiscardAlert = false }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        
                        Spacer()
                        
                        Button(role: .destructive) {
                            showingDiscardAlert = false
                            Task { await viewModel.discardRecording() }
                        } label: {
                            Label("Discard", systemImage: "trash")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.regular)
                    }
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        withAnimation { showingDiscardAlert = true }
                    } label: {
                        Label("Discard", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    // Pause / Resume
                    Button {
                        viewModel.togglePauseResume()
                    } label: {
                        Label(
                            viewModel.isPaused ? "Resume" : "Pause",
                            systemImage: viewModel.isPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()

                    Button {
                        Task {
                            await viewModel.stopRecording()
                        }
                    } label: {
                        Label("Stop & Save", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.regular)
                }
            }
        }
    }
}
