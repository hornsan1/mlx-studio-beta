#!/usr/bin/env bash
# Executable Markdown AX contract (packaging-optional).
#
# Unit gates always run. Installed-app AX pasteboard asserts run only when
# the packaged app and Accessibility tooling are available.
#
# Usage:
#   tests/e2e/mlx-studio-markdown-smoke.sh [/path/to/MLX Studio.app]
#   MLX_STUDIO_APP="/path/to/MLX Studio.app" tests/e2e/mlx-studio-markdown-smoke.sh
#
# Exit codes:
#   0  unit gates pass AND (if app+AX available) pasteboard asserts pass
#   0  unit gates pass, app missing            → prints SKIP_NO_APP
#   0  unit gates pass, AX denied / incomplete → prints SKIP_NO_AX
#   1  unit gates fail
#   2  packaging lane: app present, AX available, assert failed
#
# Env:
#   MLX_STUDIO_APP   path to packaged .app (overrides positional when set)
#   BUNDLE_ID        defaults domain (default: ai.dealign.mlxstudio.beta)
#
# Does not require network. Not a hard PR CI gate until packaging owns exit 2.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT_DIR/tests/e2e/fixtures/markdown-golden.json"
IMPORT_FIX="$ROOT_DIR/tests/e2e/fixtures/markdown-code-import.json"
AX_DIR="$ROOT_DIR/tests/e2e/swift-axdriver"
AX_BIN="$AX_DIR/.build/release/vmlx-axdriver"
REPORT_DIR="$ROOT_DIR/tests/e2e/reports"
BUNDLE_ID="${BUNDLE_ID:-ai.dealign.mlxstudio.beta}"
TS="$(date +%Y%m%d-%H%M%S)"
TMP_APP="/tmp/MLX Studio Markdown Smoke.app"
PID=""
EXPECTED_CODE_BODY='print("MARKDOWN_E2E")'
SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
ASSISTANT_TURN_ID="ffffffff-0000-1111-2222-333333333333"

# Prefer env over positional; positional remains for manual packaging runs.
APP_PATH="${MLX_STUDIO_APP:-${1:-}}"

note() {
  printf '==> %s\n' "$*"
}

fail_unit() {
  echo "FAIL: $*" >&2
  exit 1
}

fail_assert() {
  echo "FAIL_ASSERT: $*" >&2
  exit 2
}

skip_no_app() {
  echo "SKIP_NO_APP: $*"
  echo "OK (unit gates only; packaging AX skipped)"
  exit 0
}

skip_no_ax() {
  echo "SKIP_NO_AX: $*"
  echo "OK (unit gates only; AX/pasteboard path skipped)"
  echo "Manual checklist when automation skipped:"
  echo "  1. Import $IMPORT_FIX (or open a chat with a fenced code block)"
  echo "  2. Focus the code Copy control (markdown.copy-code.*)"
  echo "  3. Activate copy; pbpaste should equal: $EXPECTED_CODE_BODY"
  echo "  4. Optional: light/dark screenshots under tests/e2e/reports/"
  exit 0
}

cleanup() {
  if [[ -n "${PID:-}" ]]; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  pkill -x MLXStudio 2>/dev/null || true
  rm -rf "$TMP_APP" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Unit gates (always)
# ---------------------------------------------------------------------------

echo "== Markdown smoke =="
echo "root: $ROOT_DIR"
echo "contract: exit 0=pass|SKIP_NO_APP|SKIP_NO_AX  1=unit fail  2=AX assert fail"

if [[ ! -f "$FIX" ]]; then
  fail_unit "missing golden corpus $FIX"
fi
if [[ ! -f "$IMPORT_FIX" ]]; then
  fail_unit "missing import fixture $IMPORT_FIX"
fi

CASE_COUNT="$(python3 -c "import json; print(len(json.load(open('$FIX'))['cases']))")"
note "golden corpus present ($CASE_COUNT cases)"

# Expected code body from the import fixture (keeps smoke aligned with fixture).
FIXTURE_BODY="$(
  IMPORT_FIX="$IMPORT_FIX" python3 - <<'PY'
import json, os, re
path = os.environ["IMPORT_FIX"]
content = json.load(open(path))["messages"][1]["content"]
m = re.search(r"```(?:swift)?\n(.*?)```", content, re.S)
if not m:
    raise SystemExit("import fixture missing fenced code body")
print(m.group(1).rstrip("\n"))
PY
)"
EXPECTED_CODE_BODY="$FIXTURE_BODY"
note "expected code pasteboard body: $EXPECTED_CODE_BODY"

