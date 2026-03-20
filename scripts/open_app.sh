#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION_FILE="$ROOT/Configurations/Version.xcconfig"

APP_DIR="$HOME/Applications/OfflineInterpreterApp.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
FORCE_REBUILD="${1:-}"

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null | awk '/"/ {print $2; exit}')"
fi

MARKETING_VERSION="$(awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' "$VERSION_FILE" | tr -d '[:space:]')"
BUILD_NUMBER="$(awk -F'= ' '/CURRENT_PROJECT_VERSION/ {print $2; exit}' "$VERSION_FILE" | tr -d '[:space:]')"

build_app() {
    swift build

    local bin_dir
    bin_dir="$(swift build --show-bin-path)"
    local bin="$bin_dir/OfflineInterpreterApp"

    rm -rf "$APP_DIR"
    mkdir -p "$MACOS_DIR"
    cp "$bin" "$MACOS_DIR/OfflineInterpreterApp"

    cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>OfflineInterpreterApp</string>
    <key>CFBundleExecutable</key>
    <string>OfflineInterpreterApp</string>
    <key>CFBundleIdentifier</key>
    <string>local.codex.offline-interpreter</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>OfflineInterpreterApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>需要麦克风权限以执行本地离线同声传译。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>需要语音识别权限以执行本地离线同声传译。</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        codesign --force --deep --keychain "$LOGIN_KEYCHAIN" --sign "$SIGNING_IDENTITY" --identifier local.codex.offline-interpreter "$APP_DIR" || \
            codesign --force --deep --sign - --identifier local.codex.offline-interpreter "$APP_DIR"
    else
        codesign --force --deep --sign - --identifier local.codex.offline-interpreter "$APP_DIR"
    fi
}

if [[ ! -d "$APP_DIR" || "$FORCE_REBUILD" == "--rebuild" ]]; then
    build_app
fi

open "$APP_DIR"
