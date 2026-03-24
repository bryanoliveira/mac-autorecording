#!/bin/bash
#
# build-release.sh
# Builds MeetingAssistant in Release configuration and places
# the .app bundle in the project's build/ directory.
#
# Usage:  ./build-release.sh
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$PROJECT_DIR/MeetingAssistant.xcodeproj"
SCHEME="MeetingAssistant"
ARCHIVE_PATH="/tmp/MeetingAssistant.xcarchive"
OUTPUT_DIR="$PROJECT_DIR/build"
APP_NAME="MeetingAssistant.app"

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
