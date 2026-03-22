#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/Configurations/Version.xcconfig"
APP_DISPLAY_NAME="多国语言同声翻译"
VERSION="$(awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' "$VERSION_FILE" | tr -d '[:space:]')"
DIST_DIR="$ROOT/dist"
DERIVED="$ROOT/.xcode-release"
BUILT_APP_PATH="$DERIVED/Build/Products/Release/OfflineInterpreterApp.app"
DMG_NAME="${APP_DISPLAY_NAME}-v${VERSION}-macOS.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/offline-interpreter-dmg.XXXXXX")"
STAGED_APP_PATH="$STAGE_DIR/${APP_DISPLAY_NAME}.app"
VOLUME_NAME="${APP_DISPLAY_NAME} v${VERSION}"
RW_DMG="$(mktemp "${TMPDIR:-/tmp}/offline-interpreter-rw.XXXXXX.dmg")"
MOUNT_POINT="/Volumes/$VOLUME_NAME"
RESOURCES_DIR="$ROOT/Resources"
BACKGROUND_PNG="$RESOURCES_DIR/dmg-background.png"
ICON_ICNS="$RESOURCES_DIR/AppIcon.icns"
WINDOW_BOUNDS="{140, 120, 1060, 670}"
APP_POSITION="{230, 315}"
APPLICATIONS_POSITION="{690, 315}"
ICON_SIZE="136"
TEXT_SIZE="16"

cleanup() {
    if mount | grep -Fq "$MOUNT_POINT"; then
        hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGE_DIR"
    rm -f "$RW_DMG"
}
trap cleanup EXIT

mkdir -p "$DIST_DIR"

if [[ ! -d "$BUILT_APP_PATH" ]]; then
    "$ROOT/scripts/build_release_zip.sh" >/dev/null
fi

if [[ ! -d "$BUILT_APP_PATH" ]]; then
    echo "未找到 Release app：$BUILT_APP_PATH" >&2
    exit 1
fi

if [[ ! -f "$BACKGROUND_PNG" || ! -f "$ICON_ICNS" ]]; then
    "$ROOT/scripts/build_release_zip.sh" >/dev/null
fi

rm -f "$DMG_PATH"
cp -R "$BUILT_APP_PATH" "$STAGED_APP_PATH"
ln -s /Applications "$STAGE_DIR/Applications"
mkdir -p "$STAGE_DIR/.background"
cp "$BACKGROUND_PNG" "$STAGE_DIR/.background/background.png"
cp "$ICON_ICNS" "$STAGE_DIR/.VolumeIcon.icns"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW_DMG" >/dev/null

hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -mountpoint "$MOUNT_POINT" \
  "$RW_DMG" >/dev/null

SetFile -a C "$MOUNT_POINT" >/dev/null 2>&1 || true

/usr/bin/osascript <<EOF >/dev/null
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to ${WINDOW_BOUNDS}
        set arrangement of the icon view options of container window to not arranged
        set icon size of the icon view options of container window to ${ICON_SIZE}
        set text size of the icon view options of container window to ${TEXT_SIZE}
        set background picture of the icon view options of container window to file ".background:background.png"
        set position of item "${APP_DISPLAY_NAME}.app" of container window to ${APP_POSITION}
        set position of item "Applications" of container window to ${APPLICATIONS_POSITION}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
EOF

SetFile -a V "$MOUNT_POINT/.background" "$MOUNT_POINT/.background/background.png" "$MOUNT_POINT/.VolumeIcon.icns" >/dev/null 2>&1 || true

sync
hdiutil detach "$MOUNT_POINT" >/dev/null
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null

echo "Release DMG 已生成：$DMG_PATH"
