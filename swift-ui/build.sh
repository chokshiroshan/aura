#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="Orb"
BUNDLE_ID="ai.orb.desktop"
VERSION="0.1.0"
BUILD_NUM="1"
BINARY=".build/release/Aura"
APP_BUNDLE="build/${APP_NAME}.app"

# --- Clean ---
if [[ "$1" == "clean" ]]; then
    echo "🧹 Cleaning..."
    rm -rf .build/release build
    swift package clean 2>/dev/null || true
    echo "✅ Clean."
    exit 0
fi

if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ Build must run on macOS."
    exit 1
fi

# --- Build ---
echo "🔨 Building ${APP_NAME} v${VERSION}..."
swift build -c release 2>&1 | tail -5

if [[ ! -f "$BINARY" ]]; then
    echo "❌ Build failed."
    exit 1
fi

# --- .app Bundle ---
echo "🏗️  Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUM}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Orb needs microphone access for voice interaction.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Orb needs accessibility access for screen awareness and text injection.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Orb needs screen capture to see what you're working on.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Code sign
if [[ -f "Aura.entitlements" ]]; then
    codesign --force --deep --sign - --entitlements Aura.entitlements "$APP_BUNDLE" 2>/dev/null || true
else
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
fi

APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ${APP_NAME} v${VERSION} (${APP_SIZE})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  cp -r $APP_BUNDLE /Applications/"
echo ""
