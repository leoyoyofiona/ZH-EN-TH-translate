#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/Configurations/Version.xcconfig"
APP_DISPLAY_NAME="多国语言同声翻译"
VERSION="$(awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' "$VERSION_FILE" | tr -d '[:space:]')"
DIST_DIR="$ROOT/dist"
DERIVED="$ROOT/.xcode-release"
BUILT_APP_PATH="$DERIVED/Build/Products/Release/OfflineInterpreterApp.app"
DMG_NAME="multilingual-live-translator-v${VERSION}-macOS.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/offline-interpreter-dmg.XXXXXX")"
STAGED_APP_PATH="$STAGE_DIR/${APP_DISPLAY_NAME}.app"
VOLUME_NAME="${APP_DISPLAY_NAME} v${VERSION}"
RW_DMG="$(mktemp "${TMPDIR:-/tmp}/offline-interpreter-rw.XXXXXX.dmg")"
MOUNT_POINT="/Volumes/$VOLUME_NAME"
RESOURCES_DIR="$ROOT/Resources"
BACKGROUND_PNG="$RESOURCES_DIR/dmg-background.png"
ICON_ICNS="$RESOURCES_DIR/AppIcon.icns"
INSTALL_NOTE_PATH="$STAGE_DIR/首次打开说明.txt"
WINDOW_BOUNDS="{140, 120, 1060, 670}"
APP_POSITION="{230, 315}"
APPLICATIONS_POSITION="{690, 315}"
ICON_SIZE="136"
TEXT_SIZE="16"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
ALLOW_DEV_SIGNING="${ALLOW_DEV_SIGNING:-0}"

cleanup() {
    if mount | grep -Fq "$MOUNT_POINT"; then
        hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGE_DIR"
    rm -f "$RW_DMG"
}
trap cleanup EXIT

resolve_signing_identity() {
    if [[ -n "$SIGNING_IDENTITY" ]]; then
        return
    fi

    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null |
        awk -F'"' '/Developer ID Application:/ {print $2; exit}'
    )"

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        return
    fi

    if [[ "$ALLOW_DEV_SIGNING" == "1" ]]; then
        SIGNING_IDENTITY="$(
            security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null |
            awk -F'"' '/Apple Development:/ {print $2; exit}'
        )"
        if [[ -n "$SIGNING_IDENTITY" ]]; then
            echo "警告：未找到 Developer ID Application，当前改用 Apple Development 生成仅限本机测试的 DMG。" >&2
            return
        fi
    fi

    cat >&2 <<'EOF'
错误：未找到 Developer ID Application 证书。

当前这台机器不能生成适合公开分发的 DMG。
如果你只想本机测试，可这样执行：
  ALLOW_DEV_SIGNING=1 ./scripts/build_release_dmg.sh
EOF
    exit 1
}

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
cat >"$INSTALL_NOTE_PATH" <<'EOF'
多国语言同声翻译 - 首次打开说明

1. 先把“多国语言同声翻译.app”拖到 Applications。
2. 如果首次打开被 macOS 拦截，请在“终端”执行：

   xattr -dr com.apple.quarantine "/Applications/多国语言同声翻译.app"

3. 再次打开应用并按系统提示授权：
   - 屏幕录制
   - 麦克风
   - 语音识别

说明：
- 当前发布包为社区版，没有 Developer ID Application 和苹果公证。
- 手动移除隔离属性后，应用可以正常运行。
EOF

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

if ! /usr/bin/osascript <<EOF >/dev/null
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
then
    echo "警告：Finder DMG 窗口布局定制失败，继续使用默认布局生成 DMG。" >&2
fi

SetFile -a V "$MOUNT_POINT/.background" "$MOUNT_POINT/.background/background.png" "$MOUNT_POINT/.VolumeIcon.icns" >/dev/null 2>&1 || true

sync
hdiutil detach "$MOUNT_POINT" >/dev/null
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null
resolve_signing_identity
codesign --force --keychain "$LOGIN_KEYCHAIN" --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH" >/dev/null 2>&1 || true

echo "Release DMG 已生成：$DMG_PATH"