note "unit tests (Markdown*)"
cd "$ROOT_DIR"
set +e
UNIT_LOG="$REPORT_DIR/markdown-smoke-unit-$TS.log"
mkdir -p "$REPORT_DIR"
swift test --filter 'MarkdownDocument|MarkdownLink|MarkdownRender|MarkdownView|MarkdownStreaming|ChatMessageContext' \
  >"$UNIT_LOG" 2>&1
UNIT_RC=$?
set -e
tail -40 "$UNIT_LOG" || true
if [[ "$UNIT_RC" -ne 0 ]]; then
  fail_unit "swift test filter failed (exit $UNIT_RC); full log: $UNIT_LOG"
fi
note "unit gates passed (log: $UNIT_LOG)"

# ---------------------------------------------------------------------------
# Resolve packaged app
# ---------------------------------------------------------------------------

if [[ -z "$APP_PATH" ]]; then
  for candidate in \
    "$ROOT_DIR/dist/MLX Studio.app" \
    "$ROOT_DIR/dist/MLXStudio.app" \
    "$ROOT_DIR/.build/arm64-apple-macosx/debug/MLXStudio.app" \
    "$ROOT_DIR/.build/arm64-apple-macosx/release/MLXStudio.app" \
    "/tmp/mlx-studio-beta-dist/MLX Studio.app"
  do
    if [[ -d "$candidate" ]]; then
      APP_PATH="$candidate"
      break
    fi
  done
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  skip_no_app "no packaged app found (set MLX_STUDIO_APP or pass path as \$1)"
fi

note "app: $APP_PATH"

# ---------------------------------------------------------------------------
# AX tooling + permission
# ---------------------------------------------------------------------------

if [[ ! -d "$AX_DIR" ]]; then
  skip_no_ax "swift-axdriver directory missing at $AX_DIR"
fi

note "building axdriver"
set +e
(cd "$AX_DIR" && swift build -c release) >"$REPORT_DIR/markdown-smoke-axbuild-$TS.log" 2>&1
AX_BUILD_RC=$?
set -e
if [[ "$AX_BUILD_RC" -ne 0 || ! -x "$AX_BIN" ]]; then
  skip_no_ax "axdriver build failed or binary missing (see $REPORT_DIR/markdown-smoke-axbuild-$TS.log)"
fi
note "axdriver: $AX_BIN"

# Permission probe without prompting (prompt=false).
set +e
AX_TRUSTED="$(
  /usr/bin/swift -e 'import ApplicationServices; print(AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary) ? "yes" : "no")' 2>/dev/null
)"
set -e
if [[ "$AX_TRUSTED" != "yes" ]]; then
  skip_no_ax "Accessibility permission denied for this terminal (System Settings → Privacy & Security → Accessibility)"
fi
note "AX permission: trusted"

# ---------------------------------------------------------------------------
# Launch app with seeded markdown chat (Studio session store)
# ---------------------------------------------------------------------------

note "seeding Studio chat session from import fixture content"
ASSISTANT_CONTENT="$(
  IMPORT_FIX="$IMPORT_FIX" python3 - <<'PY'
import json, os
print(json.load(open(os.environ["IMPORT_FIX"]))["messages"][1]["content"], end="")
PY
)"
USER_CONTENT="$(
  IMPORT_FIX="$IMPORT_FIX" python3 - <<'PY'
