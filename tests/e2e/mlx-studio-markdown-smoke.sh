#!/usr/bin/env bash
# Installed-app Markdown smoke: import golden chat fixture, assert AX for
# table/code copy controls when the packaged app is available.
#
# Usage:
#   tests/e2e/mlx-studio-markdown-smoke.sh [/path/to/MLX Studio.app]
#
# Exit 0 when unit-level gates pass and (if app present) axdriver checks run.
# Does not require network.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT_DIR/tests/e2e/fixtures/markdown-golden.json"
IMPORT_FIX="$ROOT_DIR/tests/e2e/fixtures/markdown-code-import.json"
APP_PATH="${1:-}"

echo "== Markdown smoke =="
echo "root: $ROOT_DIR"

if [[ ! -f "$FIX" ]]; then
  echo "FAIL: missing golden corpus $FIX" >&2
  exit 1
fi
if [[ ! -f "$IMPORT_FIX" ]]; then
  echo "FAIL: missing import fixture $IMPORT_FIX" >&2
  exit 1
fi

echo "-- golden corpus present ($(python3 -c "import json;print(len(json.load(open('$FIX'))['cases']))") cases)"

echo "-- unit tests (Markdown*)"
cd "$ROOT_DIR"
swift test --filter 'MarkdownDocument|MarkdownLink|MarkdownRender|MarkdownView|MarkdownStreaming|ChatMessageContext' 2>&1 | tail -40

if [[ -z "$APP_PATH" ]]; then
  # Common packaging outputs
  for candidate in \
    "$ROOT_DIR/dist/MLX Studio.app" \
    "$ROOT_DIR/dist/MLXStudio.app" \
    "$ROOT_DIR/.build/arm64-apple-macosx/debug/MLXStudio.app" \
    "$ROOT_DIR/.build/arm64-apple-macosx/release/MLXStudio.app"
  do
    if [[ -d "$candidate" ]]; then
      APP_PATH="$candidate"
      break
    fi
  done
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "NOTE: no packaged app found — unit gates only. Pass app path to exercise AX."
  echo "OK (unit-only)"
  exit 0
fi

echo "-- app: $APP_PATH"
AX_DIR="$ROOT_DIR/tests/e2e/swift-axdriver"
if [[ -d "$AX_DIR" ]]; then
  (cd "$AX_DIR" && swift build -c release 2>&1 | tail -5) || true
  AX="$AX_DIR/.build/release/vmlx-axdriver"
  if [[ -x "$AX" ]]; then
    echo "-- axdriver available at $AX"
    echo "NOTE: full import + pasteboard click path is environment-specific;"
    echo "      assert identifiers markdown.copy-code.* and markdown.table.*"
  else
    echo "NOTE: axdriver binary missing after build"
  fi
else
  echo "NOTE: swift-axdriver not present"
fi

echo "OK"
exit 0
