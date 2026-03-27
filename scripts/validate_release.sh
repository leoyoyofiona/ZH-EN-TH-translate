#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DISPLAY_NAME="多国语言同声翻译"
VERSION_FILE="$ROOT/Configurations/Version.xcconfig"
VERSION="$(awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' "$VERSION_FILE" | tr -d '[:space:]')"
ZIP_PATH="$ROOT/dist/multilingual-live-translator-v${VERSION}-macOS.zip"
DMG_PATH="$ROOT/dist/multilingual-live-translator-v${VERSION}-macOS.dmg"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/offline-release-validate.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "未找到 ZIP：$ZIP_PATH" >&2
  exit 1
fi

ditto -x -k "$ZIP_PATH" "$TMP_DIR"
APP_PATH="$TMP_DIR/${APP_DISPLAY_NAME}.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "ZIP 中未找到 app：$APP_PATH" >&2
  exit 1
fi

echo "[1/4] codesign verify"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "[2/4] codesign details"
codesign -dvv "$APP_PATH" 2>&1 | sed -n '1,20p'

echo "[3/4] gatekeeper check (.app)"
/usr/sbin/spctl -a -vv "$APP_PATH"

if [[ -f "$DMG_PATH" ]]; then
  echo "[4/4] gatekeeper check (.dmg)"
  /usr/sbin/spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"
fi

echo "Release validation: PASS"
