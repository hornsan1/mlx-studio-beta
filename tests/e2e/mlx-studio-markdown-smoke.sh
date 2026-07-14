#!/usr/bin/env bash
# Executable Markdown AX contract (packaging-optional).
#
# Unit gates always run. Installed-app AX pasteboard asserts run only when
# the packaged app and Accessibility tooling are available AND the fixture
# chat can be injected into an isolated SQLite store.
#
# Usage:
#   tests/e2e/mlx-studio-markdown-smoke.sh [/path/to/MLX Studio.app]
#   MLX_STUDIO_APP="/path/to/MLX Studio.app" tests/e2e/mlx-studio-markdown-smoke.sh
#
# Exit codes:
#   0  unit gates pass AND (if app+AX available) pasteboard asserts pass
#   0  unit gates pass, app missing            → prints SKIP_NO_APP
#   0  unit gates pass, AX denied / incomplete → prints SKIP_NO_AX
#   2  packaging lane: app + AX are available and a fixture, launch, or AX
#      assertion failed
#   1  unit gates fail
#
# Env:
#   MLX_STUDIO_APP   path to packaged .app (overrides positional when set)
#   BUNDLE_ID        base bundle identifier for the isolated copied app
#                    (default: ai.dealign.mlxstudio.beta)
#   MLX_SMOKE_HOME   optional empty directory for isolated app state; the
#                    caller owns and retains it. By default a fresh temporary
#                    home is created and removed on exit.
#
# Isolation notes:
#   The copied app receives a unique CFBundleIdentifier and runs with a fresh
#   HOME/CFFIXED_USER_HOME. Its SQLite database is therefore separate from a
#   user's real chat history, and command-line defaults avoid writing the
#   normal MLX Studio preference domain. The text clipboard is restored on exit
#   when it can be read.
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
REQUESTED_VMLX_SQLITE="${VMLX_SQLITE:-}"
TS="$(date +%Y%m%d-%H%M%S)"
CALLER_HOME="$(cd "${HOME:?HOME must be set}" && pwd -P)"
SMOKE_HOME=""
OWN_SMOKE_HOME=0
VMLX_SQLITE=""
TMP_APP=""
SMOKE_BUNDLE_ID=""
SAVED_STATE_DIR=""
PID=""
CLIPBOARD_BACKUP=""
CLIPBOARD_WAS_READABLE=0
# Fallback expected body; packaging branch overwrites from import fixture.
EXPECTED_CODE_BODY='print("MARKDOWN_E2E")'
SESSION_ID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
USER_TURN_ID="11111111-1111-1111-1111-111111111111"
ASSISTANT_TURN_ID="FFFFFFFF-0000-1111-2222-333333333333"

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

