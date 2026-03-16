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
APPLICATIONS_DIR="${APPLICATIONS_DIR:-../applications}"

if [ -d "$BUILD_DIR/MacChill.app" ]; then
    mkdir -p "$APPLICATIONS_DIR"
    cp -r "$BUILD_DIR/MacChill.app" "$APPLICATIONS_DIR/"
    echo ""
    echo "Build successful!"
    echo "App location: $APPLICATIONS_DIR/MacChill.app"
    echo ""
    echo "To run directly:"
    echo "  open $APPLICATIONS_DIR/MacChill.app"
else
    echo "Build failed."
    exit 1
fi
