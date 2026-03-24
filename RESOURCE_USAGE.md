# Resource Usage

MeetingAssistant is designed to be as lightweight as possible. This document describes its resource footprint in each state.

## Architecture

All monitoring is **event-driven** — no polling, no timers, no background audio processing when idle.

| Component | Mechanism | Cost When Idle |
|---|---|---|
| **Mic Monitor** | CoreAudio `AudioObjectPropertyListenerBlock` on `kAudioDevicePropertyDeviceIsRunningSomewhere` | Zero — OS callback only fires on state change |
| **Default Device Monitor** | CoreAudio listener on `kAudioHardwarePropertyDefaultInputDevice` | Zero — OS callback on device change |
| **Volume Enforcer** | AppleScript (`set volume input volume 100`) on 3s timer | Zero when idle — only active during recording |
| **Global Hotkey** | Carbon `RegisterEventHotKey` | Zero — OS callback on keypress |
| **Recording Timer** | `Timer.scheduledTimer` (1s interval) | Only active during recording |

## App States

### Idle (Monitoring)
- **CPU**: ~0.0% — all listeners are kernel callbacks, no user-space processing
- **Memory**: ~15–25 MB resident (SwiftUI menu bar app baseline)
- **Battery**: Negligible — no wake-ups, no timers, no audio processing
- **Network**: None
- **Disk**: None

### Recording (Audio Only)
- **CPU**: ~1–3% — ScreenCaptureKit audio capture + AAC encoding (64 kbps mono) + volume enforcement timer (negligible)
- **Memory**: ~30–50 MB (audio buffers + asset writer)
- **Battery**: Low — efficient hardware-accelerated AAC encoding
- **Disk**: ~0.5 MB/min (AAC 64 kbps mono)

### Recording (Video + Audio)
- **CPU**: ~5–15% — ScreenCaptureKit video + audio, HEVC encoding (500 kbps, 15 fps)
- **Memory**: ~80–150 MB (video frame buffers + encoder)
- **Battery**: Moderate — hardware HEVC encoder is efficient but video capture adds overhead
- **Disk**: ~4–5 MB/min (HEVC 500 kbps + AAC 64 kbps)

### Paused
- **CPU**: ~0.5–1% — capture stream is still active but all samples are dropped (no encoding)
- **Memory**: ~30–50 MB (buffers remain allocated, no new data written)
- **Battery**: Low — capture hardware stays warm but no encoding work
- **Disk**: None (samples are dropped)

## What Was Removed

The following were removed over time to reduce resource usage, eliminate CoreAudio log spam, and improve reliability:

| Removed Component | Previous Cost | Reason |
|---|---|---|
| **AVAudioEngine input tap** | Continuous mic capture (~1–3% CPU) | Required for stem detection; unreliable on macOS |
| **VoiceProcessingIO audio unit** | Full-duplex DSP processing (~2–5% CPU) | macOS VP I/O had persistent initialization failures and DSP errors |
| **AVAudioApplication stem handler** | Registration + callback overhead | Stem events not reliably routed to non-frontmost apps |
| **Always-on mic monitoring** | Kept mic hardware active, triggered macOS mic indicator | Battery drain + user confusion from persistent mic icon |
| **Mic mute via AppleScript** | Minor (on-demand AppleScript) | Unreliable — volume would drift, causing false unmuted states |
| **Auto-stop on mic inactive** | N/A | Caused recordings to split when switching mics/headphones mid-meeting |

**Current design**: Idle CPU is **~0%** (pure event-driven listeners). Recording relies on ScreenCaptureKit with volume enforcement and manual stop control.

## Measuring Resource Usage

To verify these numbers on your machine:

```bash
# Find PID
pgrep -f MeetingAssistant

# CPU and memory (5 samples, 1s interval)
top -pid <PID> -l 5 -stats pid,cpu,rsize,vsize

# Energy impact
sudo powermetrics --samplers tasks --show-process-energy -n 3 -i 1000 | grep MeetingAssistant
```
