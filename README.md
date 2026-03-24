# MeetingAssistant

A native macOS menu bar app that **automatically records every meeting** by monitoring microphone activity. Lightweight, private, and built for transcription workflows.

## Features

- **Auto-record** — Detects when any app activates the mic (Zoom, Meet, Teams, etc.) and starts recording after a configurable countdown
- **Lightweight audio** — AAC 64 kbps mono (~30 MB/hour), optimized for speech transcription
- **Optional video** — One-click upgrade to screen recording (HEVC 500 kbps, 15 fps) during the countdown popup
- **Calendar-aware** — Automatically names recordings after matching calendar events
- **System audio** — Captures both microphone and system audio (meeting participants)
- **Pause/resume** — Pause and resume recordings during meeting breaks via UI or global keyboard shortcut
- **Volume enforcement** — Automatically keeps mic input at 100% while recording to prevent volume drift
- **Stable recordings** — Freely switch mics or headphones mid-meeting without breaking the recording
- **No dock icon** — Lives entirely in the menu bar

## Requirements

- macOS 15.2 (Sequoia) or later
- Microphone permission
- Screen Recording permission (for system audio capture and optional video)
- Calendar permission (optional, for event-based naming)

## Installation

### From Source

1. Clone the repository and open the project:
   ```bash
   open MeetingAssistant.xcodeproj
   ```

2. Build and run (⌘R), or build a release (see below).

### Building a Release

Run the included build script:

```bash
./build-release.sh
```

This builds a Release archive and places the `.app` in `build/MeetingAssistant.app`. Launch it with:

```bash
open build/MeetingAssistant.app
```

Alternatively, in Xcode: **Product → Archive → Distribute App → Copy App**.

## Architecture

```
MeetingAssistant/
├── MeetingAssistantApp.swift      # App entry point, menu bar setup
├── Model/
│   └── SettingsStore.swift        # UserDefaults-backed preferences
├── View/
│   ├── CountdownPopupView.swift   # Floating countdown/recording popup
│   ├── MenuBarDropdownView.swift  # Menu bar dropdown UI
│   └── SettingsView.swift         # Settings window (3 tabs)
├── ViewModel/
│   └── MeetingRecorderViewModel.swift  # Central state machine
└── Service/
    ├── MicMonitorService.swift    # CoreAudio mic-in-use detection
    ├── RecordingEngine.swift      # ScreenCaptureKit stream management
    ├── AudioAssetWriter.swift     # AVAssetWriter for media files
    ├── CalendarService.swift      # EventKit calendar matching
    ├── MicVolumeEnforcer.swift    # Keeps input volume at 100% during recording
    ├── GlobalHotkeyService.swift  # Carbon-based global keyboard shortcut
    └── PermissionService.swift    # Permission status tracking
```

### Recording Flow

```
Mic detected → Countdown popup (5s) → Recording starts → Manual stop → File renamed
                     │                       │
                     ├─ Dismiss              ├─ Pause / Resume
                     ├─ Add Video            ├─ Stop & Save
                     └─ Start Now            └─ Discard
```

Recordings are never auto-stopped — switching mics, headphones, or Bluetooth devices mid-meeting will not interrupt the recording. The user stops recordings manually via the menu bar, popup, or by quitting the app.

## Settings

### General
- **Countdown duration** — 3/5/8/10 seconds before recording starts
- **Include system audio** — Capture meeting participants' audio
- **Auto-record on mic activity** — Automatically start when any app uses the mic
- **Output directory** — Choose where recordings are saved

### Microphone
- **Keyboard shortcut** — Configurable global hotkey for pause/resume (default: ⌃⌥⌘M)

### Permissions
- Status indicators and quick links to System Settings

## Technical Notes

- **No sandbox** — Distributed outside the App Store for full mic/audio access
- **ScreenCaptureKit** — Used for both audio-only and video capture
- **Volume enforcement** — AppleScript `set volume input volume 100` on a 3-second timer during recording to prevent OS or app-level volume changes
- **Pause/resume** — Capture stream stays active while paused; samples are silently dropped to create a gap in the recording
- **Carbon hotkeys** — `RegisterEventHotKey` for true global shortcuts without Accessibility permission
- **AAC codec** — 64 kbps mono, suitable for speech recognition (Whisper, etc.)

## License

MIT
