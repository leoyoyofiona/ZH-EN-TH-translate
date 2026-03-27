#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DISPLAY_NAME="多国语言同声翻译"
VERSION_FILE="$ROOT/Configurations/Version.xcconfig"
VERSION="$(awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' "$VERSION_FILE" | tr -d '[:space:]')"
PROFILE_NAME="${NOTARY_PROFILE:-codex-release}"
DIST_DIR="$ROOT/dist"
ZIP_PATH="$DIST_DIR/${APP_DISPLAY_NAME}-v${VERSION}-macOS.zip"
DMG_PATH="$DIST_DIR/${APP_DISPLAY_NAME}-v${VERSION}-macOS.dmg"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "未找到 ZIP：$ZIP_PATH" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE_NAME" >/dev/null 2>&1; then
  cat >&2 <<EOF
错误：未找到 notarytool 凭据 profile：$PROFILE_NAME

请先保存苹果公证凭据，例如：
  xcrun notarytool store-credentials "$PROFILE_NAME" \\
    --apple-id "<apple-id>" \\
    --team-id "<team-id>" \\
    --password "<app-specific-password>"

或者使用 App Store Connect API key：
  xcrun notarytool store-credentials "$PROFILE_NAME" \\
    --key "<AuthKey_xxx.p8>" \\
    --key-id "<KEY_ID>" \\
    --issuer "<ISSUER_ID>"
EOF
  exit 1
fi

echo "[1/4] 提交 ZIP 到苹果公证服务"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$PROFILE_NAME" --wait

if [[ -f "$DMG_PATH" ]]; then
  echo "[2/4] 提交 DMG 到苹果公证服务"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE_NAME" --wait
fi

echo "[3/4] stapler 回写"
xcrun stapler staple "$ZIP_PATH" >/dev/null 2>&1 || true
if [[ -f "$DMG_PATH" ]]; then
  xcrun stapler staple "$DMG_PATH"
fi

echo "[4/4] Gatekeeper 复检"
"$ROOT/scripts/validate_release.sh"

echo "公证完成。"