import json, os
print(json.load(open(os.environ["IMPORT_FIX"]))["messages"][0]["content"], end="")
PY
)"

SESSION_JSON="$(
  ASSISTANT_CONTENT="$ASSISTANT_CONTENT" \
  USER_CONTENT="$USER_CONTENT" \
  SESSION_ID="$SESSION_ID" \
  ASSISTANT_TURN_ID="$ASSISTANT_TURN_ID" \
  /usr/bin/python3 - <<'PY'
import json, os

assistant = os.environ["ASSISTANT_CONTENT"]
user = os.environ["USER_CONTENT"]
session_id = os.environ["SESSION_ID"]
assistant_id = os.environ["ASSISTANT_TURN_ID"]
# JSONEncoder Date default is seconds since 2001-01-01 (Reference Date).
created = 803000000.0
print(json.dumps([{
    "id": session_id,
    "title": "Markdown E2E",
    "modelName": "Local test model",
    "turns": [
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "role": "user",
            "content": user,
            "createdAt": created,
            "streamState": "complete",
        },
        {
            "id": assistant_id,
            "role": "assistant",
            "content": assistant,
            "createdAt": created + 1,
            "streamState": "complete",
        },
    ],
    "createdAt": created,
    "updatedAt": created + 1,
    "isPinned": False,
}], separators=(",", ":")))
PY
)"
SESSION_HEX="$(printf '%s' "$SESSION_JSON" | /usr/bin/xxd -p -c 256 | tr -d '\n')"

defaults write "$BUNDLE_ID" mlxstudio.onboardingComplete -bool true
defaults write "$BUNDLE_ID" mlxstudio.experienceMode -string beginner
defaults write "$BUNDLE_ID" mlxstudio.chat.sessions -data "$SESSION_HEX"
defaults write "$BUNDLE_ID" mlxstudio.chat.selectedSessionID "$SESSION_ID"

pkill -x MLXStudio 2>/dev/null || true
rm -rf "$TMP_APP"
/usr/bin/ditto --noextattr "$APP_PATH" "$TMP_APP"
xattr -cr "$TMP_APP" 2>/dev/null || true

MLX_BIN="$TMP_APP/Contents/MacOS/MLXStudio"
if [[ ! -x "$MLX_BIN" ]]; then
  # Some packages use a different executable name.
  if [[ -x "$TMP_APP/Contents/MacOS/MLX Studio" ]]; then
    MLX_BIN="$TMP_APP/Contents/MacOS/MLX Studio"
  else
    fail_assert "app binary missing under $TMP_APP/Contents/MacOS"
  fi
fi

note "launching app"
"$MLX_BIN" -ApplePersistenceIgnoreState YES \
  >"$REPORT_DIR/markdown-smoke-app-$TS.log" 2>&1 &
PID="$!"
sleep 2
if ! ps -p "$PID" >/dev/null 2>&1; then
  fail_assert "app exited immediately after launch (see $REPORT_DIR/markdown-smoke-app-$TS.log)"
fi

# Bring main surface into view.
"$AX_BIN" wait "$PID" "Chat" 20 >"$REPORT_DIR/markdown-smoke-wait-chat-$TS.txt" 2>&1 || true
"$AX_BIN" click "$PID" "Chat" >"$REPORT_DIR/markdown-smoke-click-chat-$TS.txt" 2>&1 || true
sleep 1

# Prefer the seeded session title if visible in Library/Chat history.
"$AX_BIN" wait "$PID" "Markdown E2E" 15 >"$REPORT_DIR/markdown-smoke-wait-session-$TS.txt" 2>&1 || true
"$AX_BIN" click "$PID" "Markdown E2E" >"$REPORT_DIR/markdown-smoke-click-session-$TS.txt" 2>&1 || true
sleep 1

# Probe for stable copy IDs (PR1a: markdown.copy-code.<uuid>.<start>-<end|open>)
# and legacy ordinal form markdown.copy-code.N
GREP_OUT="$REPORT_DIR/markdown-smoke-copy-grep-$TS.txt"
set +e
"$AX_BIN" grep "$PID" "markdown.copy-code" >"$GREP_OUT" 2>&1
GREP_RC=$?
set -e

