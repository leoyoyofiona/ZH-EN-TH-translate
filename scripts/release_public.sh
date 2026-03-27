#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/build_release_zip.sh"
"$ROOT/scripts/build_release_dmg.sh"
"$ROOT/scripts/notarize_release.sh"