init_smoke_home() {
  if [[ -n "$REQUESTED_VMLX_SQLITE" ]]; then
    fail_assert "VMLX_SQLITE is not supported by the isolated smoke runner; use MLX_SMOKE_HOME instead"
  fi

  if [[ -z "${MLX_SMOKE_HOME:-}" ]]; then
    SMOKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mlx-studio-markdown-smoke.XXXXXX")" \
      || fail_assert "could not create isolated smoke home"
    OWN_SMOKE_HOME=1
  else
    SMOKE_HOME="$MLX_SMOKE_HOME"
    mkdir -p "$SMOKE_HOME" || fail_assert "could not create MLX_SMOKE_HOME: $SMOKE_HOME"
    SMOKE_HOME="$(cd "$SMOKE_HOME" && pwd -P)"
    if [[ "$SMOKE_HOME" == "$CALLER_HOME" || "$SMOKE_HOME" == "/" ]]; then
      fail_assert "MLX_SMOKE_HOME must not be the real home directory or /"
    fi
    if [[ -n "$(find "$SMOKE_HOME" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      fail_assert "MLX_SMOKE_HOME must be an empty directory so no existing test state is overwritten: $SMOKE_HOME"
    fi
  fi

  SMOKE_HOME="$(cd "$SMOKE_HOME" && pwd -P)"
  VMLX_SQLITE="$SMOKE_HOME/Library/Application Support/vMLX/vmlx.sqlite3"
  TMP_APP="$SMOKE_HOME/MLX Studio Markdown Smoke.app"
  # A unique bundle ID makes UserDefaults writes from the launched app
  # disposable even on systems where cfprefsd does not honor CFFIXED_USER_HOME.
  SMOKE_BUNDLE_ID="${BUNDLE_ID}.markdownsmoke.${TS}.$RANDOM"
  # AppKit writes this outside HOME even with ApplePersistenceIgnoreState.
  SAVED_STATE_DIR="${TMPDIR%/}/${SMOKE_BUNDLE_ID}.savedState"
  CLIPBOARD_BACKUP="$SMOKE_HOME/clipboard-before.txt"
}

stop_test_app() {
  [[ -n "${PID:-}" ]] || return
  if kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
  fi
  wait "$PID" 2>/dev/null || true
  PID=""
}

cleanup() {
  stop_test_app
  if [[ "$CLIPBOARD_WAS_READABLE" == "1" && -f "$CLIPBOARD_BACKUP" ]]; then
    /usr/bin/pbcopy <"$CLIPBOARD_BACKUP" 2>/dev/null || true
  fi
  if [[ "$OWN_SMOKE_HOME" == "1" && -n "$SMOKE_HOME" ]]; then
    rm -rf "$SMOKE_HOME" 2>/dev/null || true
  elif [[ -n "$SMOKE_HOME" ]]; then
    note "preserving caller-provided isolated state: $SMOKE_HOME"
  fi
  if [[ -n "$SMOKE_BUNDLE_ID" ]]; then
    /usr/bin/defaults delete "$SMOKE_BUNDLE_ID" 2>/dev/null || true
  fi
  if [[ -n "$SAVED_STATE_DIR" ]]; then
    rm -rf "$SAVED_STATE_DIR" 2>/dev/null || true
  fi
}
trap 'exit 130' INT TERM HUP
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
swift test --filter 'MarkdownDocument|MarkdownLink|MarkdownPlainText|MarkdownRender|MarkdownView|MarkdownStreaming|ChatMessageContext' \
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

# Everything below this point is the packaging lane.  Never point it at an
# existing vmlx.sqlite3: the app is launched with a clean per-run home.
init_smoke_home
note "isolated home: $SMOKE_HOME"

# ---------------------------------------------------------------------------
# Fixture body (packaging branch only — after unit gates)
# ---------------------------------------------------------------------------

set +e
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
FIXTURE_RC=$?
ASSISTANT_CONTENT="$(
  IMPORT_FIX="$IMPORT_FIX" python3 - <<'PY'
import json, os
print(json.load(open(os.environ["IMPORT_FIX"]))["messages"][1]["content"], end="")
PY
)"
ASSISTANT_RC=$?
USER_CONTENT="$(
  IMPORT_FIX="$IMPORT_FIX" python3 - <<'PY'
import json, os
print(json.load(open(os.environ["IMPORT_FIX"]))["messages"][0]["content"], end="")
PY
)"
USER_RC=$?
set -e

if [[ "$FIXTURE_RC" -ne 0 ]]; then
  fail_assert "import fixture $IMPORT_FIX is missing a fenced code body (cannot assert pasteboard)"
fi
if [[ "$ASSISTANT_RC" -ne 0 || "$USER_RC" -ne 0 ]]; then
  fail_assert "could not load message content from import fixture $IMPORT_FIX"
fi
EXPECTED_CODE_BODY="$FIXTURE_BODY"
note "expected code pasteboard body: $EXPECTED_CODE_BODY"

# ---------------------------------------------------------------------------
# Seed isolated Chat SQLite (not Studio UserDefaults-only)
# ---------------------------------------------------------------------------
# ChatScreen reads ~/Library/Application Support/vMLX/vmlx.sqlite3.  Here that
# path is under SMOKE_HOME, verified by the Foundation CFFIXED_USER_HOME
# contract used for the app launch below.

