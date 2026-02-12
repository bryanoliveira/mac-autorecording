---
description: How to export MeetingAssistant as a .app for distribution
---

# Exporting MeetingAssistant as a .app

## Option 1: Xcode GUI (Recommended)

1. Open `MeetingAssistant.xcodeproj` in Xcode
2. Set the scheme to **MeetingAssistant** and target to **My Mac**
3. Select **Product → Archive** from the menu bar
4. Wait for the archive to complete. The Organizer window will open automatically.
5. Select your archive and click **Distribute App**
6. Choose **Copy App** for local distribution (or **Direct Distribution** if you have an Apple Developer account for notarization)
7. Choose an export location. The `.app` file will be saved there.

## Option 2: Command Line

// turbo-all

1. Build the release archive:
```bash
xcodebuild -project /Users/bryan/Projects/meetingassistant/MeetingAssistant.xcodeproj \
  -scheme MeetingAssistant \
  -configuration Release \
  -archivePath /tmp/MeetingAssistant.xcarchive \
  archive
```

2. Export the .app from the archive:
```bash
mkdir -p ~/Desktop/MeetingAssistant-Release
cp -R /tmp/MeetingAssistant.xcarchive/Products/Applications/MeetingAssistant.app ~/Desktop/MeetingAssistant-Release/
```

3. The `.app` file is now at `~/Desktop/MeetingAssistant-Release/MeetingAssistant.app`

## Notes

- **No codesigning required** for local use. The app is not sandboxed and not distributed via the App Store.
- **Notarization** (optional): If you want to distribute the app to others without Gatekeeper warnings, you'll need an Apple Developer account ($99/year) and should use `xcrun notarytool` to notarize the app.
- **Debug vs Release**: Release builds have optimizations enabled and may behave differently than debug builds (especially for audio session handling). Always test with a release build before distributing.
