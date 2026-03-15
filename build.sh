#!/bin/bash
# Build MacChill
# Usage: ./build.sh [debug|release]

set -euo pipefail

MODE="${1:-debug}"
SCHEME="MacChill"
PROJECT="MacChill.xcodeproj"

if [ "$MODE" = "release" ]; then
    CONFIG="Release"
else
    CONFIG="Debug"
fi

echo "Building MacChill ($CONFIG)..."

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath build \
    build 2>&1 | tail -20

BUILD_DIR="build/Build/Products/$CONFIG"

if [ -d "$BUILD_DIR/MacChill.app" ]; then
    echo ""
    echo "Build successful!"
    echo "App location: $BUILD_DIR/MacChill.app"
    echo ""
    echo "To install to /Applications:"
    echo "  cp -r $BUILD_DIR/MacChill.app /Applications/"
    echo ""
    echo "To run directly:"
    echo "  open $BUILD_DIR/MacChill.app"
else
    echo "Build failed."
    exit 1
fi
