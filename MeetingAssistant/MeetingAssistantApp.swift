//
//  MeetingAssistantApp.swift
//  MeetingAssistant
//
//  Entry point — menu bar only app with floating countdown popup.
//

import SwiftUI

@main
struct MeetingAssistantApp: App {

    @State private var viewModel = MeetingRecorderViewModel()
    @State private var popupManager = PopupWindowManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarDropdownView(viewModel: viewModel)
                .onAppear {
                    setupIfNeeded()
                }
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }

    private func setupIfNeeded() {
        guard !popupManager.isSetUp else { return }
        popupManager.isSetUp = true

        Task { @MainActor in
            await viewModel.requestPermissionsOnLaunch()
            viewModel.startMonitoring()

            popupManager.viewModel = viewModel

            viewModel.setPopupCallbacks(
                show: { [popupManager] in
                    popupManager.showPopup()
                },
                hide: { [popupManager] in
                    popupManager.hidePopup()
                }
            )
        }
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let viewModel: MeetingRecorderViewModel

    var body: some View {
        Group {
            if viewModel.isRecording {
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .primary)
            } else if viewModel.isInCountdown {
                Image(systemName: "timer")
                    .symbolRenderingMode(.monochrome)
            } else {
                Image(systemName: "mic.badge.plus")
                    .symbolRenderingMode(.monochrome)
            }
        }
    }
}

// MARK: - Popup Window Manager

/// Manages the floating countdown/recording popup window
@MainActor
@Observable
final class PopupWindowManager {

    var viewModel: MeetingRecorderViewModel?
    var isSetUp = false
    private var popupWindow: NSWindow?

    func showPopup() {
        guard let viewModel else { return }
        guard popupWindow == nil else { return }

        let popupView = CountdownPopupView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: popupView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 180)

        let window = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.title = ""

        // Position near the top-right corner of the main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - window.frame.width - 16
            let y = screenFrame.maxY - window.frame.height - 16
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.orderFrontRegardless()
        popupWindow = window
    }

    func hidePopup() {
        popupWindow?.close()
        popupWindow = nil
    }
}
