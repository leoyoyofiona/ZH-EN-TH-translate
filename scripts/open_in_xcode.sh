#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/OfflineInterpreterApp.xcodeproj"

if ! open -Ra Xcode; then
    echo "未找到完整 Xcode。请先从 App Store 安装 Xcode，再运行此脚本。" >&2
    exit 1
fi

open -a Xcode "$PROJECT"