if ! command -v sqlite3 >/dev/null 2>&1; then
  fail_assert "sqlite3 CLI missing — cannot inject fixture into isolated chat DB"
fi

note "seeding isolated chat SQLite: $VMLX_SQLITE"
mkdir -p "$(dirname "$VMLX_SQLITE")" \
  || fail_assert "could not create isolated SQLite directory for $VMLX_SQLITE"

# Seed the complete current chat schema. This avoids best-effort ALTERs: any
# schema error is a packaging-lane failure rather than a skipped AX test.
SCHEMA_LOG="$REPORT_DIR/markdown-smoke-sqlite-schema-$TS.log"
set +e
sqlite3 "$VMLX_SQLITE" >"$SCHEMA_LOG" 2>&1 <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    model_path TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    model_name TEXT,
    is_pinned INTEGER NOT NULL DEFAULT 0,
    collection_name TEXT
);
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    reasoning TEXT,
    tool_calls_json TEXT,
    created_at REAL NOT NULL,
    is_streaming INTEGER NOT NULL DEFAULT 0,
    image_data BLOB,
    video_paths BLOB,
    tool_statuses BLOB,
    request_context TEXT NOT NULL DEFAULT '',
    generation_state TEXT,
    FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_messages_session ON messages(session_id, created_at);
CREATE TABLE IF NOT EXISTS chat_drafts (
    session_id TEXT PRIMARY KEY,
    input_text TEXT NOT NULL DEFAULT '',
    image_data BLOB,
    video_paths BLOB,
    document_data BLOB,
    updated_at REAL NOT NULL,
    FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
);
PRAGMA user_version = 4;
SQL
SCHEMA_RC=$?
set -e
if [[ "$SCHEMA_RC" -ne 0 ]]; then
  fail_assert "SQLite schema setup failed (rc=$SCHEMA_RC); see $SCHEMA_LOG"
fi

for column in \
  sessions:id sessions:title sessions:model_path sessions:model_name \
  sessions:is_pinned sessions:collection_name sessions:created_at sessions:updated_at \
  messages:id messages:session_id messages:role messages:content messages:reasoning \
  messages:tool_calls_json messages:created_at messages:is_streaming messages:image_data \
  messages:video_paths messages:tool_statuses messages:request_context messages:generation_state \
  chat_drafts:session_id chat_drafts:input_text chat_drafts:document_data
do
  table="${column%%:*}"
  name="${column#*:}"
  set +e
  COLUMN_COUNT="$(sqlite3 "$VMLX_SQLITE" "SELECT COUNT(*) FROM pragma_table_info('$table') WHERE name='$name';" 2>>"$SCHEMA_LOG")"
  COLUMN_RC=$?
  set -e
  if [[ "$COLUMN_RC" -ne 0 || "$COLUMN_COUNT" != "1" ]]; then
    fail_assert "SQLite schema is missing required $table.$name (see $SCHEMA_LOG)"
  fi
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
  fail_assert "SQLite seed failed (rc=$SEED_RC); see $SEED_LOG"
fi

# Verify seed landed before launching. Uppercase UUIDs match UUID.uuidString,
# which Database.messages(for:) binds for its session lookup.
set +e
SEED_COUNT="$(sqlite3 "$VMLX_SQLITE" "SELECT COUNT(*) FROM messages WHERE id='${ASSISTANT_TURN_ID}' AND session_id='${SESSION_ID}';" 2>>"$SEED_LOG")"
SEED_COUNT_RC=$?
SEED_CHECK="$(sqlite3 "$VMLX_SQLITE" "SELECT content FROM messages WHERE id='${ASSISTANT_TURN_ID}' AND session_id='${SESSION_ID}';" 2>>"$SEED_LOG")"
SEED_CHECK_RC=$?
set -e
if [[ "$SEED_COUNT_RC" -ne 0 || "$SEED_CHECK_RC" -ne 0 ]]; then
  fail_assert "SQLite seed verification query failed; see $SEED_LOG"
