#!/bin/bash
#
# build-release.sh
# Builds MeetingAssistant in Release configuration and places
# the .app bundle in the project's build/ directory.
#
# Usage:  ./build-release.sh [--reset-permissions]
#
# Options:
#   --reset-permissions   Reset macOS privacy permissions (mic, screen recording)
#                         so they are re-requested on next launch. Use this if permissions
#                         are stuck or granted to the wrong app binary.
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$PROJECT_DIR/MeetingAssistant.xcodeproj"
SCHEME="MeetingAssistant"
BUNDLE_ID="com.meetingassistant.app"
ARCHIVE_PATH="/tmp/MeetingAssistant.xcarchive"
OUTPUT_DIR="$PROJECT_DIR/build"
APP_NAME="MeetingAssistant.app"

# Handle --reset-permissions flag
if [[ "${1:-}" == "--reset-permissions" ]]; then
    echo "🔒 Resetting macOS privacy permissions for $BUNDLE_ID..."
    echo "   This clears Microphone and Screen Recording permissions."
    echo "   You will be prompted to grant them again on next launch."
    echo ""
    tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null && echo "   ✓ Microphone permissions reset" || echo "   ⚠ Microphone reset skipped (may need sudo)"
    tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null && echo "   ✓ Screen Recording permissions reset" || echo "   ⚠ Screen Recording reset skipped (may need sudo)"
    echo ""
    echo "   Done. Launch the app to re-request permissions."
    exit 0
fi

echo "🔨 Building $SCHEME (Release)..."

# Clean previous archive
rm -rf "$ARCHIVE_PATH"

# Build the release archive
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    -quiet

if [ ! -d "$ARCHIVE_PATH/Products/Applications/$APP_NAME" ]; then
    echo "❌ Archive failed — .app not found."
    exit 1
fi

# Copy the .app to the project's build/ directory
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/$APP_NAME"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME" "$OUTPUT_DIR/$APP_NAME"

# Clean up archive
rm -rf "$ARCHIVE_PATH"

echo ""
echo "✅ Build complete!"
echo "   $OUTPUT_DIR/$APP_NAME"
echo ""
echo "   To launch:  open \"$OUTPUT_DIR/$APP_NAME\""
echo ""
echo "   If permissions aren't working, run:"
echo "   ./build-release.sh --reset-permissions"
