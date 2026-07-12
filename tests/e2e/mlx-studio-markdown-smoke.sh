#!/usr/bin/env bash
# Executable Markdown AX contract (packaging-optional).
#
# Unit gates always run. Installed-app AX pasteboard asserts run only when
# the packaged app and Accessibility tooling are available AND the fixture
# chat can be injected into the production SQLite store.
#
# Usage:
#   tests/e2e/mlx-studio-markdown-smoke.sh [/path/to/MLX Studio.app]
#   MLX_STUDIO_APP="/path/to/MLX Studio.app" tests/e2e/mlx-studio-markdown-smoke.sh
#
# Exit codes:
#   0  unit gates pass AND (if app+AX available) pasteboard asserts pass
#   0  unit gates pass, app missing            → prints SKIP_NO_APP
#   0  unit gates pass, AX denied / incomplete → prints SKIP_NO_AX
#   0  unit gates pass, SQLite seed unavailable → prints SKIP_NO_AX
#      (soft packaging: avoids false exit 2 when chat cannot be injected)
#   1  unit gates fail
#   2  packaging lane: app present, AX available, seed verified, assert failed
#
# Env:
#   MLX_STUDIO_APP   path to packaged .app (overrides positional when set)
#   BUNDLE_ID        defaults domain (default: ai.dealign.mlxstudio.beta)
#   VMLX_SQLITE      override path to vmlx.sqlite3 (default: Application Support)
#
# Seed notes:
#   Production RootView mounts ChatScreen (SQLite), not Studio UserDefaults.
#   Studio defaults (mlxstudio.chat.sessions) only feed chat once via
#   StudioChatHistoryMigration (mlxstudio.chat.unifiedSQLiteMigration.v1).
#   This script seeds ~/Library/Application Support/vMLX/vmlx.sqlite3 directly
#   and sets mlxstudio.chat.unifiedSelectedSessionID for durable selection.
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
VMLX_SQLITE="${VMLX_SQLITE:-$HOME/Library/Application Support/vMLX/vmlx.sqlite3}"
TS="$(date +%Y%m%d-%H%M%S)"
TMP_APP="/tmp/MLX Studio Markdown Smoke.app"
PID=""
# Fallback expected body; packaging branch overwrites from import fixture.
EXPECTED_CODE_BODY='print("MARKDOWN_E2E")'
SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
USER_TURN_ID="11111111-1111-1111-1111-111111111111"
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

print_manual_checklist() {
  echo "Manual checklist when automation skipped:"
  echo "  1. Import $IMPORT_FIX (Chat → Import conversation) or open a chat with a fenced code block"
  echo "  2. Focus the code Copy control (markdown.copy-code.*)"
  echo "  3. Activate copy; pbpaste should equal: $EXPECTED_CODE_BODY"
  echo "  4. Optional: light/dark screenshots under tests/e2e/reports/"
}

skip_no_app() {
  echo "SKIP_NO_APP: $*"
  echo "OK (unit gates only; packaging AX skipped)"
  print_manual_checklist
  exit 0
}

skip_no_ax() {
  echo "SKIP_NO_AX: $*"
  echo "OK (unit gates only; AX/pasteboard path skipped)"
  print_manual_checklist
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
# Unit gates (always) — only existence checks before swift test
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
# Fixture body (packaging branch only — after unit gates)
# ---------------------------------------------------------------------------

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
)" || skip_no_ax "import fixture $IMPORT_FIX missing fenced code body (cannot assert pasteboard)"
EXPECTED_CODE_BODY="$FIXTURE_BODY"
note "expected code pasteboard body: $EXPECTED_CODE_BODY"

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

# ---------------------------------------------------------------------------
# Seed production Chat SQLite (not Studio UserDefaults-only)
# ---------------------------------------------------------------------------
# ChatScreen reads ~/Library/Application Support/vMLX/vmlx.sqlite3.
# Studio UserDefaults migration runs only once (unifiedSQLiteMigration.v1);
# re-seeding mlxstudio.chat.sessions alone does not update live chat after
# migration has completed on the machine.

if ! command -v sqlite3 >/dev/null 2>&1; then
  skip_no_ax "sqlite3 CLI missing — cannot inject fixture into production chat DB"
fi

note "seeding production chat SQLite: $VMLX_SQLITE"
mkdir -p "$(dirname "$VMLX_SQLITE")"

# Ensure base tables exist (app may never have launched on a clean agent).
# Keep schema aligned with Database.migrate() core columns; extra columns are
# added by the app on launch if user_version is behind.
sqlite3 "$VMLX_SQLITE" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    model_path TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    reasoning TEXT,
    tool_calls_json TEXT,
    created_at REAL NOT NULL,
    FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_messages_session ON messages(session_id, created_at);
SQL

# Best-effort column upgrades so INSERT matches common app schemas without
# requiring a full user_version dance when the DB is brand new.
for col_sql in \
  "ALTER TABLE sessions ADD COLUMN model_name TEXT;" \
  "ALTER TABLE sessions ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0;" \
  "ALTER TABLE sessions ADD COLUMN collection_name TEXT;" \
  "ALTER TABLE messages ADD COLUMN is_streaming INTEGER NOT NULL DEFAULT 0;" \
  "ALTER TABLE messages ADD COLUMN image_data BLOB;" \
  "ALTER TABLE messages ADD COLUMN video_paths BLOB;" \
  "ALTER TABLE messages ADD COLUMN tool_statuses BLOB;" \
  "ALTER TABLE messages ADD COLUMN request_context TEXT NOT NULL DEFAULT '';" \
  "ALTER TABLE messages ADD COLUMN generation_state TEXT;"