fi
if [[ "$SEED_COUNT" != "1" || "$SEED_CHECK" != *"$EXPECTED_CODE_BODY"* ]]; then
  fail_assert "SQLite seed verification failed (assistant message missing expected code body); see $SEED_LOG"
fi
note "SQLite seed verified for session $SESSION_ID"

# ---------------------------------------------------------------------------
# Launch app
# ---------------------------------------------------------------------------

COPY_LOG="$REPORT_DIR/markdown-smoke-copy-$TS.log"
set +e
/usr/bin/ditto --noextattr "$APP_PATH" "$TMP_APP" >"$COPY_LOG" 2>&1
COPY_RC=$?
set -e
if [[ "$COPY_RC" -ne 0 ]]; then
  fail_assert "could not copy app into isolated smoke home (rc=$COPY_RC); see $COPY_LOG"
fi
xattr -cr "$TMP_APP" 2>/dev/null || true

INFO_PLIST="$TMP_APP/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  fail_assert "copied app is missing $INFO_PLIST"
fi
set +e
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SMOKE_BUNDLE_ID" "$INFO_PLIST" >"$COPY_LOG" 2>&1
PLIST_RC=$?
ACTUAL_SMOKE_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>>"$COPY_LOG")"
set -e
if [[ "$PLIST_RC" -ne 0 || "$ACTUAL_SMOKE_BUNDLE_ID" != "$SMOKE_BUNDLE_ID" ]]; then
  fail_assert "could not assign isolated bundle identifier (see $COPY_LOG)"
fi

# Info.plist changed on a disposable copy, so restore a valid ad-hoc signature
# before launch. Production signing/notarization is covered by its own lane.
SIGN_LOG="$REPORT_DIR/markdown-smoke-sign-$TS.log"
set +e
/usr/bin/codesign --force --deep --sign - --timestamp=none "$TMP_APP" >"$SIGN_LOG" 2>&1
SIGN_RC=$?
set -e
if [[ "$SIGN_RC" -ne 0 ]]; then
  fail_assert "could not ad-hoc sign isolated app copy (rc=$SIGN_RC); see $SIGN_LOG"
fi

MLX_BIN="$TMP_APP/Contents/MacOS/MLXStudio"
if [[ ! -x "$MLX_BIN" ]]; then
  if [[ -x "$TMP_APP/Contents/MacOS/MLX Studio" ]]; then
    MLX_BIN="$TMP_APP/Contents/MacOS/MLX Studio"
  else
    fail_assert "app binary missing under $TMP_APP/Contents/MacOS"
  fi
fi

note "launching isolated app ($SMOKE_BUNDLE_ID)"
HOME="$SMOKE_HOME" CFFIXED_USER_HOME="$SMOKE_HOME" "$MLX_BIN" \
  -ApplePersistenceIgnoreState YES \
  -mlxstudio.onboardingComplete YES \
  -mlxstudio.experienceMode beginner \
  -mlxstudio.chat.unifiedSQLiteMigration.v1 YES \
  -mlxstudio.chat.unifiedSelectedSessionID "$SESSION_ID" \
  -mlxstudio.chat.unifiedPreferredSessionID "$SESSION_ID" \
  -mlxstudio.chat.selectedSessionID "$SESSION_ID" \
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
# The AX assertion necessarily exercises the system text pasteboard. Preserve
# its readable text representation so a normal completion or failure restores
# it in cleanup; non-text pasteboard types cannot be represented by pbpaste.
if /usr/bin/pbpaste >"$CLIPBOARD_BACKUP" 2>/dev/null; then
  CLIPBOARD_WAS_READABLE=1
else
  fail_assert "could not read existing text clipboard; refusing to overwrite it"
fi
if ! printf '' | /usr/bin/pbcopy 2>/dev/null; then
  fail_assert "could not clear text clipboard before copy assertion"
fi

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
set +e
PASTEBOARD="$(/usr/bin/pbpaste | tr -d '\r')"
PASTEBOARD_RC=$?
set -e
if [[ "$PASTEBOARD_RC" -ne 0 ]]; then
  fail_assert "could not read text clipboard after copy assertion"
fi
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
