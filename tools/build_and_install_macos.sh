#!/bin/bash

set -e

PROJECT_ROOT="/Users/lawrencewong/Movies/vietnamese_shadowing"
BUILD_APP="$PROJECT_ROOT/build/macos/Build/Products/Release/vietnamese_shadowing.app"

INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/Vietnamese Shadowing.app"

echo "========================================"
echo "Building Vietnamese Shadowing"
echo "========================================"

cd "$PROJECT_ROOT"

mkdir -p "$INSTALL_DIR"

# Make sure the development ORT environment variable cannot
# accidentally affect the packaged application.
unset ORT_DYLIB_PATH

echo "Cleaning Flutter build..."
flutter clean

echo "Getting Flutter packages..."
flutter pub get

echo "Building macOS Release..."
flutter build macos --release

if [ ! -d "$BUILD_APP" ]; then
    echo ""
    echo "ERROR: Release application was not found:"
    echo "$BUILD_APP"
    exit 1
fi

echo ""
echo "Installing:"
echo "$INSTALL_APP"

rm -rf "$INSTALL_APP"

ditto "$BUILD_APP" "$INSTALL_APP"

echo ""
echo "========================================"
echo "Installation complete"
echo "========================================"
echo ""
echo "Application:"
echo "$INSTALL_APP"
echo ""

open "$INSTALL_APP"