do
  sqlite3 "$VMLX_SQLITE" "$col_sql" 2>/dev/null || true
done

# Unix epoch seconds (Database binds Date.timeIntervalSince1970).
NOW_UNIX="$(/usr/bin/python3 -c 'import time; print(f"{time.time():.3f}")')"
USER_UNIX="$(/usr/bin/python3 -c "print(float('${NOW_UNIX}') - 2)")"
ASSIST_UNIX="$(/usr/bin/python3 -c "print(float('${NOW_UNIX}') - 1)")"

SEED_LOG="$REPORT_DIR/markdown-smoke-sqlite-seed-$TS.log"
set +e
# Escape single quotes for SQL string literals.
sql_quote() {
  printf "%s" "$1" | sed "s/'/''/g"
}
USER_SQL="$(sql_quote "$USER_CONTENT")"
ASSIST_SQL="$(sql_quote "$ASSISTANT_CONTENT")"

sqlite3 "$VMLX_SQLITE" >"$SEED_LOG" 2>&1 <<SQL
PRAGMA foreign_keys=ON;
BEGIN;
DELETE FROM messages WHERE session_id='${SESSION_ID}';
DELETE FROM sessions WHERE id='${SESSION_ID}';
INSERT INTO sessions (id, title, model_path, model_name, is_pinned, collection_name, created_at, updated_at)
VALUES (
  '${SESSION_ID}',
  'Markdown E2E',
  NULL,
  'Local test model',
  0,
  NULL,
  ${USER_UNIX},
  ${NOW_UNIX}
);
INSERT INTO messages (id, session_id, role, content, created_at, is_streaming)
VALUES (
  '${USER_TURN_ID}',
  '${SESSION_ID}',
  'user',
  '${USER_SQL}',
  ${USER_UNIX},
  0
);
INSERT INTO messages (id, session_id, role, content, created_at, is_streaming)
VALUES (
  '${ASSISTANT_TURN_ID}',
  '${SESSION_ID}',
  'assistant',
  '${ASSIST_SQL}',
  ${ASSIST_UNIX},
  0
);
COMMIT;
SQL
SEED_RC=$?
set -e

if [[ "$SEED_RC" -ne 0 ]]; then
  skip_no_ax "SQLite seed failed (rc=$SEED_RC); see $SEED_LOG — soft skip to avoid false packaging exit 2"
fi

# Verify seed landed (production path only proceeds when content is present).
SEED_CHECK="$(sqlite3 "$VMLX_SQLITE" "SELECT content FROM messages WHERE id='${ASSISTANT_TURN_ID}';" 2>/dev/null || true)"
if [[ "$SEED_CHECK" != *"$EXPECTED_CODE_BODY"* ]]; then
  skip_no_ax "SQLite seed verification failed (assistant message missing expected code body) — soft skip to avoid false packaging exit 2"
fi
note "SQLite seed verified for session $SESSION_ID"

# Durable selection for consolidated Chat runtime (not Studio selectedSessionID).
defaults write "$BUNDLE_ID" mlxstudio.onboardingComplete -bool true
defaults write "$BUNDLE_ID" mlxstudio.experienceMode -string beginner
defaults write "$BUNDLE_ID" mlxstudio.chat.unifiedSelectedSessionID "$SESSION_ID"
# Preferred migration key is consumed once on attach; set it as a fallback for
# first-launch-after-reset agents. Harmless if already migrated.
defaults write "$BUNDLE_ID" mlxstudio.chat.unifiedPreferredSessionID "$SESSION_ID"
# Keep Studio keys aligned for Library surfaces that still read them.
defaults write "$BUNDLE_ID" mlxstudio.chat.selectedSessionID "$SESSION_ID"

# ---------------------------------------------------------------------------
# Launch app
# ---------------------------------------------------------------------------

pkill -x MLXStudio 2>/dev/null || true
rm -rf "$TMP_APP"
/usr/bin/ditto --noextattr "$APP_PATH" "$TMP_APP"
xattr -cr "$TMP_APP" 2>/dev/null || true

MLX_BIN="$TMP_APP/Contents/MacOS/MLXStudio"
if [[ ! -x "$MLX_BIN" ]]; then
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

# Prefer the seeded session title if visible in the chat session list.
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
  # Seed is verified in SQLite; missing AX control is a real packaging assert.
  fail_assert "no markdown.copy-code.* control found after SQLite seed (see $GREP_OUT and axtree dump)"
fi

COPY_ID="$(
  GREP_OUT="$GREP_OUT" /usr/bin/python3 - <<'PY'
import os, re
text = open(os.environ["GREP_OUT"], encoding="utf-8", errors="replace").read()
ids = re.findall(r"markdown\.copy-code\.[A-Za-z0-9._-]+", text)
if not ids:
    raise SystemExit(1)
final = [i for i in ids if not i.endswith("-open")]
print((final or ids)[0])
PY
)" || fail_assert "could not parse copy-code identifier from $GREP_OUT"

note "clicking copy control: $COPY_ID"
printf '' | /usr/bin/pbcopy 2>/dev/null || true

set +e
"$AX_BIN" click "$PID" "$COPY_ID" >"$REPORT_DIR/markdown-smoke-click-copy-$TS.txt" 2>&1
CLICK_RC=$?
set -e
if [[ "$CLICK_RC" -ne 0 ]]; then
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

# Optional: table copy-markdown control (best-effort; not a hard assert).
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
