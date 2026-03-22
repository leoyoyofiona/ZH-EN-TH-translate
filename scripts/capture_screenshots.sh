#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DISPLAY_NAME="多国语言同声翻译"
EXECUTABLE_NAME="OfflineInterpreterApp"
APP="$HOME/Applications/${APP_DISPLAY_NAME}.app"
BIN="$APP/Contents/MacOS/${EXECUTABLE_NAME}"
SHOT_DIR="$ROOT/docs/screenshots"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
VERSION_FILE="$ROOT/Configurations/Version.xcconfig"
MARKETING_VERSION="$(awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' "$VERSION_FILE" | tr -d '[:space:]')"
BUILD_NUMBER="$(awk -F'= ' '/CURRENT_PROJECT_VERSION/ {print $2; exit}' "$VERSION_FILE" | tr -d '[:space:]')"

mkdir -p "$SHOT_DIR"

build_app() {
    cd "$ROOT"
    swift build >/dev/null

    local bin_dir
    bin_dir="$(swift build --show-bin-path)"

    rm -rf "$APP"
    mkdir -p "$MACOS_DIR"
    cp "$bin_dir/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"

    cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>local.codex.offline-interpreter</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_DISPLAY_NAME}</string>
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

    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="$(security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null | awk '/"/ {print $2; exit}')"
    fi

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        codesign --force --deep --keychain "$LOGIN_KEYCHAIN" --sign "$SIGNING_IDENTITY" --identifier local.codex.offline-interpreter "$APP" >/dev/null 2>&1 || \
            codesign --force --deep --sign - --identifier local.codex.offline-interpreter "$APP" >/dev/null 2>&1
    else
        codesign --force --deep --sign - --identifier local.codex.offline-interpreter "$APP" >/dev/null 2>&1
    fi
}

build_app
pkill -f "$BIN" 2>/dev/null || true
sleep 1

capture_demo() {
    local source="$1"
    local target="$2"
    local output="$3"

    pkill -f "$BIN" 2>/dev/null || true
    open -na "$APP" --args --demo-snapshot --demo-source "$source" --demo-target "$target"
    sleep 2

    local window_id
    window_id="$(xcrun swift - <<'SWIFT'
import CoreGraphics
import Foundation

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

let matches = windows.compactMap { info -> (id: CGWindowID, bounds: CGRect, owner: String, layer: Int)? in
    guard let owner = info[kCGWindowOwnerName as String] as? String,
          owner.contains("OfflineInterpreterApp") || owner.contains("多国语言同声翻译"),
          let id = info[kCGWindowNumber as String] as? NSNumber,
          let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
        return nil
    }

    let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    return (CGWindowID(id.uint32Value), bounds, owner, layer)
}
.filter { $0.bounds.width > 900 && $0.bounds.height > 400 }

guard let window = matches.max(by: { ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height) }) else {
    fputs("Unable to locate app window for screenshot.\n", stderr)
    exit(1)
}
print(window.id)
SWIFT
)"

    screencapture -x -l "$window_id" "$output"

    pkill -f "$BIN" 2>/dev/null || true
    sleep 1
}

capture_demo "en" "zh-Hans" "$SHOT_DIR/english-to-chinese.png"
capture_demo "th" "zh-Hans" "$SHOT_DIR/thai-to-chinese.png"
capture_demo "zh-Hans" "en" "$SHOT_DIR/chinese-to-english.png"

echo "Saved screenshots to $SHOT_DIR"
