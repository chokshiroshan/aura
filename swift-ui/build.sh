#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="Aura"
BUNDLE_ID="ai.aura.desktop"
VERSION="0.1.0"
BUILD_NUM="1"
BINARY=".build/release/Aura"
APP_BUNDLE="build/${APP_NAME}.app"
CODEX_APP_SERVER_PATH="${CODEX_APP_SERVER_PATH:-}"

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
rm -rf "build/Orb.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

RESOURCE_BUNDLE="$(find .build -path "*/release/Aura_Aura.bundle" -type d | head -n 1)"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
fi
if [[ -d "Sources/Aura/Resources/CatMemes" ]]; then
    cp -R "Sources/Aura/Resources/CatMemes" "$APP_BUNDLE/Contents/Resources/CatMemes"
fi

if [[ -z "$CODEX_APP_SERVER_PATH" ]]; then
    for candidate in \
        "$HOME/codex-source/codex-rs/target/aarch64-apple-darwin/release/codex-app-server" \
        "$HOME/codex-source/codex-rs/target/release/codex-app-server"; do
        if [[ -x "$candidate" ]]; then
            CODEX_APP_SERVER_PATH="$candidate"
            break
        fi
    done
fi

if [[ ! -x "$CODEX_APP_SERVER_PATH" ]]; then
    echo "❌ codex-app-server not found. Build it with:"
    echo "   cargo build --release -p codex-app-server"
    echo "   or set CODEX_APP_SERVER_PATH=/path/to/codex-app-server"
    exit 1
fi

cp "$CODEX_APP_SERVER_PATH" "$APP_BUNDLE/Contents/MacOS/codex-app-server"
chmod +x "$APP_BUNDLE/Contents/MacOS/codex-app-server"

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
    <string>Aura needs microphone access for voice interaction.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Aura needs accessibility access for screen awareness and text injection.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Aura needs screen capture to see what you're working on.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Code sign
# Use a stable signing identity when available so macOS TCC permissions survive
# rebuilds. Ad-hoc signing changes the code identity on every build.
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Developer ID Application:/ { print $2; exit }'
    )"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Apple Development:|Local Code Signing/ { print $2; exit }'
    )"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
fi

echo "🔏 Signing with ${SIGN_IDENTITY}"
if [[ -f "Aura.entitlements" ]]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements Aura.entitlements "$APP_BUNDLE"
else
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi

APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ${APP_NAME} v${VERSION} (${APP_SIZE})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  cp -r $APP_BUNDLE /Applications/"
echo ""