if [[ "$GREP_RC" -ne 0 ]] || ! grep -q "markdown.copy-code" "$GREP_OUT"; then
  "$AX_BIN" dump "$PID" >"$REPORT_DIR/markdown-smoke-axtree-$TS.txt" 2>&1 || true
  "$AX_BIN" shot "$PID" "$REPORT_DIR/markdown-smoke-$TS.png" 2>/dev/null || true
  fail_assert "no markdown.copy-code.* control found (see $GREP_OUT and axtree dump)"
fi

COPY_ID="$(
  GREP_OUT="$GREP_OUT" /usr/bin/python3 - <<'PY'
import os, re
text = open(os.environ["GREP_OUT"], encoding="utf-8", errors="replace").read()
# Prefer full stable IDs; fall back to legacy ordinal.
ids = re.findall(r"markdown\.copy-code\.[A-Za-z0-9._-]+", text)
if not ids:
    raise SystemExit(1)
# Prefer non-open finalized IDs when both exist.
final = [i for i in ids if not i.endswith("-open")]
print((final or ids)[0])
PY
)" || fail_assert "could not parse copy-code identifier from $GREP_OUT"

note "clicking copy control: $COPY_ID"
# Clear pasteboard so a stale value cannot satisfy the assert.
printf '' | /usr/bin/pbcopy 2>/dev/null || true

set +e
"$AX_BIN" click "$PID" "$COPY_ID" >"$REPORT_DIR/markdown-smoke-click-copy-$TS.txt" 2>&1
CLICK_RC=$?
set -e
if [[ "$CLICK_RC" -ne 0 ]]; then
  # Fallback: click by accessibility label.
  set +e
  "$AX_BIN" click "$PID" "Copy code" >"$REPORT_DIR/markdown-smoke-click-copy-label-$TS.txt" 2>&1
  CLICK_RC=$?
  set -e
fi
if [[ "$CLICK_RC" -ne 0 ]]; then
  fail_assert "failed to click copy control $COPY_ID (rc=$CLICK_RC)"
fi

sleep 0.5
PASTEBOARD="$(/usr/bin/pbpaste | tr -d '\r')"
# Normalize trailing newline for comparison.
PASTE_NORM="$(printf '%s' "$PASTEBOARD" | sed -e 's/[[:space:]]*$//')"
EXPECT_NORM="$(printf '%s' "$EXPECTED_CODE_BODY" | sed -e 's/[[:space:]]*$//')"

if [[ "$PASTE_NORM" != "$EXPECT_NORM" ]]; then
  "$AX_BIN" dump "$PID" >"$REPORT_DIR/markdown-smoke-axtree-fail-$TS.txt" 2>&1 || true
  "$AX_BIN" shot "$PID" "$REPORT_DIR/markdown-smoke-fail-$TS.png" 2>/dev/null || true
  fail_assert "pasteboard mismatch
  expected: $EXPECT_NORM
  actual:   $PASTE_NORM"
fi

note "pasteboard assert passed: $EXPECT_NORM"

# Optional: table copy-markdown control (best-effort; does not fail packaging
# if absent — code copy is the hard assert for this contract).
TABLE_GREP="$REPORT_DIR/markdown-smoke-table-grep-$TS.txt"
if "$AX_BIN" grep "$PID" "markdown.table" >"$TABLE_GREP" 2>&1 && grep -q "markdown.table" "$TABLE_GREP"; then
  note "table control present (optional probe ok)"
else
  note "table control not observed (optional; not asserted)"
fi

"$AX_BIN" shot "$PID" "$REPORT_DIR/markdown-smoke-$TS.png" 2>/dev/null || true
note "screenshot (best-effort): $REPORT_DIR/markdown-smoke-$TS.png"

echo "OK (unit gates + AX pasteboard asserts)"
exit 0
