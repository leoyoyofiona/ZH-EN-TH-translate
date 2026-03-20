#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/OfflineInterpreterApp.xcodeproj"
SCHEME="OfflineInterpreterApp"
DERIVED="$ROOT/.xcode-release"
DIST_DIR="$ROOT/dist"
VERSION_FILE="$ROOT/Configurations/Version.xcconfig"
VERSION="$(awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' "$VERSION_FILE" | tr -d '[:space:]')"
ARCHIVE_NAME="OfflineInterpreterApp-v${VERSION}-macOS"
APP_PATH="$DERIVED/Build/Products/Release/OfflineInterpreterApp.app"
ZIP_PATH="$DIST_DIR/${ARCHIVE_NAME}.zip"

mkdir -p "$DIST_DIR"
rm -rf "$DERIVED" "$ZIP_PATH"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "未找到 Release app：$APP_PATH" >&2
  exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
echo "Release ZIP 已生成：$ZIP_PATH"
