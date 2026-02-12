# MeetingAssistant

A native macOS menu bar app that **automatically records every meeting** by monitoring microphone activity. Lightweight, private, and built for transcription workflows.

## Features

- **Auto-record** — Detects when any app activates the mic (Zoom, Meet, Teams, etc.) and starts recording after a configurable countdown
- **Lightweight audio** — AAC 64 kbps mono (~30 MB/hour), optimized for speech transcription
- **Optional video** — One-click upgrade to screen recording (HEVC 500 kbps, 15 fps) during the countdown popup
- **Calendar-aware** — Automatically names recordings after matching calendar events
- **System audio** — Captures both microphone and system audio (meeting participants)
- **Mic mute** — Mute/unmute via menu bar dropdown or a global keyboard shortcut
- **AirPods stem mute** — Experimental support for muting via AirPods stem press
- **No dock icon** — Lives entirely in the menu bar

## Requirements

- macOS 15.2 (Sequoia) or later
- Microphone permission
- Screen Recording permission (for system audio capture and optional video)
- Calendar permission (optional, for event-based naming)

## Installation

### From Source

1. Clone the repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/MeetingAssistant.git
   cd MeetingAssistant
   ```

2. Open the project in Xcode:
   ```bash
   open MeetingAssistant.xcodeproj
   ```

3. Build and run (⌘R), or archive and export for distribution (see below).

### Exporting a Release Build

1. In Xcode, select **Product → Archive**
2. In the Organizer window, select the archive and click **Distribute App**
3. Choose **Copy App** (or **Direct Distribution** for notarization)
4. Export the `.app` file to your desired location

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
    ├── AirPodsMuteService.swift   # Stem detection + AppleScript mute
    ├── GlobalHotkeyService.swift  # Carbon-based global keyboard shortcut
    └── PermissionService.swift    # Permission status tracking
```

### Recording Flow

```
Mic detected → Countdown popup (5s) → Recording starts → Mic goes silent → Recording stops → File renamed
                     │                       │
                     ├─ Dismiss              ├─ Mute/Unmute
                     ├─ Add Video            ├─ Stop & Save
                     └─ Start Now            └─ Discard
```

## Settings

### General
- **Countdown duration** — 3/5/8/10 seconds before recording starts
- **Include system audio** — Capture meeting participants' audio
- **Auto-record on mic activity** — Automatically start when any app uses the mic

### Microphone
- **Keyboard shortcut** — Configurable global hotkey for mute/unmute (default: ⌃⌥⌘M)
- **AirPods stem mute** — Experimental during-call stem detection
- **Always-on mic monitoring** — Continuous mic tap for stem detection (like MutePod)

### Permissions
- Status indicators and quick links to System Settings

## Technical Notes

- **No sandbox** — Distributed outside the App Store for full mic/audio access
- **ScreenCaptureKit** — Used for both audio-only and video capture
- **AppleScript mute** — System-wide mic mute via `set volume input volume 0` (most reliable cross-device method)
- **Carbon hotkeys** — `RegisterEventHotKey` for true global shortcuts without Accessibility permission
- **AAC codec** — 64 kbps mono, suitable for speech recognition (Whisper, etc.)

## License

MIT
