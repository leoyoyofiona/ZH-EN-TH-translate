#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_DISPLAY_NAME="多国语言同声翻译"
VERSION_FILE="$ROOT/Configurations/Version.xcconfig"
VERSION="$(awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' "$VERSION_FILE" | tr -d '[:space:]')"
TAG="v${VERSION}"
ZIP_NAME="multilingual-live-translator-v${VERSION}-macOS.zip"
DMG_NAME="multilingual-live-translator-v${VERSION}-macOS.dmg"
ZIP_PATH="$ROOT/dist/${ZIP_NAME}"
DMG_PATH="$ROOT/dist/${DMG_NAME}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/offline-community-release.XXXXXX")"
NOTES_FILE="$TMP_DIR/release-notes.md"
REPO="${GITHUB_REPOSITORY:-}"
trap 'rm -rf "$TMP_DIR"' EXIT

resolve_repo() {
  if [[ -n "$REPO" ]]; then
    return
  fi

  local remote
  remote="$(git remote get-url origin)"
  case "$remote" in
    git@github.com:*.git)
      REPO="${remote#git@github.com:}"
      REPO="${REPO%.git}"
      ;;
    https://github.com/*.git)
      REPO="${remote#https://github.com/}"
      REPO="${REPO%.git}"
      ;;
    https://github.com/*)
      REPO="${remote#https://github.com/}"
      ;;
    *)
      echo "无法从 origin 解析 GitHub 仓库：$remote" >&2
      exit 1
      ;;
  esac
}

write_notes() {
  cat >"$NOTES_FILE" <<EOF2
## ${APP_DISPLAY_NAME} ${TAG}

这是 GitHub 社区版安装包，适合没有 Apple Developer ID / 苹果公证条件的维护者继续分发。

### 下载内容

- ${DMG_NAME}
- ${ZIP_NAME}

### 安装步骤

1. 下载 DMG
2. 打开 DMG
3. 将 ${APP_DISPLAY_NAME}.app 拖到 Applications
4. 在“终端”执行：

   bash
   xattr -dr com.apple.quarantine "/Applications/${APP_DISPLAY_NAME}.app"

5. 再打开应用，并按提示授权：
   - 屏幕录制
   - 麦克风
   - 语音识别

### 重要说明

- 当前发布包不是 Developer ID Application + 苹果公证正式版
- 因此首次打开前，需要手动移除 quarantine 隔离属性
- 移除隔离后，应用可以正常使用与授权
- 当前最低系统版本：macOS 26+
EOF2
}

validate_zip_codesign() {
  local extract_dir="$TMP_DIR/unzip"
  mkdir -p "$extract_dir"
  ditto -x -k "$ZIP_PATH" "$extract_dir"
  local app_path="$extract_dir/${APP_DISPLAY_NAME}.app"
  if [[ ! -d "$app_path" ]]; then
    echo "ZIP 解压后未找到 app：$app_path" >&2
    exit 1
  fi
  codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null
}

resolve_repo
ALLOW_DEV_SIGNING=1 "$ROOT/scripts/build_release_zip.sh"
ALLOW_DEV_SIGNING=1 "$ROOT/scripts/build_release_dmg.sh"
validate_zip_codesign
write_notes

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP_PATH" "$DMG_PATH" --clobber -R "$REPO"
  gh release edit "$TAG" -R "$REPO" --title "$TAG" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" "$ZIP_PATH" "$DMG_PATH" -R "$REPO" --title "$TAG" --notes-file "$NOTES_FILE"
fi

echo "社区版 GitHub Release 已更新：$REPO $TAG"
