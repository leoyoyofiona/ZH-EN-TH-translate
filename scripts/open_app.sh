#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_DISPLAY_NAME="多国语言同声翻译"
SCHEME="OfflineInterpreterApp"
PROJECT="$ROOT/OfflineInterpreterApp.xcodeproj"
DERIVED_DATA="$ROOT/.xcodebuild/DerivedData"
CONFIGURATION="${BUILD_CONFIGURATION:-Debug}"
EXPECTED_TEAM_ID="967J4F9277"
APP_DIR="$HOME/Applications/${APP_DISPLAY_NAME}.app"
SOURCE_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/OfflineInterpreterApp.app"
FORCE_REBUILD="${1:-}"

app_has_expected_signature() {
    local app_path="$1"
    [[ -d "$app_path" ]] || return 1

    local signature_output
    signature_output="$(codesign -dvv "$app_path" 2>&1 || true)"
    grep -q "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$signature_output"
}

build_signed_app() {
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "platform=macOS" \
        -derivedDataPath "$DERIVED_DATA" \
        build >/tmp/offline-interpreter-xcodebuild.log

    if ! app_has_expected_signature "$SOURCE_APP"; then
        echo "Refusing to install unsigned or adhoc build." >&2
        codesign -dvv "$SOURCE_APP" 2>&1 || true
        exit 1
    fi

    pkill -f "$APP_DIR/Contents/MacOS/OfflineInterpreterApp" >/dev/null 2>&1 || true
    rm -rf "$APP_DIR"
    ditto "$SOURCE_APP" "$APP_DIR"

    if ! app_has_expected_signature "$APP_DIR"; then
        echo "Installed app lost its Apple Development signature." >&2
        exit 1
    fi
}

if [[ "$FORCE_REBUILD" == "--rebuild" || ! -d "$APP_DIR" ]] || ! app_has_expected_signature "$APP_DIR"; then
    build_signed_app
fi

open "$APP_DIR"
