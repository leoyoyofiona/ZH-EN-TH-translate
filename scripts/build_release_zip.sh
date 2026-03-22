#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/OfflineInterpreterApp.xcodeproj"
SCHEME="OfflineInterpreterApp"
DERIVED="$ROOT/.xcode-release"
DIST_DIR="$ROOT/dist"
VERSION_FILE="$ROOT/Configurations/Version.xcconfig"
APP_DISPLAY_NAME="多国语言同声翻译"
VERSION="$(awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' "$VERSION_FILE" | tr -d '[:space:]')"
ARCHIVE_NAME="${APP_DISPLAY_NAME}-v${VERSION}-macOS"
BUILT_APP_PATH="$DERIVED/Build/Products/Release/OfflineInterpreterApp.app"
ZIP_PATH="$DIST_DIR/${ARCHIVE_NAME}.zip"
RESOURCES_DIR="$ROOT/Resources"
ICON_PNG="$RESOURCES_DIR/AppIcon-base.png"
ICON_ICNS="$RESOURCES_DIR/AppIcon.icns"
ZIP_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/offline-interpreter-zip.XXXXXX")"
STAGED_APP_PATH="$ZIP_STAGE/${APP_DISPLAY_NAME}.app"

mkdir -p "$DIST_DIR"
rm -rf "$DERIVED" "$ZIP_PATH"
trap 'rm -rf "$ZIP_STAGE"' EXIT

generate_brand_assets() {
  xcrun swift "$ROOT/scripts/render_brand_assets.swift" "$ROOT" >/dev/null
}

build_icns() {
  local source_png="$1"
  local target_icns="$2"
  local iconset_dir
  iconset_dir="$(mktemp -d "${TMPDIR:-/tmp}/offline-interpreter-iconset.XXXXXX").iconset"
  mkdir -p "$iconset_dir"

  sips -z 16 16     "$source_png" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips -z 32 32     "$source_png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$source_png" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips -z 64 64     "$source_png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$source_png" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips -z 256 256   "$source_png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$source_png" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips -z 512 512   "$source_png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$source_png" --out "$iconset_dir/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$source_png" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$iconset_dir" -o "$target_icns"
  rm -rf "$iconset_dir"
}

resign_app() {
  local app_path="$1"
  local signing_identity
  signing_identity="$(codesign -dvv "$app_path" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
  if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
  fi

  codesign --force --deep --sign "$signing_identity" --timestamp=none "$app_path"
}

generate_brand_assets
build_icns "$ICON_PNG" "$ICON_ICNS"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  build

if [[ ! -d "$BUILT_APP_PATH" ]]; then
  echo "未找到 Release app：$BUILT_APP_PATH" >&2
  exit 1
fi

mkdir -p "$BUILT_APP_PATH/Contents/Resources"
cp "$ICON_ICNS" "$BUILT_APP_PATH/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$BUILT_APP_PATH/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$BUILT_APP_PATH/Contents/Info.plist"
resign_app "$BUILT_APP_PATH"

cp -R "$BUILT_APP_PATH" "$STAGED_APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP_PATH" "$ZIP_PATH"
echo "Release ZIP 已生成：$ZIP_PATH"
