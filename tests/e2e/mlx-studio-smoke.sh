#!/usr/bin/env bash
# Local MLX Studio smoke test.
#
# Builds/packages the app if needed, resets first-run defaults, launches a
# temporary copy, and uses the existing Swift AX driver for best-effort UI
# assertions. Set MLX_STUDIO_REQUIRE_AX=1 to fail when Accessibility assertions
# cannot be read/clicked.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT_DIR="$ROOT_DIR/Tests/e2e/reports"
AX_DIR="$ROOT_DIR/Tests/e2e/swift-axdriver"
AX_BIN="$AX_DIR/.build/release/vmlx-axdriver"
APP_PATH="${MLX_STUDIO_APP_PATH:-/tmp/mlx-studio-beta-dist/MLX Studio.app}"
TMP_APP="/tmp/MLX Studio Smoke.app"
BUNDLE_ID="${BUNDLE_ID:-ai.dealign.mlxstudio.beta}"
REQUIRE_AX="${MLX_STUDIO_REQUIRE_AX:-0}"
TS="$(date +%Y%m%d-%H%M%S)"
SMOKE_CHAT_ACTIVITY_DATE="2026-06-12"
SMOKE_SECOND_SESSION_UPDATED_AT="803000004"
SMOKE_CREATE_ACTION_CREATED_AT="$(date +%s)"
SMOKE_IMAGE_CREATED_AT="$((SMOKE_CREATE_ACTION_CREATED_AT - 1))"
SMOKE_MISSING_IMAGE_CREATED_AT="$((SMOKE_IMAGE_CREATED_AT - 1))"
SMOKE_FAILED_IMAGE_CREATED_AT="$((SMOKE_IMAGE_CREATED_AT - 2))"
SMOKE_ONBOARDING_MODEL_ROOT="/tmp/mlx-studio-onboarding-model-$TS/Smoke-Onboarding-Models"
SMOKE_ONBOARDING_MODEL_DIR="$SMOKE_ONBOARDING_MODEL_ROOT/Smoke-Onboarding-Model"
SMOKE_HF_TOKEN="hf_smoke_onboarding_secret_123456"
SMOKE_HF_TOKEN_KEYCHAIN_SERVICE="ai.jangq.vmlx.hf_token.smoke.$TS"
SMOKE_MODEL_DB="$HOME/Library/Application Support/vMLX/models.sqlite3"
SMOKE_DEFAULT_CHAT_REPO="${MLX_STUDIO_E2E_REPO:-LiquidAI/LFM2.5-350M}"
SMOKE_DEFAULT_CHAT_NAME="${SMOKE_DEFAULT_CHAT_REPO##*/}"
SMOKE_DEFAULT_CHAT_QUERY="${MLX_STUDIO_E2E_QUERY:-$SMOKE_DEFAULT_CHAT_NAME}"
PID=""
export MLX_STUDIO_HF_TOKEN_KEYCHAIN_SERVICE="$SMOKE_HF_TOKEN_KEYCHAIN_SERVICE"

mkdir -p "$REPORT_DIR"
LOG="$REPORT_DIR/mlx-studio-smoke-$TS.log"

note() {
    printf '==> %s\n' "$*" | tee -a "$LOG"
}

warn_or_fail() {
    local message="$1"
    if [[ -n "${PID:-}" ]] && ps -p "$PID" >/dev/null 2>&1; then
        local safe
        safe="$(echo "$message" | tr -c 'A-Za-z0-9' '_' | cut -c1-48)"
        "$AX_BIN" dump "$PID" >"$REPORT_DIR/mlx-studio-smoke-$TS-failure-$safe-axtree.txt" 2>&1 || true
        "$AX_BIN" shot "$PID" "$REPORT_DIR/mlx-studio-smoke-$TS-failure-$safe.png" >>"$LOG" 2>&1 || true
    fi
    if [[ "$REQUIRE_AX" == "1" ]]; then
        note "FAIL: $message"
        exit 1
    fi
    note "WARN: $message"
}

assert_ax_grep() {
    local pid="$1"
    local needle="$2"
    local out="$REPORT_DIR/grep-${TS}-$(echo "$needle" | tr -c 'A-Za-z0-9' '_').txt"
    if "$AX_BIN" grep "$pid" "$needle" >"$out" 2>&1 && grep -qi "$needle" "$out"; then
        note "AX found: $needle"
    else
        warn_or_fail "AX did not find '$needle' (see $out)"
    fi
}

ax_grep_contains() {
    local pid="$1"
    local needle="$2"
    local out="$REPORT_DIR/probe-${TS}-$(echo "$needle" | tr -c 'A-Za-z0-9' '_').txt"
    "$AX_BIN" grep "$pid" "$needle" >"$out" 2>&1 && grep -qi "$needle" "$out"
}

assert_ax_not_grep() {
    local pid="$1"
    local needle="$2"
    local out="$REPORT_DIR/not-grep-${TS}-$(echo "$needle" | tr -c 'A-Za-z0-9' '_').txt"
    if "$AX_BIN" grep "$pid" "$needle" >"$out" 2>&1 && grep -qi "$needle" "$out"; then
        warn_or_fail "AX unexpectedly found '$needle' (see $out)"
    else
        note "AX absent: $needle"
    fi
}

assert_ax_value() {
    local pid="$1"
    local title="$2"
    local expected="$3"
    local out="$REPORT_DIR/value-${TS}-$(echo "$title" | tr -c 'A-Za-z0-9' '_').txt"
    if "$AX_BIN" grep "$pid" "$title" >"$out" 2>&1 && grep -qi "$expected" "$out"; then
        note "AX value for $title: $expected"
    else
        warn_or_fail "AX value for '$title' did not contain '$expected' (see $out)"
    fi
}

click_ax() {
    local pid="$1"
    local title="$2"
    if "$AX_BIN" click "$pid" "$title" >>"$LOG" 2>&1; then
        note "AX clicked: $title"
    else
        warn_or_fail "AX could not click '$title'"
    fi
}

key_ax() {
    local pid="$1"
    local key="$2"
    local modifiers="${3:-}"
    if "$AX_BIN" key "$pid" "$key" "$modifiers" >>"$LOG" 2>&1; then
        note "AX key: ${modifiers:+$modifiers+}$key"
    else
        warn_or_fail "AX could not press '${modifiers:+$modifiers+}$key'"
    fi
}

scroll_ax() {
    local pid="$1"
    local lines="$2"
    if "$AX_BIN" scroll "$pid" "$lines" >>"$LOG" 2>&1; then
        note "AX scroll: $lines"
    else
        warn_or_fail "AX could not scroll '$lines'"
    fi
}

click_ax_expect() {
    local pid="$1"
    local title="$2"
    local expected="$3"
    local timeout="${4:-10}"
    local out="$REPORT_DIR/click-${TS}-$(echo "$title" | tr -c 'A-Za-z0-9' '_').txt"
    if "$AX_BIN" click "$pid" "$title" >"$out" 2>&1; then
        note "AX clicked: $title"
        wait_ax "$pid" "$expected" "$timeout"
    elif "$AX_BIN" wait "$pid" "$expected" "$timeout" >>"$LOG" 2>&1; then
        note "AX clicked: $title"
        note "AX ready: $expected"
    else
        cat "$out" >>"$LOG" 2>/dev/null || true
        warn_or_fail "AX could not click '$title'"
    fi
}

type_ax() {
    local pid="$1"
    local title="$2"
    local text="$3"
    if "$AX_BIN" type "$pid" "$title" "$text" >>"$LOG" 2>&1; then
        note "AX typed into: $title"
    else
        warn_or_fail "AX could not type into '$title'"
    fi
}

wait_ax() {
    local pid="$1"
    local title="$2"
    local timeout="${3:-15}"
    if "$AX_BIN" wait "$pid" "$title" "$timeout" >>"$LOG" 2>&1; then
        note "AX ready: $title"
    else
        warn_or_fail "AX timed out waiting for '$title'"
    fi
}

shot_ax() {
    local pid="$1"
    local label="$2"
    local out="$REPORT_DIR/mlx-studio-smoke-$TS-$label.png"
    "$AX_BIN" shot "$pid" "$out" >>"$LOG" 2>&1 || true
    note "Screenshot: $out"
}

chat_sessions_defaults_json() {
    if defaults export "$BUNDLE_ID" "$CHAT_DEFAULTS_PLIST" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c 'Print :mlxstudio.chat.sessions' "$CHAT_DEFAULTS_PLIST" 2>/dev/null || true
    fi
}

chat_session_field() {
    local session_id="$1"
    local field="$2"
    local raw
    raw="$(chat_sessions_defaults_json)"
    /usr/bin/python3 -c '
import json
import sys

session_id, field = sys.argv[1], sys.argv[2]
try:
    sessions = json.loads(sys.stdin.read() or "[]")
except json.JSONDecodeError:
    sessions = []

for session in sessions:
    if session.get("id") == session_id:
        value = session.get(field, "")
        if isinstance(value, float) and value.is_integer():
            value = int(value)
        print(value)
        break
	' "$session_id" "$field" <<<"$raw"
}

chat_session_turn_count() {
    local session_id="$1"
    local raw
    raw="$(chat_sessions_defaults_json)"
    CHAT_SESSIONS_RAW="$raw" /usr/bin/python3 - "$session_id" <<'PY'
import json
import os
import sys

session_id = sys.argv[1]
try:
    sessions = json.loads(os.environ.get("CHAT_SESSIONS_RAW", "[]") or "[]")
except json.JSONDecodeError:
    sessions = []

for session in sessions:
    if session.get("id") == session_id:
        print(len(session.get("turns") or []))
        break
PY
}

assert_second_session_activity_timestamp() {
    local action="$1"
    local actual
    actual="$(chat_session_field "66666666-6666-6666-6666-666666666666" "updatedAt")"
    if [[ "$actual" == "$SMOKE_SECOND_SESSION_UPDATED_AT" || "$actual" == "$SMOKE_SECOND_SESSION_UPDATED_AT.0" ]]; then
        note "$action preserved latest-session activity timestamp"
    else
        warn_or_fail "$action rewrote latest-session activity timestamp: expected $SMOKE_SECOND_SESSION_UPDATED_AT, got ${actual:-missing}"
    fi
}

cleanup() {
    if [[ -n "${PID:-}" ]]; then
        kill -TERM "$PID" 2>/dev/null || true
    fi
    pkill -x MLXStudio 2>/dev/null || true
    if [[ -n "${SMOKE_IMAGE_DB:-}" && -x /usr/bin/sqlite3 ]]; then
        /usr/bin/sqlite3 "$SMOKE_IMAGE_DB" \
            "DELETE FROM image_generations WHERE id IN ('77777777-7777-7777-7777-777777777777','55555555-5555-5555-5555-555555555555','99999999-9999-9999-9999-999999999999','AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA','BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB');" \
            >/dev/null 2>&1 || true
    fi
    rm -f "${SMOKE_CREATE_ACTION_PNG:-}" "${SMOKE_CREATE_ACTION_PNG:-}.metadata.json" 2>/dev/null || true
    rm -f "${SMOKE_IMAGE_PNG:-}" "${SMOKE_IMAGE_PNG:-}.metadata.json" 2>/dev/null || true
    rm -f "${SMOKE_KNOWN_IMAGE_PNG:-}" "${SMOKE_KNOWN_IMAGE_PNG:-}.metadata.json" 2>/dev/null || true
    rm -f "${SMOKE_MISSING_IMAGE_PATH:-}" "${SMOKE_MISSING_IMAGE_PATH:-}.metadata.json" 2>/dev/null || true
    rm -f "${SMOKE_SUMMARY_PATH:-}" "${SMOKE_STALE_SUMMARY_PATH:-}" 2>/dev/null || true
    if [[ -n "${SMOKE_ONBOARDING_MODEL_ROOT:-}" ]]; then
        rm -rf "$(dirname "$SMOKE_ONBOARDING_MODEL_ROOT")" 2>/dev/null || true
    fi
    rm -rf "${SMOKE_MODEL_FIXTURE_DIR:-}" 2>/dev/null || true
    rm -rf "${SMOKE_SWITCH_MODEL_FIXTURE_DIR:-}" 2>/dev/null || true
    rm -rf "${SMOKE_DELETE_MODEL_FIXTURE_DIR:-}" 2>/dev/null || true
    if [[ -n "${SMOKE_MODEL_DB:-}" && -x /usr/bin/sqlite3 ]]; then
        /usr/bin/sqlite3 "$SMOKE_MODEL_DB" \
            "DELETE FROM models WHERE canonical_path LIKE '%Smoke-Onboarding%' OR canonical_path IN ('${SMOKE_MODEL_FIXTURE_DIR:-}','${SMOKE_SWITCH_MODEL_FIXTURE_DIR:-}','${SMOKE_DELETE_MODEL_FIXTURE_DIR:-}');" \
            >/dev/null 2>&1 || true
        /usr/bin/sqlite3 "$SMOKE_MODEL_DB" \
            "DELETE FROM user_dirs WHERE url LIKE '%Smoke-Onboarding%';" \
            >/dev/null 2>&1 || true
    fi
    if [[ -n "${SMOKE_HF_TOKEN_KEYCHAIN_SERVICE:-}" ]]; then
        /usr/bin/security delete-generic-password \
            -s "$SMOKE_HF_TOKEN_KEYCHAIN_SERVICE" \
            -a default >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

reset_first_run_defaults() {
    defaults delete "$BUNDLE_ID" mlxstudio.onboardingComplete 2>/dev/null || true
    defaults delete "$BUNDLE_ID" mlxstudio.experienceMode 2>/dev/null || true
    defaults delete "$BUNDLE_ID" mlxstudio.chat.sessions 2>/dev/null || true
    defaults delete "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true
}

stage_tmp_app() {
    pkill -x MLXStudio 2>/dev/null || true
    rm -rf "$TMP_APP"
    /usr/bin/ditto --noextattr "$APP_PATH" "$TMP_APP"
    xattr -cr "$TMP_APP" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$TMP_APP" 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$TMP_APP" 2>/dev/null || true
    MLX_BIN="$TMP_APP/Contents/MacOS/MLXStudio"
    "$MLX_BIN" -ApplePersistenceIgnoreState YES >>"$LOG" 2>&1 &
    PID="$!"
}

stop_smoke_app() {
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    sleep 1
    pkill -x MLXStudio 2>/dev/null || true
    PID=""
}

verify_onboarding_chat_route() {
    local route_name="$1"
    local selected_marker="$2"
    local landing_title="$3"
    local status_text="$4"
    local prompt_text="$5"
    local screenshot_label="$6"

    note "Verifying onboarding $route_name route handoff"
    reset_first_run_defaults
    stage_tmp_app
    wait_ax "$PID" "Next" 20
    click_ax "$PID" "Next"
    wait_ax "$PID" "Beginner" 10
    click_ax "$PID" "Next"
    wait_ax "$PID" "Pick your first result" 10
    click_ax "$PID" "Onboarding $route_name route"
    wait_ax "$PID" "$selected_marker" 10
    wait_ax "$PID" "Finish opens Chat" 10
    click_ax "$PID" "Finish"
    wait_ax "$PID" "$landing_title" 15
    assert_ax_grep "$PID" "$status_text"
    assert_ax_value "$PID" "Chat composer" "$prompt_text"
    shot_ax "$PID" "$screenshot_label"
    note "Onboarding $route_name route landed in Chat with prepared prompt"
    stop_smoke_app
}

prepare_onboarding_model_fixture() {
    rm -rf "$(dirname "$SMOKE_ONBOARDING_MODEL_ROOT")"
    mkdir -p "$SMOKE_ONBOARDING_MODEL_DIR"
    printf '%s\n' '{"architectures":["SmokeForCausalLM"],"model_type":"qwen2","_name_or_path":"Smoke-Onboarding-Model"}' >"$SMOKE_ONBOARDING_MODEL_DIR/config.json"
    printf '%s\n' '{"version":"smoke"}' >"$SMOKE_ONBOARDING_MODEL_DIR/tokenizer.json"
    /usr/bin/truncate -s 9437184 "$SMOKE_ONBOARDING_MODEL_DIR/model.safetensors"
    export MLX_STUDIO_ONBOARDING_MODEL_DIR="$SMOKE_ONBOARDING_MODEL_ROOT"
}

verify_onboarding_local_folder_scan() {
    note "Verifying onboarding local folder scan"
    prepare_onboarding_model_fixture
    reset_first_run_defaults
    stage_tmp_app
    wait_ax "$PID" "Next" 20
    click_ax "$PID" "Next"
    wait_ax "$PID" "Beginner" 10
    click_ax "$PID" "Next"
    wait_ax "$PID" "Pick your first result" 10
    click_ax "$PID" "Scan local model folder"
    wait_ax "$PID" "Scanned local model folder: Smoke-Onboarding-Models" 20
    assert_ax_grep "$PID" "Local folder"
    assert_ax_grep "$PID" "Folder selected"
    assert_ax_grep "$PID" "MLX Studio will scan Smoke-Onboarding-Models"
    assert_ax_grep "$PID" "Scanned local model folder: Smoke-Onboarding-Models"
    click_ax "$PID" "Finish"
    wait_ax "$PID" "First local chat" 15
    click_ax "$PID" "Models"
    wait_ax "$PID" "Ready Now" 15
    click_ax "$PID" "Refresh"
    wait_ax "$PID" "Smoke-Onboarding-Model" 20
    assert_ax_grep "$PID" "Smoke-Onboarding-Model"
    assert_ax_grep "$PID" "Chat route"
    click_ax "$PID" "Select model Smoke-Onboarding-Model"
    wait_ax "$PID" "Smoke-Onboarding-Model is selected" 10
    shot_ax "$PID" "onboarding-local-folder-models"
    note "Onboarding local folder scan surfaced Smoke-Onboarding-Model in Models"
    stop_smoke_app
    if [[ -x /usr/bin/sqlite3 ]]; then
        /usr/bin/sqlite3 "$SMOKE_MODEL_DB" \
            "DELETE FROM models WHERE canonical_path LIKE '%Smoke-Onboarding%';" \
            >/dev/null 2>&1 || true
        /usr/bin/sqlite3 "$SMOKE_MODEL_DB" \
            "DELETE FROM user_dirs WHERE url LIKE '%Smoke-Onboarding%';" \
            >/dev/null 2>&1 || true
    fi
    rm -rf "$(dirname "$SMOKE_ONBOARDING_MODEL_ROOT")"
}

verify_onboarding_hf_token_handoff() {
    note "Verifying onboarding Hugging Face token handoff"
    /usr/bin/security delete-generic-password \
        -s "$SMOKE_HF_TOKEN_KEYCHAIN_SERVICE" \
        -a default >/dev/null 2>&1 || true
    reset_first_run_defaults
    stage_tmp_app
    wait_ax "$PID" "Next" 20
    click_ax "$PID" "Next"
    wait_ax "$PID" "Beginner" 10
    click_ax "$PID" "Next"
    wait_ax "$PID" "Pick your first result" 10
    type_ax "$PID" "Onboarding Hugging Face token" "$SMOKE_HF_TOKEN"
    assert_ax_grep "$PID" "MLX Studio will save the token in Keychain"
    assert_ax_not_grep "$PID" "$SMOKE_HF_TOKEN"
    click_ax "$PID" "Finish"
    wait_ax "$PID" "First local chat" 15
    stop_smoke_app
    note "Relaunching after onboarding HF token save"
    stage_tmp_app
    wait_ax "$PID" "Chat" 20
    click_ax "$PID" "Models"
    wait_ax "$PID" "Ready Now" 15
    wait_ax "$PID" "Token rejected" 30
    assert_ax_grep "$PID" "HF auth"
    assert_ax_grep "$PID" "Token rejected"
    assert_ax_grep "$PID" "Public Hub models still work"
    assert_ax_grep "$PID" "Gated repos need a valid token before download"
    assert_ax_not_grep "$PID" "$SMOKE_HF_TOKEN"
    shot_ax "$PID" "onboarding-hf-token-models"
    stop_smoke_app
    /usr/bin/security delete-generic-password \
        -s "$SMOKE_HF_TOKEN_KEYCHAIN_SERVICE" \
        -a default >/dev/null 2>&1 || true
    note "Onboarding HF token handoff surfaced Models gated-repo state"
}

verify_onboarding_advanced_route() {
    note "Verifying onboarding Advanced route handoff"
    reset_first_run_defaults
    stage_tmp_app
    wait_ax "$PID" "Next" 20
    click_ax "$PID" "Next"
    wait_ax "$PID" "Beginner" 10
    assert_ax_grep "$PID" "Full control"
    assert_ax_grep "$PID" "Onboarding Advanced mode"
    click_ax "$PID" "Onboarding Advanced mode"
    click_ax "$PID" "Next"
    wait_ax "$PID" "Advanced Setup" 10
    assert_ax_grep "$PID" "Open Server after setup"
    assert_ax_grep "$PID" "Finish opens Server"
    assert_ax_grep "$PID" "manual Start/Stop controls"
    assert_ax_grep "$PID" "API stays off until started"
    assert_ax_not_grep "$PID" "Server starts after a model is selected"
    click_ax "$PID" "Finish"
    wait_ax "$PID" "Control Plane" 15
    shot_ax "$PID" "onboarding-advanced-route-server"
    assert_ax_grep "$PID" "Server"
    assert_ax_grep "$PID" "Start Server"
    assert_ax_grep "$PID" "Copy Endpoint"
    stop_smoke_app
    note "Onboarding Advanced route landed in Server without promising auto-start"
}

if [[ ! -d "$APP_PATH" ]]; then
    note "Packaging MLX Studio app"
    (cd "$ROOT_DIR" && CONFIGURATION="${CONFIGURATION:-release}" scripts/package-mlx-studio-app.sh) | tee -a "$LOG"
fi

if [[ ! -x "$AX_BIN" || "$AX_DIR/Sources/main.swift" -nt "$AX_BIN" ]]; then
    note "Building Swift AX driver"
    (cd "$AX_DIR" && swift build -c release) | tee -a "$LOG"
fi

verify_onboarding_chat_route \
    "Chat" \
    "Prompt ready" \
    "First local chat" \
    "Prepared first local chat prompt" \
    "first local AI reply" \
    "onboarding-chat-route-chat"
verify_onboarding_chat_route \
    "Coding" \
    "Coding prompt" \
    "Local coding chat" \
    "Prepared local coding prompt" \
    "Help me review a code change" \
    "onboarding-coding-route-chat"
verify_onboarding_chat_route \
    "Research" \
    "Research prompt" \
    "Research brief" \
    "Prepared research brief prompt" \
    "research question into a local brief" \
    "onboarding-research-route-chat"
verify_onboarding_local_folder_scan
verify_onboarding_hf_token_handoff
verify_onboarding_advanced_route

note "Resetting first-run defaults for $BUNDLE_ID"
reset_first_run_defaults
defaults delete "$BUNDLE_ID" mlxstudio.diagnostics.issues 2>/dev/null || true

APP_SUPPORT_DIR="$HOME/Library/Application Support/vMLX"
SMOKE_STALE_SUMMARY_PATH="$APP_SUPPORT_DIR/chat-summaries/Smoke chat session-summary-11111111.md"
SMOKE_SESSION_JSON="$(SMOKE_STALE_SUMMARY_PATH="$SMOKE_STALE_SUMMARY_PATH" /usr/bin/python3 - <<'PY'
import json
import os

print(json.dumps([
    {
        "id": "11111111-1111-1111-1111-111111111111",
        "title": "Smoke chat session",
        "modelName": "Smoke Model",
        "turns": [
            {
                "id": "22222222-2222-2222-2222-222222222222",
                "role": "user",
                "content": "Smoke prompt",
                "createdAt": 803000000,
                "streamState": "complete",
            },
            {
                "id": "33333333-3333-3333-3333-333333333333",
                "role": "assistant",
                "content": "Smoke response",
                "createdAt": 803000001,
                "streamState": "failed",
            },
        ],
        "createdAt": 803000000,
        "updatedAt": 803000001,
        "isPinned": True,
        "summaryExportPath": os.environ["SMOKE_STALE_SUMMARY_PATH"],
        "summaryExportedAt": 803000001,
    },
    {
        "id": "66666666-6666-6666-6666-666666666666",
        "title": "Second smoke session",
        "modelName": "Smoke Model B",
        "turns": [
            {
                "id": "77777777-7777-7777-7777-777777777777",
                "role": "user",
                "content": "Second smoke prompt",
                "createdAt": 803000003,
                "streamState": "complete",
            },
            {
                "id": "88888888-8888-8888-8888-888888888888",
                "role": "assistant",
                "content": "Second smoke response",
                "createdAt": 803000004,
                "streamState": "complete",
            },
        ],
        "createdAt": 803000003,
        "updatedAt": 803000004,
        "isPinned": False,
    },
], separators=(",", ":")))
PY
)"
SMOKE_SESSION_HEX="$(printf '%s' "$SMOKE_SESSION_JSON" | /usr/bin/xxd -p -c 256 | tr -d '\n')"
defaults write "$BUNDLE_ID" mlxstudio.chat.sessions -data "$SMOKE_SESSION_HEX"
defaults write "$BUNDLE_ID" mlxstudio.chat.selectedSessionID "66666666-6666-6666-6666-666666666666"
SMOKE_NOW_REFERENCE="$(/usr/bin/python3 - <<'PY'
import time

print(f"{time.time() - 978307200:.3f}")
PY
)"
SMOKE_OLD_ISSUE_REFERENCE="$(/usr/bin/python3 - <<'PY'
import time

print(f"{time.time() - 978307200 - 3600:.3f}")
PY
)"
SMOKE_ISSUE_JSON="$(printf '[{"id":"44444444-4444-4444-4444-444444444444","source":"chat stream","severity":"error","title":"Smoke diagnostic issue","message":"Smoke stream failed for diagnostics token=hf_smokesecret123456","context":"Smoke Model at /Users/hermes/private/model Authorization: Bearer smoke-secret-123456","createdAt":%s},{"id":"55555555-5555-5555-5555-555555555555","source":"server","severity":"warning","title":"Old server binding issue","message":"Server could not bind token=hf_oldserversecret123456","context":"Server at http://127.0.0.1:8000 api_key=old-server-secret-123456","createdAt":%s}]' "$SMOKE_NOW_REFERENCE" "$SMOKE_OLD_ISSUE_REFERENCE")"
SMOKE_ISSUE_HEX="$(printf '%s' "$SMOKE_ISSUE_JSON" | /usr/bin/xxd -p -c 256 | tr -d '\n')"
defaults write "$BUNDLE_ID" mlxstudio.diagnostics.issues -data "$SMOKE_ISSUE_HEX"

SMOKE_IMAGE_DB="$APP_SUPPORT_DIR/image_history.sqlite3"
SMOKE_MODEL_DB="$APP_SUPPORT_DIR/models.sqlite3"
SMOKE_MODEL_ROOT="$HOME/.mlxstudio/models"
SMOKE_MODEL_FIXTURE_DIR="$SMOKE_MODEL_ROOT/Smoke-Library-Model"
SMOKE_SWITCH_MODEL_FIXTURE_DIR="$SMOKE_MODEL_ROOT/Smoke-Switch-Model"
SMOKE_DELETE_MODEL_FIXTURE_DIR="$SMOKE_MODEL_ROOT/Smoke-Delete-Model"
SMOKE_CREATE_ACTION_PNG="$REPORT_DIR/mlx-studio-smoke-$TS-create-action-image.png"
SMOKE_CREATE_REVEAL_LOG="$REPORT_DIR/mlx-studio-smoke-$TS-create-reveal.log"
SMOKE_LIBRARY_OPEN_LOG="$REPORT_DIR/mlx-studio-smoke-$TS-library-open.log"
SMOKE_LIBRARY_REVEAL_LOG="$REPORT_DIR/mlx-studio-smoke-$TS-library-reveal.log"
SMOKE_IMAGE_PNG="$REPORT_DIR/mlx-studio-smoke-$TS-image.png"
SMOKE_KNOWN_IMAGE_PNG="$REPORT_DIR/mlx-studio-smoke-$TS-known-catalog-image.png"
SMOKE_MISSING_IMAGE_PATH="$REPORT_DIR/mlx-studio-smoke-$TS-missing-image.png"
SMOKE_SUMMARY_PATH="$APP_SUPPORT_DIR/chat-summaries/Second smoke session-summary-66666666.md"
SMOKE_EXPORT_DIR="$REPORT_DIR/chat-exports-$TS"
SMOKE_IMAGE_METADATA_EXPORT_DIR="$REPORT_DIR/image-metadata-exports-$TS"
SMOKE_MODEL_REPORT_EXPORT_DIR="$REPORT_DIR/model-reports-$TS"
SMOKE_CHAT_RETRY_DRAFT_LOG="$REPORT_DIR/mlx-studio-smoke-$TS-chat-retry-draft.log"
CHAT_DEFAULTS_PLIST="$REPORT_DIR/chat-defaults-$TS.plist"
mkdir -p "$APP_SUPPORT_DIR" "$SMOKE_EXPORT_DIR" "$SMOKE_IMAGE_METADATA_EXPORT_DIR" "$SMOKE_MODEL_REPORT_EXPORT_DIR"
mkdir -p "$(dirname "$SMOKE_STALE_SUMMARY_PATH")"
printf '# Smoke chat session Summary\n\nStale summary before model switch.\n' >"$SMOKE_STALE_SUMMARY_PATH"
rm -f "$SMOKE_SUMMARY_PATH"
export MLX_STUDIO_CHAT_EXPORT_DIR="$SMOKE_EXPORT_DIR"
export MLX_STUDIO_IMAGE_METADATA_EXPORT_DIR="$SMOKE_IMAGE_METADATA_EXPORT_DIR"
export MLX_STUDIO_MODEL_REPORT_EXPORT_DIR="$SMOKE_MODEL_REPORT_EXPORT_DIR"
export MLX_STUDIO_CREATE_REVEAL_LOG="$SMOKE_CREATE_REVEAL_LOG"
export MLX_STUDIO_LIBRARY_OPEN_LOG="$SMOKE_LIBRARY_OPEN_LOG"
export MLX_STUDIO_LIBRARY_REVEAL_LOG="$SMOKE_LIBRARY_REVEAL_LOG"
export MLX_STUDIO_CHAT_RETRY_DRAFT_LOG="$SMOKE_CHAT_RETRY_DRAFT_LOG"
rm -rf "$SMOKE_MODEL_FIXTURE_DIR"
rm -rf "$SMOKE_SWITCH_MODEL_FIXTURE_DIR"
rm -rf "$SMOKE_DELETE_MODEL_FIXTURE_DIR"
mkdir -p "$SMOKE_MODEL_FIXTURE_DIR"
mkdir -p "$SMOKE_SWITCH_MODEL_FIXTURE_DIR"
mkdir -p "$SMOKE_DELETE_MODEL_FIXTURE_DIR"
printf '%s\n' '{"architectures":["SmokeForCausalLM"],"model_type":"qwen2","_name_or_path":"Smoke-Library-Model"}' >"$SMOKE_MODEL_FIXTURE_DIR/config.json"
printf '%s\n' '{"version":"smoke"}' >"$SMOKE_MODEL_FIXTURE_DIR/tokenizer.json"
/usr/bin/truncate -s 9437184 "$SMOKE_MODEL_FIXTURE_DIR/model.safetensors"
printf '%s\n' '{"architectures":["SmokeForCausalLM"],"model_type":"qwen2","_name_or_path":"Smoke-Switch-Model"}' >"$SMOKE_SWITCH_MODEL_FIXTURE_DIR/config.json"
printf '%s\n' '{"version":"smoke"}' >"$SMOKE_SWITCH_MODEL_FIXTURE_DIR/tokenizer.json"
/usr/bin/truncate -s 8388608 "$SMOKE_SWITCH_MODEL_FIXTURE_DIR/model.safetensors"
printf '%s\n' '{"architectures":["SmokeForCausalLM"],"model_type":"qwen2","_name_or_path":"Smoke-Delete-Model"}' >"$SMOKE_DELETE_MODEL_FIXTURE_DIR/config.json"
printf '%s\n' '{"version":"smoke"}' >"$SMOKE_DELETE_MODEL_FIXTURE_DIR/tokenizer.json"
/usr/bin/truncate -s 10485760 "$SMOKE_DELETE_MODEL_FIXTURE_DIR/model.safetensors"
/usr/bin/base64 -D >"$SMOKE_IMAGE_PNG" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAMAAADXqc3KAAAAFVBMVEUOEBYZHicsNERoitLJnv9c1Inws1r9rTlKAAAAlElEQVR42m2RURLFIAgDgzjc/8gFhBL7Hl+adZh0i73FZ+WIzBk7yUJMAZxLkn8gyQ/QuDj5Ak0QhICZqYOssKebmYjngrNkujmIvMF0yz0y4O1W+YDuVjmB061zAflxErnlXBqCkJIBSt4uP6rj7fKj5G1A9Wlv6H8XOXvr78j37K3A2cPesCYX9gb2w96wyA97ewAbigNzULQ9IAAAAABJRU5ErkJggg==
PNG
cp "$SMOKE_IMAGE_PNG" "$SMOKE_CREATE_ACTION_PNG"
cp "$SMOKE_IMAGE_PNG" "$SMOKE_KNOWN_IMAGE_PNG"
/usr/bin/python3 - "$SMOKE_IMAGE_PNG" "$SMOKE_CREATE_ACTION_PNG" "$SMOKE_KNOWN_IMAGE_PNG" <<'PY'
import json
import sys

ready_path, action_path, known_path = sys.argv[1], sys.argv[2], sys.argv[3]
settings = {
    "steps": 4,
    "guidance": 3.5,
    "width": 128,
    "height": 128,
    "seed": 7,
    "numImages": 1,
    "scheduler": "default",
    "strength": 0.75,
}
records = [
    (
        f"{ready_path}.metadata.json",
        "55555555-5555-5555-5555-555555555555",
        "Smoke Image Model",
        "Smoke image prompt",
        ready_path,
        settings,
    ),
    (
        f"{action_path}.metadata.json",
        "77777777-7777-7777-7777-777777777777",
        "Create Action Image Model",
        "Create action prompt",
        action_path,
        {**settings, "seed": 17},
    ),
    (
        f"{known_path}.metadata.json",
        "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
        "FLUX.1 Schnell",
        "Known catalog prompt",
        known_path,
        {**settings, "width": 256, "height": 256, "seed": 31},
    ),
]
for sidecar_path, ident, model, prompt, output_path, sidecar_settings in records:
    payload = {
        "schemaVersion": 1,
        "id": ident,
        "modelAlias": model,
        "prompt": prompt,
        "sourceImagePath": None,
        "maskPath": None,
        "settings": sidecar_settings,
        "settingsJSON": json.dumps(sidecar_settings, separators=(",", ":")),
        "outputPath": output_path,
        "createdAt": "2026-06-30T00:00:00Z",
        "durationMs": 1200,
        "status": "completed",
        "runtimeName": None,
        "modelPath": None,
        "runtimeProofPath": None,
        "runtimeProof": None,
    }
    with open(sidecar_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
PY
/usr/bin/sqlite3 "$SMOKE_IMAGE_DB" >/dev/null <<SQL
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS image_generations (
    id TEXT PRIMARY KEY,
    model_alias TEXT NOT NULL,
    prompt TEXT NOT NULL,
    source_image_path TEXT,
    mask_path TEXT,
    settings_json TEXT NOT NULL,
    output_path TEXT,
    created_at REAL NOT NULL,
    duration_ms INTEGER,
    status TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_image_gen_created ON image_generations(created_at DESC);
INSERT INTO image_generations (
    id, model_alias, prompt, source_image_path, mask_path,
    settings_json, output_path, created_at, duration_ms, status
) VALUES (
    '77777777-7777-7777-7777-777777777777',
    'Create Action Image Model',
    'Create action prompt',
    NULL,
    NULL,
    '{"steps":4,"guidance":3.5,"width":128,"height":128,"seed":17,"numImages":1,"scheduler":"default","strength":0.75}',
    '$SMOKE_CREATE_ACTION_PNG',
    $SMOKE_CREATE_ACTION_CREATED_AT,
    800,
    'completed'
) ON CONFLICT(id) DO UPDATE SET
    prompt=excluded.prompt,
    output_path=excluded.output_path,
    created_at=excluded.created_at,
    duration_ms=excluded.duration_ms,
    status=excluded.status,
    settings_json=excluded.settings_json;
	INSERT INTO image_generations (
	    id, model_alias, prompt, source_image_path, mask_path,
	    settings_json, output_path, created_at, duration_ms, status
) VALUES (
    '55555555-5555-5555-5555-555555555555',
    'Smoke Image Model',
    'Smoke image prompt',
    NULL,
    NULL,
    '{"steps":4,"guidance":3.5,"width":128,"height":128,"seed":7,"numImages":1,"scheduler":"default","strength":0.75}',
    '$SMOKE_IMAGE_PNG',
    $SMOKE_IMAGE_CREATED_AT,
    1200,
    'completed'
) ON CONFLICT(id) DO UPDATE SET
    prompt=excluded.prompt,
    output_path=excluded.output_path,
    duration_ms=excluded.duration_ms,
    status=excluded.status,
    settings_json=excluded.settings_json;
	INSERT INTO image_generations (
	    id, model_alias, prompt, source_image_path, mask_path,
	    settings_json, output_path, created_at, duration_ms, status
	) VALUES (
	    'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
	    'FLUX.1 Schnell',
	    'Known catalog prompt',
	    NULL,
	    NULL,
	    '{"steps":4,"guidance":3.5,"width":256,"height":256,"seed":31,"numImages":1,"scheduler":"default","strength":0.75}',
	    '$SMOKE_KNOWN_IMAGE_PNG',
	    $((SMOKE_IMAGE_CREATED_AT - 1)),
	    1100,
	    'completed'
	) ON CONFLICT(id) DO UPDATE SET
	    prompt=excluded.prompt,
	    output_path=excluded.output_path,
	    created_at=excluded.created_at,
	    duration_ms=excluded.duration_ms,
	    status=excluded.status,
	    settings_json=excluded.settings_json;
	INSERT INTO image_generations (
	    id, model_alias, prompt, source_image_path, mask_path,
	    settings_json, output_path, created_at, duration_ms, status
	) VALUES (
	    '99999999-9999-9999-9999-999999999999',
    'Missing Image Model',
    'Missing image prompt',
    NULL,
    NULL,
    '{"steps":2,"guidance":2.5,"width":128,"height":128,"seed":13,"numImages":1,"scheduler":"default","strength":0.75}',
    '$SMOKE_MISSING_IMAGE_PATH',
    $SMOKE_MISSING_IMAGE_CREATED_AT,
    900,
    'completed'
) ON CONFLICT(id) DO UPDATE SET
    prompt=excluded.prompt,
    output_path=excluded.output_path,
    created_at=excluded.created_at,
    duration_ms=excluded.duration_ms,
    status=excluded.status,
    settings_json=excluded.settings_json;
INSERT INTO image_generations (
    id, model_alias, prompt, source_image_path, mask_path,
    settings_json, output_path, created_at, duration_ms, status
) VALUES (
    'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
    'Failed Image Model',
    'Failed image prompt',
    NULL,
    NULL,
    '{"steps":3,"guidance":1.5,"width":128,"height":128,"seed":21,"numImages":1,"scheduler":"default","strength":0.75}',
    NULL,
    $SMOKE_FAILED_IMAGE_CREATED_AT,
    300,
    'failed'
) ON CONFLICT(id) DO UPDATE SET
    prompt=excluded.prompt,
    output_path=excluded.output_path,
    created_at=excluded.created_at,
    duration_ms=excluded.duration_ms,
    status=excluded.status,
    settings_json=excluded.settings_json;
SQL

note "Launching temporary app copy"
pkill -x MLXStudio 2>/dev/null || true
rm -rf "$TMP_APP"
/usr/bin/ditto --noextattr "$APP_PATH" "$TMP_APP"
xattr -cr "$TMP_APP" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$TMP_APP" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$TMP_APP" 2>/dev/null || true
if codesign --verify --deep --strict --verbose=2 "$TMP_APP" >>"$LOG" 2>&1; then
    note "Temporary app signature verified"
else
    warn_or_fail "Temporary app signature verification failed"
fi
MLX_BIN="$TMP_APP/Contents/MacOS/MLXStudio"
"$MLX_BIN" -ApplePersistenceIgnoreState YES >>"$LOG" 2>&1 &
PID="$!"

for _ in {1..60}; do
    if ps -p "$PID" >/dev/null; then
        break
    fi
    sleep 0.5
done

if [[ -z "$PID" ]] || ! ps -p "$PID" >/dev/null; then
    note "FAIL: MLXStudio process did not launch"
    exit 1
fi
note "Launched MLXStudio pid=$PID"
sleep 2

if ! ps -p "$PID" >/dev/null; then
    note "FAIL: MLXStudio exited during startup"
    exit 1
fi

AX_DUMP="$REPORT_DIR/mlx-studio-axtree-$TS.txt"
"$AX_BIN" dump "$PID" >"$AX_DUMP" 2>&1 || true
note "AX dump: $AX_DUMP"

wait_ax "$PID" "Next" 20
shot_ax "$PID" "onboarding-1"
assert_ax_grep "$PID" "Local AI, ready to make something"
click_ax "$PID" "Next"
wait_ax "$PID" "Beginner" 10
shot_ax "$PID" "onboarding-2"
assert_ax_grep "$PID" "Beginner"
assert_ax_grep "$PID" "Chat, Create, Models, Library"
assert_ax_grep "$PID" "Server, Diagnostics, Model lab"
assert_ax_grep "$PID" "Recommended first"
assert_ax_grep "$PID" "Full control"
click_ax "$PID" "Next"
wait_ax "$PID" "Pick your first result" 10
shot_ax "$PID" "onboarding-3"
assert_ax_grep "$PID" "First result path"
assert_ax_grep "$PID" "Goal routes"
assert_ax_grep "$PID" "Onboarding Chat route"
assert_ax_grep "$PID" "Onboarding Coding route"
assert_ax_grep "$PID" "Onboarding Images route"
assert_ax_grep "$PID" "Onboarding Research route"
assert_ax_grep "$PID" "Ready handoff"
assert_ax_grep "$PID" "Finish lands in Chat"
assert_ax_grep "$PID" "Prompt ready"
assert_ax_grep "$PID" "Starter available"
assert_ax_grep "$PID" "Recommended starter"
assert_ax_grep "$PID" "Already have models?"
assert_ax_grep "$PID" "No folder or token selected"
click_ax "$PID" "Onboarding Coding route"
wait_ax "$PID" "Coding prompt" 10
assert_ax_grep "$PID" "Coding prompt"
click_ax "$PID" "Onboarding Research route"
wait_ax "$PID" "Research prompt" 10
assert_ax_grep "$PID" "Research prompt"
click_ax "$PID" "Onboarding Images route"
wait_ax "$PID" "Finish opens Create" 10
assert_ax_grep "$PID" "Finish lands in Create"
assert_ax_grep "$PID" "Canvas ready"
assert_ax_grep "$PID" "Proof check"
assert_ax_grep "$PID" "Proof-gated canvas"
click_ax "$PID" "Finish"
wait_ax "$PID" "Canvas stage" 15
shot_ax "$PID" "onboarding-images-route-create"
assert_ax_grep "$PID" "Create"
assert_ax_grep "$PID" "Output canvas"
click_ax "$PID" "Chat"
wait_ax "$PID" "Conversation runway" 15
shot_ax "$PID" "beginner-chat"

assert_ax_grep "$PID" "Chat"
assert_ax_grep "$PID" "Create"
assert_ax_grep "$PID" "Models"
assert_ax_grep "$PID" "Library"
assert_ax_grep "$PID" "Second smoke session"
assert_ax_grep "$PID" "Second smoke response"
assert_ax_not_grep "$PID" "AITRADER/FLUX1-schnell-mlx-4bit"
assert_ax_grep "$PID" "Conversation runway"
assert_ax_grep "$PID" "Model readiness"
assert_ax_grep "$PID" "Follow-up prompts"
assert_ax_grep "$PID" "Transcript"
assert_ax_grep "$PID" "Session trail"
assert_ax_grep "$PID" "Prepared in composer"
assert_ax_grep "$PID" "Session context"
assert_ax_grep "$PID" "Session brief"
assert_ax_grep "$PID" "Purpose"
assert_ax_grep "$PID" "Handoff ready"
assert_ax_grep "$PID" "Last prompt"
assert_ax_grep "$PID" "Next move"
assert_ax_grep "$PID" "Keep moving"
assert_ax_grep "$PID" "Make practical"
assert_ax_grep "$PID" "Find risk"
assert_ax_grep "$PID" "Branch idea"
assert_ax_grep "$PID" "Save summary"
click_ax "$PID" "Pin"
wait_ax "$PID" "Pinned in Library" 10
wait_ax "$PID" "Unpin" 10
shot_ax "$PID" "chat-session-pinned-brief"
SELECTED_SESSION_AFTER_ACTIVE_PIN="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ "$SELECTED_SESSION_AFTER_ACTIVE_PIN" == "66666666-6666-6666-6666-666666666666" ]]; then
    note "Pinning active chat preserved selected session"
else
    warn_or_fail "Pinning active chat changed selected session"
fi
assert_second_session_activity_timestamp "Pinning active chat"
click_ax "$PID" "Unpin"
wait_ax "$PID" "Saved in Library" 10
wait_ax "$PID" "Pin" 10
shot_ax "$PID" "chat-session-unpinned-brief"
SELECTED_SESSION_AFTER_ACTIVE_UNPIN="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ "$SELECTED_SESSION_AFTER_ACTIVE_UNPIN" == "66666666-6666-6666-6666-666666666666" ]]; then
    note "Unpinning active chat preserved selected session"
else
    warn_or_fail "Unpinning active chat changed selected session"
fi
assert_second_session_activity_timestamp "Unpinning active chat"
click_ax "$PID" "Copy prompt"
COPIED_PROMPT="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_PROMPT" == "Second smoke prompt" ]]; then
    note "Copied prompt to clipboard"
else
    warn_or_fail "Copy prompt wrote unexpected clipboard text"
fi
click_ax "$PID" "Copy response"
COPIED_RESPONSE="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_RESPONSE" == "Second smoke response" ]]; then
    note "Copied response to clipboard"
else
    warn_or_fail "Copy response wrote unexpected clipboard text"
fi
click_ax "$PID" "Prompt starter Branch idea"
assert_ax_value "$PID" "Chat composer" "Explore a different approach without losing the current thread."
click_ax "$PID" "Prompt starter Continue answer"
assert_ax_value "$PID" "Chat composer" "Continue from the last useful point, keeping the answer concise."
click_ax "$PID" "Prompt starter Summarize decisions"
assert_ax_value "$PID" "Chat composer" "Summarize this session into decisions, open questions, and next actions."
click_ax "$PID" "Session quick prompt Make practical"
assert_ax_value "$PID" "Chat composer" "Turn the last answer into concrete next steps with tradeoffs."
click_ax "$PID" "Session quick prompt Continue"
assert_ax_value "$PID" "Chat composer" "Continue from the last useful point, keeping the answer concise."
click_ax "$PID" "Session quick prompt Summarize"
assert_ax_value "$PID" "Chat composer" "Summarize this session into decisions, open questions, and next actions."
click_ax "$PID" "Keep moving Make practical"
assert_ax_grep "$PID" "Turn the last answer into concrete next steps with tradeoffs."
assert_ax_value "$PID" "Chat composer" "Turn the last answer into concrete next steps with tradeoffs."
click_ax "$PID" "Keep moving Find risk"
assert_ax_grep "$PID" "Point out the hidden assumptions, failure modes, and missing evidence."
assert_ax_value "$PID" "Chat composer" "Point out the hidden assumptions, failure modes, and missing evidence."
click_ax "$PID" "Keep moving Branch idea"
assert_ax_value "$PID" "Chat composer" "Explore a different approach without losing the current thread."
shot_ax "$PID" "chat-composer-starters"
click_ax "$PID" "Keep moving Save summary"
for _ in {1..25}; do
    [[ -f "$SMOKE_SUMMARY_PATH" ]] && break
    sleep 0.2
done
if [[ -f "$SMOKE_SUMMARY_PATH" ]] \
    && grep -q "# Second smoke session Summary" "$SMOKE_SUMMARY_PATH" \
    && grep -q -- "- Model: Smoke Model B" "$SMOKE_SUMMARY_PATH" \
    && grep -q -- "- Failed turns: 0" "$SMOKE_SUMMARY_PATH" \
    && grep -q "Second smoke prompt" "$SMOKE_SUMMARY_PATH" \
    && grep -q "Second smoke response" "$SMOKE_SUMMARY_PATH" \
    && grep -q "Ready to continue from the latest response." "$SMOKE_SUMMARY_PATH"; then
    note "Chat summary saved: $SMOKE_SUMMARY_PATH"
else
    warn_or_fail "Save summary did not write expected handoff content to $SMOKE_SUMMARY_PATH"
fi
wait_ax "$PID" "Summary saved" 10
assert_ax_grep "$PID" "Saved summary:"
COPIED_SUMMARY_PATH="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_SUMMARY_PATH" == "$SMOKE_SUMMARY_PATH" ]]; then
    note "Copied Chat summary path to clipboard"
else
    warn_or_fail "Save summary did not copy summary path"
fi
SMOKE_SESSION_SUMMARY_PATH="$(chat_session_field "66666666-6666-6666-6666-666666666666" "summaryExportPath")"
if [[ "$SMOKE_SESSION_SUMMARY_PATH" == "$SMOKE_SUMMARY_PATH" ]]; then
    note "Save summary persisted summary path on selected chat session"
else
    warn_or_fail "Save summary did not persist selected session summary path: ${SMOKE_SESSION_SUMMARY_PATH:-missing}"
fi

click_ax "$PID" "Models"
wait_ax "$PID" "Ready Now" 10
click_ax "$PID" "Refresh"
wait_ax "$PID" "Smoke-Delete-Model" 15
shot_ax "$PID" "models"
assert_ax_grep "$PID" "Ready Now"
assert_ax_grep "$PID" "Best ready action"
assert_ax_grep "$PID" "Local folders"
assert_ax_grep "$PID" "Needs proof"
assert_ax_grep "$PID" "Proof needed"
assert_ax_grep "$PID" "Memory fit"
assert_ax_grep "$PID" "Memory fit Spacious"
assert_ax_grep "$PID" "Memory fit Comfort"
assert_ax_grep "$PID" "Estimated runtime"
assert_ax_grep "$PID" "GB est"
assert_ax_grep "$PID" "system memory"
assert_ax_grep "$PID" "Ready on disk"
assert_ax_grep "$PID" "Canvas only"
assert_ax_grep "$PID" "Verify in Create"
assert_ax_grep "$PID" "Chat route"
assert_ax_grep "$PID" "Select model Smoke-Delete-Model"
assert_ax_grep "$PID" "Load model Smoke-Delete-Model"
assert_ax_grep "$PID" "Chat with Smoke-Delete-Model"
assert_ax_grep "$PID" "Load model unavailable AITRADER/FLUX1-schnell-mlx-4bit"
assert_ax_grep "$PID" "Verify in Create AITRADER/FLUX1-schnell-mlx-4bit"
assert_ax_grep "$PID" "Delete model files Smoke-Delete-Model"
click_ax "$PID" "Chat with Smoke-Delete-Model"
wait_ax "$PID" "Conversation runway" 10
assert_ax_grep "$PID" "Smoke-Delete-Model"
assert_ax_grep "$PID" "Model readiness"
note "Models Chat action opened Chat with selected model handoff"
click_ax "$PID" "Models"
wait_ax "$PID" "Ready Now" 10
click_ax "$PID" "Refresh"
wait_ax "$PID" "Smoke-Delete-Model" 15
assert_ax_grep "$PID" "Models"
assert_ax_grep "$PID" "Ready Now"
click_ax "$PID" "Delete model files Smoke-Delete-Model"
wait_ax "$PID" "Delete model files?" 10
assert_ax_grep "$PID" "not just a Library record"
shot_ax "$PID" "models-delete-confirmation"
click_ax "$PID" "Delete files for Smoke-Delete-Model"
for _ in {1..40}; do
    [[ ! -d "$SMOKE_DELETE_MODEL_FIXTURE_DIR" ]] && break
    sleep 0.25
done
if [[ ! -d "$SMOKE_DELETE_MODEL_FIXTURE_DIR" ]]; then
    note "Deleted smoke model files: $SMOKE_DELETE_MODEL_FIXTURE_DIR"
else
    warn_or_fail "Delete Files left smoke model directory on disk: $SMOKE_DELETE_MODEL_FIXTURE_DIR"
fi
assert_ax_grep "$PID" "Recommended Starters"
assert_ax_grep "$PID" "Compatible Hub"
assert_ax_grep "$PID" "HF auth"
assert_ax_grep "$PID" "Gated repos"
type_ax "$PID" "Search Hugging Face" "$SMOKE_DEFAULT_CHAT_QUERY"
click_ax "$PID" "Run Hub Search"
HUB_SEARCH_DEADLINE=$((SECONDS + ${MLX_STUDIO_HUB_WAIT_SECONDS:-30}))
while (( SECONDS < HUB_SEARCH_DEADLINE )); do
    if ax_grep_contains "$PID" "Hub Download and Chat $SMOKE_DEFAULT_CHAT_REPO"; then
        break
    fi
    scroll_ax "$PID" "-7"
    sleep 1
done
shot_ax "$PID" "models-hf-search"
HUB_RESULT_GREP="$REPORT_DIR/grep-${TS}-compatible_hub_result.txt"
if "$AX_BIN" grep "$PID" "Weights" >"$HUB_RESULT_GREP" 2>&1 && grep -qi "Weights" "$HUB_RESULT_GREP"; then
    note "AX found: Hub result metadata"
    assert_ax_grep "$PID" "$SMOKE_DEFAULT_CHAT_NAME"
    assert_ax_grep "$PID" "compatible result"
    assert_ax_grep "$PID" "Weights"
    assert_ax_grep "$PID" "Storage"
    assert_ax_grep "$PID" "supported by vMLX"
    click_ax "$PID" "Hub Download and Chat $SMOKE_DEFAULT_CHAT_REPO"
    wait_ax "$PID" "Session context" 180
    shot_ax "$PID" "chat-after-hub-install"
    assert_ax_grep "$PID" "$SMOKE_DEFAULT_CHAT_NAME"
    assert_ax_grep "$PID" "Loaded"
    assert_ax_grep "$PID" "Loaded in memory"
else
    if [[ "$REQUIRE_AX" == "1" ]]; then
        warn_or_fail "AX did not find compatible Hub results"
    else
        note "WARN: optional Hub search returned no compatible result"
    fi
fi

click_ax "$PID" "Create"
wait_ax "$PID" "Generation Settings" 10
shot_ax "$PID" "create-settings"
assert_ax_grep "$PID" "Generation Settings"
assert_ax_grep "$PID" "Canvas stage"
assert_ax_grep "$PID" "Output canvas"
assert_ax_grep "$PID" "Prompt provenance"
assert_ax_grep "$PID" "Ready for reuse"
assert_ax_grep "$PID" "Result handoff"
assert_ax_grep "$PID" "Prompt captured"
assert_ax_grep "$PID" "Settings captured"
assert_ax_grep "$PID" "File captured"
assert_ax_grep "$PID" "Saved asset"
assert_ax_grep "$PID" "Output actions"
assert_ax_grep "$PID" "Reveal file"
assert_ax_grep "$PID" "Copy path"
assert_ax_grep "$PID" "Steps"
assert_ax_grep "$PID" "Guidance"
assert_ax_grep "$PID" "Creative brief"
assert_ax_grep "$PID" "Product shot"
assert_ax_grep "$PID" "Portrait light"
assert_ax_grep "$PID" "Concept frame"
assert_ax_grep "$PID" "Prompt brief"
assert_ax_grep "$PID" "Recent outputs"
assert_ax_grep "$PID" "Ready output"
assert_ax_grep "$PID" "Missing file"
assert_ax_grep "$PID" "Failed output"
assert_ax_grep "$PID" "Create action prompt"
assert_ax_grep "$PID" "Delete history output Smoke image prompt"
assert_ax_grep "$PID" "Recall history output Known catalog prompt"
assert_ax_grep "$PID" "Verify FLUX.1 Schnell"
assert_ax_grep "$PID" "Selected FLUX.2 Klein 4B"
click_ax "$PID" "Recall history output Known catalog prompt"
wait_ax "$PID" "Selected FLUX.1 Schnell" 10
shot_ax "$PID" "create-known-catalog-recall"
assert_ax_grep "$PID" "FLUX.1 Schnell"
assert_ax_grep "$PID" "Selected FLUX.1 Schnell"
assert_ax_grep "$PID" "W 256"
assert_ax_grep "$PID" "H 256"
assert_ax_value "$PID" "Image prompt brief" "Known catalog prompt"
click_ax "$PID" "Select FLUX.2 Klein 4B"
wait_ax "$PID" "Selected FLUX.2 Klein 4B" 10
click_ax "$PID" "Verify FLUX.1 Schnell"
wait_ax "$PID" "Verify & Generate" 10
assert_ax_grep "$PID" "Selected FLUX.1 Schnell"
assert_ax_grep "$PID" "Verify & Generate"
shot_ax "$PID" "create-proof-gated-verify-generate"
click_ax "$PID" "Select FLUX.2 Klein 4B"
wait_ax "$PID" "Selected FLUX.2 Klein 4B" 10
if [[ -f "$HOME/Library/Application Support/vMLX/image-runtime-proofs/z-image-turbo.json" ]]; then
    assert_ax_grep "$PID" "Proven ready"
    assert_ax_grep "$PID" "Z-Image Turbo 6-bit"
fi
click_ax "$PID" "Delete history output Smoke image prompt"
wait_ax "$PID" "Delete output?" 10
assert_ax_grep "$PID" "Confirm delete output Smoke image prompt"
assert_ax_grep "$PID" "This deletes its output file"
shot_ax "$PID" "create-history-output-delete-confirmation"
click_ax "$PID" "Cancel"
assert_ax_not_grep "$PID" "Delete output?"
if [[ -f "$SMOKE_IMAGE_PNG" && -f "${SMOKE_IMAGE_PNG}.metadata.json" ]]; then
    note "Create history output delete cancel preserved image artifacts"
else
    warn_or_fail "Create history output delete cancel removed image artifacts"
fi
SMOKE_HISTORY_IMAGE_ROWS_AFTER_CANCEL="$(/usr/bin/sqlite3 "$SMOKE_IMAGE_DB" "SELECT COUNT(*) FROM image_generations WHERE id='55555555-5555-5555-5555-555555555555';" 2>/dev/null || echo "sqlite-error")"
if [[ "$SMOKE_HISTORY_IMAGE_ROWS_AFTER_CANCEL" == "1" ]]; then
    note "Create history output delete cancel preserved image history row"
else
    warn_or_fail "Create history output delete cancel changed image history row count: $SMOKE_HISTORY_IMAGE_ROWS_AFTER_CANCEL"
fi
click_ax "$PID" "Reveal file"
for _ in {1..25}; do
    [[ -f "$SMOKE_CREATE_REVEAL_LOG" ]] && grep -qx "$SMOKE_CREATE_ACTION_PNG" "$SMOKE_CREATE_REVEAL_LOG" && break
    sleep 0.2
done
if [[ -f "$SMOKE_CREATE_REVEAL_LOG" ]] && grep -qx "$SMOKE_CREATE_ACTION_PNG" "$SMOKE_CREATE_REVEAL_LOG"; then
    note "Create Reveal file targeted output path"
else
    warn_or_fail "Create Reveal file did not target expected output path"
fi
click_ax "$PID" "Copy path"
COPIED_CREATE_OUTPUT_PATH="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_CREATE_OUTPUT_PATH" == "$SMOKE_CREATE_ACTION_PNG" ]]; then
    note "Create Copy path copied output path"
else
    warn_or_fail "Create Copy path wrote unexpected clipboard text"
fi
click_ax "$PID" "Reuse prompt"
assert_ax_value "$PID" "Image prompt brief" "Create action prompt"
assert_ax_grep "$PID" "Choose an image model"
assert_ax_grep "$PID" "Reused prompt came from Create Action Image Model"
click_ax "$PID" "Delete output"
wait_ax "$PID" "Delete output?" 10
assert_ax_grep "$PID" "This deletes its output file"
assert_ax_grep "$PID" "Models, chats, and other image outputs are not deleted."
shot_ax "$PID" "create-output-delete-confirmation"
if [[ -f "$SMOKE_CREATE_ACTION_PNG" && -f "${SMOKE_CREATE_ACTION_PNG}.metadata.json" ]]; then
    note "Create Delete output confirmation preserved image artifacts until confirm"
else
    warn_or_fail "Create Delete output confirmation removed image artifacts before confirm"
fi
SMOKE_CREATE_ACTION_ROWS_BEFORE_DELETE="$(/usr/bin/sqlite3 "$SMOKE_IMAGE_DB" "SELECT COUNT(*) FROM image_generations WHERE id='77777777-7777-7777-7777-777777777777';" 2>/dev/null || echo "sqlite-error")"
if [[ "$SMOKE_CREATE_ACTION_ROWS_BEFORE_DELETE" == "1" ]]; then
    note "Create Delete output confirmation preserved image history row until confirm"
else
    warn_or_fail "Create Delete output confirmation changed image history row count before confirm: $SMOKE_CREATE_ACTION_ROWS_BEFORE_DELETE"
fi
click_ax "$PID" "Confirm delete output Create action prompt"
wait_ax "$PID" "Smoke image prompt" 10
shot_ax "$PID" "create-output-actions"
if [[ ! -f "$SMOKE_CREATE_ACTION_PNG" && ! -f "${SMOKE_CREATE_ACTION_PNG}.metadata.json" ]]; then
    note "Create Delete output removed image and metadata sidecar"
else
    warn_or_fail "Create Delete output left image artifacts on disk"
fi
SMOKE_CREATE_ACTION_ROWS="$(/usr/bin/sqlite3 "$SMOKE_IMAGE_DB" "SELECT COUNT(*) FROM image_generations WHERE id='77777777-7777-7777-7777-777777777777';" 2>/dev/null || echo "sqlite-error")"
if [[ "$SMOKE_CREATE_ACTION_ROWS" == "0" ]]; then
    note "Create Delete output removed image history row"
else
    warn_or_fail "Create Delete output left image history row count: $SMOKE_CREATE_ACTION_ROWS"
fi
type_ax "$PID" "Image prompt brief" ""
wait_ax "$PID" "Image starter Product shot" 10
click_ax "$PID" "Image starter Product shot"
assert_ax_value "$PID" "Image prompt brief" "cinematic product photo of a translucent local AI workstation on a graphite desk"
type_ax "$PID" "Image prompt brief" ""
wait_ax "$PID" "Image starter Portrait light" 10
click_ax "$PID" "Image starter Portrait light"
assert_ax_value "$PID" "Image prompt brief" "soft studio portrait, reflective black background, precise rim light"
type_ax "$PID" "Image prompt brief" ""
wait_ax "$PID" "Image starter Concept frame" 10
click_ax "$PID" "Image starter Concept frame"
assert_ax_value "$PID" "Image prompt brief" "quiet futuristic Mac studio, local model cards floating as glass panels"
shot_ax "$PID" "create-prompt-starters"

click_ax "$PID" "Library"
wait_ax "$PID" "Search Library" 10
shot_ax "$PID" "library"
assert_ax_grep "$PID" "Search Library"
assert_ax_grep "$PID" "Recent work"
assert_ax_grep "$PID" "Studio memory"
assert_ax_grep "$PID" "Image provenance"
assert_ax_grep "$PID" "Latest image"
assert_ax_grep "$PID" "Resume session"
assert_ax_grep "$PID" "Open latest chat Second smoke session"
assert_ax_grep "$PID" "Generated images"
assert_ax_grep "$PID" "Chat sessions"
assert_ax_grep "$PID" "Model archive"
assert_ax_grep "$PID" "Pinned work"
assert_ax_grep "$PID" "Open generated images in Create"
assert_ax_grep "$PID" "Open chat sessions in Chat"
assert_ax_grep "$PID" "Show Model archive"
assert_ax_grep "$PID" "Show Pinned work"
assert_ax_grep "$PID" "Smoke image prompt"
assert_ax_grep "$PID" "Reuse latest image Smoke image prompt"
assert_ax_grep "$PID" "Open latest image in Create Smoke image prompt"
assert_ax_grep "$PID" "Browse model archive $SMOKE_DEFAULT_CHAT_REPO"
assert_ax_not_grep "$PID" "Browse model archive AITRADER/FLUX1-schnell-mlx-4bit"
assert_ax_grep "$PID" "Second smoke session"
assert_ax_grep "$PID" "Pinned"
click_ax "$PID" "Reuse latest image Smoke image prompt"
wait_ax "$PID" "Image prompt brief" 10
shot_ax "$PID" "library-latest-image-reuse-create"
assert_ax_grep "$PID" "Generation Settings"
assert_ax_grep "$PID" "Reused prompt came from Smoke Image Model"
assert_ax_value "$PID" "Image prompt brief" "Smoke image prompt"
click_ax "$PID" "Library"
wait_ax "$PID" "Search Library" 10
click_ax "$PID" "Open latest image in Create Smoke image prompt"
wait_ax "$PID" "Image prompt brief" 10
shot_ax "$PID" "library-latest-image-open-create"
assert_ax_grep "$PID" "Generation Settings"
assert_ax_grep "$PID" "Reused prompt came from Smoke Image Model"
assert_ax_value "$PID" "Image prompt brief" "Smoke image prompt"
click_ax "$PID" "Library"
wait_ax "$PID" "Search Library" 10
click_ax "$PID" "Browse model archive $SMOKE_DEFAULT_CHAT_REPO"
wait_ax "$PID" "Ready Now" 10
shot_ax "$PID" "library-model-archive-browse-models"
assert_ax_grep "$PID" "$SMOKE_DEFAULT_CHAT_NAME"
assert_ax_grep "$PID" "$SMOKE_DEFAULT_CHAT_REPO is live"
assert_ax_grep "$PID" "Selected"
assert_ax_grep "$PID" "Ready on disk"
click_ax "$PID" "Library"
wait_ax "$PID" "Search Library" 10
click_ax "$PID" "Show Pinned work"
wait_ax "$PID" "Pinned sessions" 10
shot_ax "$PID" "library-overview-show-pinned"
assert_ax_grep "$PID" "Smoke chat session"
click_ax "$PID" "All"
wait_ax "$PID" "Show Model archive" 10
click_ax "$PID" "Show Model archive"
wait_ax "$PID" "Downloaded models" 10
type_ax "$PID" "Search Library" "Smoke-Library"
wait_ax "$PID" "Smoke-Library-Model" 10
shot_ax "$PID" "library-models-filter"
assert_ax_grep "$PID" "Model archive"
assert_ax_grep "$PID" "Downloaded models"
assert_ax_grep "$PID" "Smoke-Library-Model"
click_ax "$PID" "Copy model path Smoke-Library-Model"
COPIED_MODEL_PATH="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_MODEL_PATH" == "$SMOKE_MODEL_FIXTURE_DIR" ]]; then
    note "Copied Library model path to clipboard"
else
    warn_or_fail "Copy model path wrote unexpected clipboard text"
fi
SMOKE_MODEL_REPORT="$SMOKE_MODEL_REPORT_EXPORT_DIR/Smoke-Library-Model-model-report.json"
click_ax "$PID" "Export model report Smoke-Library-Model"
for _ in {1..25}; do
    [[ -f "$SMOKE_MODEL_REPORT" ]] && break
    sleep 0.2
done
if [[ -f "$SMOKE_MODEL_REPORT" ]] \
    && /usr/bin/python3 - "$SMOKE_MODEL_REPORT" "$SMOKE_MODEL_FIXTURE_DIR" <<'PY'
import json
import sys

path, expected_local_path = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

summary = payload.get("fileSummary") or {}
ok = payload.get("displayName") == "Smoke-Library-Model"
ok = ok and payload.get("localPath") == expected_local_path
ok = ok and payload.get("sizeBytes", 0) >= 9437184
ok = ok and summary.get("weightFileCount") == 1
ok = ok and summary.get("configPresent") is True
ok = ok and summary.get("tokenizerPresent") is True
sys.exit(0 if ok else 1)
PY
then
    note "Exported Library model report JSON: $SMOKE_MODEL_REPORT"
else
    warn_or_fail "Library model report export did not write expected JSON"
fi
COPIED_MODEL_REPORT="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_MODEL_REPORT" == "$SMOKE_MODEL_REPORT" ]]; then
    note "Copied Library model report path to clipboard"
else
    warn_or_fail "Model report export did not copy exported path"
fi
shot_ax "$PID" "library-model-report-exported"
click_ax "$PID" "Open model Smoke-Library-Model in Models"
wait_ax "$PID" "Ready Now" 10
assert_ax_grep "$PID" "Smoke-Library-Model is selected"
assert_ax_grep "$PID" "Chat route"
shot_ax "$PID" "library-model-open-models"
click_ax "$PID" "Library"
wait_ax "$PID" "Search Library" 10
type_ax "$PID" "Search Library" "not loaded model"
wait_ax "$PID" "Smoke-Library-Model" 10
shot_ax "$PID" "library-model-search-not-loaded"
assert_ax_grep "$PID" "Smoke-Library-Model"
assert_ax_grep "$PID" "Not loaded"
type_ax "$PID" "Search Library" "$SMOKE_MODEL_FIXTURE_DIR"
wait_ax "$PID" "Smoke-Library-Model" 10
shot_ax "$PID" "library-model-search-path"
assert_ax_grep "$PID" "Smoke-Library-Model"
assert_ax_grep "$PID" "Not loaded"
type_ax "$PID" "Search Library" ""
click_ax "$PID" "All"
wait_ax "$PID" "Open latest chat Second smoke session" 10
click_ax "$PID" "Open latest chat Second smoke session"
wait_ax "$PID" "Second smoke prompt" 10
shot_ax "$PID" "library-open-latest-chat"
assert_ax_grep "$PID" "Second smoke session"
assert_ax_grep "$PID" "Second smoke response"
SELECTED_SESSION_AFTER_OPEN_LATEST="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ "$SELECTED_SESSION_AFTER_OPEN_LATEST" == "66666666-6666-6666-6666-666666666666" ]]; then
    note "Open Latest Chat selected latest chat session"
else
    warn_or_fail "Open Latest Chat selected unexpected session"
fi

click_ax "$PID" "Library"
wait_ax "$PID" "Search Library" 10

click_ax "$PID" "Images"
type_ax "$PID" "Search Library" "image prompt"
wait_ax "$PID" "Smoke image prompt" 10
shot_ax "$PID" "library-images-filter"
assert_ax_grep "$PID" "Images memory"
assert_ax_grep "$PID" "Visual outputs"
assert_ax_grep "$PID" "Reuse lane"
assert_ax_grep "$PID" "Captured"
assert_ax_grep "$PID" "Reusable"
assert_ax_grep "$PID" "Reuse latest prompt"
assert_ax_grep "$PID" "Open canvas"
assert_ax_grep "$PID" "Reuse latest prompt Smoke image prompt"
assert_ax_grep "$PID" "Open canvas Smoke image prompt"
assert_ax_grep "$PID" "Smoke Image Model"
assert_ax_grep "$PID" "Missing Image Model"
assert_ax_grep "$PID" "Missing image prompt"
assert_ax_grep "$PID" "Failed Image Model"
assert_ax_grep "$PID" "Failed image prompt"
assert_ax_grep "$PID" "Memory tile"
assert_ax_grep "$PID" "Ready artifact"
assert_ax_grep "$PID" "Missing file"
assert_ax_grep "$PID" "Prompt packet"
assert_ax_grep "$PID" "Provenance"
assert_ax_grep "$PID" "Sidecar saved"
assert_ax_grep "$PID" "Exportable"
assert_ax_grep "$PID" "File Missing"
assert_ax_grep "$PID" "File Failed"
assert_ax_grep "$PID" "Reuse"
assert_ax_grep "$PID" "Reuse image Smoke image prompt"
assert_ax_grep "$PID" "Open image Smoke image prompt"
assert_ax_grep "$PID" "Reveal image Smoke image prompt"
assert_ax_grep "$PID" "Copy prompt Smoke image prompt"
assert_ax_grep "$PID" "Export metadata Smoke image prompt"
assert_ax_grep "$PID" "Delete image record and file Smoke image prompt"
assert_ax_grep "$PID" "Delete image record and file Missing image prompt"
assert_ax_grep "$PID" "Delete image record and file Failed image prompt"
assert_ax_grep "$PID" "128x128"
type_ax "$PID" "Search Library" "sidecar saved"
wait_ax "$PID" "Smoke image prompt" 10
shot_ax "$PID" "library-search-sidecar-saved"
assert_ax_grep "$PID" "Smoke image prompt"
assert_ax_grep "$PID" "Sidecar saved"
type_ax "$PID" "Search Library" "file missing"
wait_ax "$PID" "Missing image prompt" 10
shot_ax "$PID" "library-search-file-missing"
assert_ax_grep "$PID" "Missing image prompt"
assert_ax_grep "$PID" "File Missing"
type_ax "$PID" "Search Library" "file failed"
wait_ax "$PID" "Failed image prompt" 10
shot_ax "$PID" "library-search-file-failed"
assert_ax_grep "$PID" "Failed image prompt"
assert_ax_grep "$PID" "File Failed"
type_ax "$PID" "Search Library" "Smoke image prompt"
wait_ax "$PID" "Smoke image prompt" 10
click_ax "$PID" "Reuse latest prompt Smoke image prompt"
wait_ax "$PID" "Image prompt brief" 10
shot_ax "$PID" "library-reuse-latest-prompt-create"
assert_ax_grep "$PID" "Generation Settings"
assert_ax_grep "$PID" "Choose an image model"
assert_ax_grep "$PID" "Reused prompt came from Smoke Image Model"
assert_ax_grep "$PID" "W 256"
assert_ax_grep "$PID" "H 256"
assert_ax_not_grep "$PID" "Image dimensions must be at least 256x256."
assert_ax_value "$PID" "Image prompt brief" "Smoke image prompt"
click_ax "$PID" "Library"
wait_ax "$PID" "Search Library" 10
click_ax "$PID" "Images"
type_ax "$PID" "Search Library" "image prompt"
wait_ax "$PID" "Smoke image prompt" 10
click_ax "$PID" "Copy prompt Smoke image prompt"
COPIED_IMAGE_PROMPT="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_IMAGE_PROMPT" == "Smoke image prompt" ]]; then
    note "Copied image prompt to clipboard"
else
    warn_or_fail "Copy prompt for image wrote unexpected clipboard text"
fi
SMOKE_IMAGE_METADATA_EXPORT="$SMOKE_IMAGE_METADATA_EXPORT_DIR/Smoke Image Model-55555555.json"
click_ax "$PID" "Export metadata Smoke image prompt"
for _ in {1..25}; do
    [[ -f "$SMOKE_IMAGE_METADATA_EXPORT" ]] && break
    sleep 0.2
done
if [[ -f "$SMOKE_IMAGE_METADATA_EXPORT" ]] \
    && /usr/bin/python3 - "$SMOKE_IMAGE_METADATA_EXPORT" "$SMOKE_IMAGE_PNG" <<'PY'
import json
import sys

path, expected_output = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

expected = {
    "schemaVersion": 1,
    "prompt": "Smoke image prompt",
    "modelAlias": "Smoke Image Model",
    "outputPath": expected_output,
    "status": "completed",
}

settings = payload.get("settings") or {}
ok = all(payload.get(key) == value for key, value in expected.items())
ok = ok and settings.get("width") == 128 and settings.get("height") == 128
ok = ok and settings.get("seed") == 7 and settings.get("steps") == 4
sys.exit(0 if ok else 1)
PY
then
    note "Exported image metadata JSON: $SMOKE_IMAGE_METADATA_EXPORT"
else
    warn_or_fail "Image metadata export did not write expected JSON"
fi
COPIED_IMAGE_METADATA_EXPORT="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_IMAGE_METADATA_EXPORT" == "$SMOKE_IMAGE_METADATA_EXPORT" ]]; then
    note "Copied image metadata export path to clipboard"
else
    warn_or_fail "Image metadata export did not copy exported path"
fi
shot_ax "$PID" "library-image-metadata-exported"
click_ax "$PID" "Open image Smoke image prompt"
for _ in {1..25}; do
    [[ -f "$SMOKE_LIBRARY_OPEN_LOG" ]] && grep -qx "$SMOKE_IMAGE_PNG" "$SMOKE_LIBRARY_OPEN_LOG" && break
    sleep 0.2
done
if [[ -f "$SMOKE_LIBRARY_OPEN_LOG" ]] && grep -qx "$SMOKE_IMAGE_PNG" "$SMOKE_LIBRARY_OPEN_LOG"; then
    note "Library Open image targeted output path"
else
    warn_or_fail "Library Open image did not target expected output path"
fi
click_ax "$PID" "Reveal image Smoke image prompt"
for _ in {1..25}; do
    [[ -f "$SMOKE_LIBRARY_REVEAL_LOG" ]] && grep -qx "$SMOKE_IMAGE_PNG" "$SMOKE_LIBRARY_REVEAL_LOG" && break
    sleep 0.2
done
if [[ -f "$SMOKE_LIBRARY_REVEAL_LOG" ]] && grep -qx "$SMOKE_IMAGE_PNG" "$SMOKE_LIBRARY_REVEAL_LOG"; then
    note "Library Reveal image targeted output path"
else
    warn_or_fail "Library Reveal image did not target expected output path"
fi
click_ax "$PID" "Open canvas Smoke image prompt"
wait_ax "$PID" "Image prompt brief" 10
shot_ax "$PID" "create-after-open-canvas"
assert_ax_grep "$PID" "Generation Settings"
assert_ax_grep "$PID" "No model selected"
assert_ax_grep "$PID" "Choose an image model"
assert_ax_grep "$PID" "Reused prompt came from Smoke Image Model"
assert_ax_value "$PID" "Image prompt brief" "Smoke image prompt"

click_ax "$PID" "Library"
wait_ax "$PID" "Search Library" 10
click_ax "$PID" "Images"
type_ax "$PID" "Search Library" "image prompt"
wait_ax "$PID" "Smoke image prompt" 10
click_ax "$PID" "Delete image record and file Smoke image prompt"
wait_ax "$PID" "Delete image artifact?" 10
assert_ax_grep "$PID" "This deletes the saved image record"
assert_ax_grep "$PID" "Models, chats, and other image outputs are not deleted."
shot_ax "$PID" "library-image-delete-confirmation"
if [[ -f "$SMOKE_IMAGE_PNG" && -f "${SMOKE_IMAGE_PNG}.metadata.json" ]]; then
    note "Image delete confirmation preserved image artifacts until confirm"
else
    warn_or_fail "Image delete confirmation removed image artifacts before confirm"
fi
SMOKE_IMAGE_ROWS_BEFORE_DELETE="$(/usr/bin/sqlite3 "$SMOKE_IMAGE_DB" "SELECT COUNT(*) FROM image_generations WHERE id='55555555-5555-5555-5555-555555555555';" 2>/dev/null || echo "sqlite-error")"
if [[ "$SMOKE_IMAGE_ROWS_BEFORE_DELETE" == "1" ]]; then
    note "Image delete confirmation preserved image history row until confirm"
else
    warn_or_fail "Image delete confirmation changed image history row count before confirm: $SMOKE_IMAGE_ROWS_BEFORE_DELETE"
fi
click_ax "$PID" "Confirm delete image Smoke image prompt"
wait_ax "$PID" "Missing image prompt" 10
shot_ax "$PID" "library-ready-image-deleted-missing-remains"
if [[ ! -f "$SMOKE_IMAGE_PNG" && ! -f "${SMOKE_IMAGE_PNG}.metadata.json" ]]; then
    note "Deleted image output and metadata sidecar"
else
    warn_or_fail "Delete image record and file left image artifacts on disk"
fi
SMOKE_IMAGE_ROWS="$(/usr/bin/sqlite3 "$SMOKE_IMAGE_DB" "SELECT COUNT(*) FROM image_generations WHERE id='55555555-5555-5555-5555-555555555555';" 2>/dev/null || echo "sqlite-error")"
if [[ "$SMOKE_IMAGE_ROWS" == "0" ]]; then
    note "Deleted image history row"
else
    warn_or_fail "Delete image record and file left image history row count: $SMOKE_IMAGE_ROWS"
fi
assert_ax_grep "$PID" "Missing Image Model"
assert_ax_grep "$PID" "Missing file"
assert_ax_grep "$PID" "Failed image prompt"
click_ax "$PID" "Delete image record and file Missing image prompt"
wait_ax "$PID" "Delete image artifact?" 10
click_ax "$PID" "Confirm delete image Missing image prompt"
wait_ax "$PID" "Failed image prompt" 10
shot_ax "$PID" "library-missing-image-deleted-failed-remains"
SMOKE_MISSING_IMAGE_ROWS="$(/usr/bin/sqlite3 "$SMOKE_IMAGE_DB" "SELECT COUNT(*) FROM image_generations WHERE id='99999999-9999-9999-9999-999999999999';" 2>/dev/null || echo "sqlite-error")"
if [[ "$SMOKE_MISSING_IMAGE_ROWS" == "0" ]]; then
    note "Deleted missing image history row"
else
    warn_or_fail "Delete image record and file left missing image history row count: $SMOKE_MISSING_IMAGE_ROWS"
fi
assert_ax_grep "$PID" "Failed Image Model"
assert_ax_grep "$PID" "File Failed"
type_ax "$PID" "Search Library" "Failed image prompt"
click_ax "$PID" "All"
wait_ax "$PID" "Failed image prompt" 10
shot_ax "$PID" "library-failed-latest-memory"
assert_ax_grep "$PID" "Latest image"
assert_ax_grep "$PID" "Image provenance"
assert_ax_grep "$PID" "Failed Image Model"
assert_ax_grep "$PID" "File Failed"
assert_ax_grep "$PID" "1 image match"
assert_ax_grep "$PID" "0 chat matches"
assert_ax_grep "$PID" "0 model matches"
assert_ax_grep "$PID" "0 pinned matches"
assert_ax_grep "$PID" "No matching chats"
assert_ax_grep "$PID" "No matching models"
assert_ax_grep "$PID" "Clear Search"
click_ax "$PID" "Clear Search"
wait_ax "$PID" "Open latest chat Second smoke session" 10
assert_ax_grep "$PID" "Second smoke session"
type_ax "$PID" "Search Library" "Failed image prompt"
wait_ax "$PID" "Failed image prompt" 10
NO_LOCAL_MODELS_GREP="$REPORT_DIR/grep-${TS}-no-local-models-after-failed-image-search.txt"
if "$AX_BIN" grep "$PID" "No local models" >"$NO_LOCAL_MODELS_GREP" 2>&1 \
    && grep -Fqi "No local models" "$NO_LOCAL_MODELS_GREP"; then
    warn_or_fail "Library search showed global empty model label while model matches were zero"
else
    note "Library search scoped model empty label"
fi
SMOKE_FAILED_IMAGE_METADATA_EXPORT="$SMOKE_IMAGE_METADATA_EXPORT_DIR/Failed Image Model-AAAAAAAA.json"
click_ax "$PID" "Export metadata Failed image prompt"
for _ in {1..25}; do
    [[ -f "$SMOKE_FAILED_IMAGE_METADATA_EXPORT" ]] && break
    sleep 0.2
done
if [[ -f "$SMOKE_FAILED_IMAGE_METADATA_EXPORT" ]] \
    && /usr/bin/python3 - "$SMOKE_FAILED_IMAGE_METADATA_EXPORT" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

settings = payload.get("settings") or {}
ok = payload.get("schemaVersion") == 1
ok = ok and payload.get("prompt") == "Failed image prompt"
ok = ok and payload.get("modelAlias") == "Failed Image Model"
ok = ok and payload.get("outputPath") is None
ok = ok and payload.get("status") == "failed"
ok = ok and settings.get("width") == 128 and settings.get("height") == 128
ok = ok and settings.get("seed") == 21 and settings.get("steps") == 3
sys.exit(0 if ok else 1)
PY
then
    note "Exported failed image metadata JSON: $SMOKE_FAILED_IMAGE_METADATA_EXPORT"
else
    warn_or_fail "Failed image metadata export did not write expected JSON"
fi
COPIED_FAILED_IMAGE_METADATA_EXPORT="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_FAILED_IMAGE_METADATA_EXPORT" == "$SMOKE_FAILED_IMAGE_METADATA_EXPORT" ]]; then
    note "Copied failed image metadata export path to clipboard"
else
    warn_or_fail "Failed image metadata export did not copy exported path"
fi
click_ax "$PID" "Delete image record and file Failed image prompt"
wait_ax "$PID" "Delete image artifact?" 10
click_ax "$PID" "Confirm delete image Failed image prompt"
wait_ax "$PID" "No generated images" 10
shot_ax "$PID" "library-image-deleted"
SMOKE_FAILED_IMAGE_ROWS="$(/usr/bin/sqlite3 "$SMOKE_IMAGE_DB" "SELECT COUNT(*) FROM image_generations WHERE id='AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA';" 2>/dev/null || echo "sqlite-error")"
if [[ "$SMOKE_FAILED_IMAGE_ROWS" == "0" ]]; then
    note "Deleted failed image history row"
else
    warn_or_fail "Delete image record and file left failed image history row count: $SMOKE_FAILED_IMAGE_ROWS"
fi

type_ax "$PID" "Search Library" ""
click_ax "$PID" "Chats"
wait_ax "$PID" "Second smoke session" 10
shot_ax "$PID" "library-chats-filter"
assert_ax_grep "$PID" "Conversation archive"
assert_ax_grep "$PID" "Smoke chat session"
assert_ax_grep "$PID" "Second smoke response"
assert_ax_grep "$PID" "1 failed"
assert_ax_grep "$PID" "Open chat Smoke chat session"
assert_ax_grep "$PID" "Open chat Second smoke session"
click_ax_expect "$PID" "Rename chat Second smoke session" "Rename Chat Session" 10
type_ax "$PID" "Rename chat title" "Renamed smoke session"
click_ax "$PID" "Rename"
wait_ax "$PID" "Renamed smoke session" 10
shot_ax "$PID" "library-chat-renamed"
RENAMED_SESSION_TITLE="$(chat_session_field "66666666-6666-6666-6666-666666666666" "title")"
if [[ "$RENAMED_SESSION_TITLE" == "Renamed smoke session" ]]; then
    note "Renamed selected chat session in persisted history"
else
    warn_or_fail "Rename chat did not update persisted session title"
fi
assert_second_session_activity_timestamp "Renaming selected chat"
SELECTED_SESSION_AFTER_RENAME="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ "$SELECTED_SESSION_AFTER_RENAME" == "66666666-6666-6666-6666-666666666666" ]]; then
    note "Renaming selected chat preserved selected session"
else
    warn_or_fail "Rename chat changed selected session unexpectedly"
fi
RENAMED_SESSION_SUMMARY_PATH="$(chat_session_field "66666666-6666-6666-6666-666666666666" "summaryExportPath")"
if [[ -z "$RENAMED_SESSION_SUMMARY_PATH" ]]; then
    note "Renaming selected chat cleared stale summary export state"
else
    warn_or_fail "Rename chat left stale summary export path: $RENAMED_SESSION_SUMMARY_PATH"
fi
SMOKE_MARKDOWN_EXPORT="$SMOKE_EXPORT_DIR/Renamed smoke session.md"
SMOKE_JSON_EXPORT="$SMOKE_EXPORT_DIR/Renamed smoke session.json"
SMOKE_FAILED_MARKDOWN_EXPORT="$SMOKE_EXPORT_DIR/Smoke chat session.md"
SMOKE_FAILED_JSON_EXPORT="$SMOKE_EXPORT_DIR/Smoke chat session.json"
click_ax "$PID" "Export Markdown chat Renamed smoke session"
for _ in {1..25}; do
    [[ -f "$SMOKE_MARKDOWN_EXPORT" ]] && break
    sleep 0.2
done
if [[ -f "$SMOKE_MARKDOWN_EXPORT" ]] \
    && grep -q "# Renamed smoke session" "$SMOKE_MARKDOWN_EXPORT" \
    && grep -q "Second smoke response" "$SMOKE_MARKDOWN_EXPORT"; then
    note "Exported Library chat markdown: $SMOKE_MARKDOWN_EXPORT"
else
    warn_or_fail "Library Markdown export did not write expected session content"
fi
COPIED_MARKDOWN_EXPORT="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_MARKDOWN_EXPORT" == "$SMOKE_MARKDOWN_EXPORT" ]]; then
    note "Copied Library markdown export path to clipboard"
else
    warn_or_fail "Markdown export did not copy exported path"
fi
click_ax "$PID" "Export Markdown chat Smoke chat session"
for _ in {1..25}; do
    [[ -f "$SMOKE_FAILED_MARKDOWN_EXPORT" ]] && break
    sleep 0.2
done
if [[ -f "$SMOKE_FAILED_MARKDOWN_EXPORT" ]] \
    && grep -q "# Smoke chat session" "$SMOKE_FAILED_MARKDOWN_EXPORT" \
    && grep -q "## Assistant (Failed)" "$SMOKE_FAILED_MARKDOWN_EXPORT" \
    && grep -q "Smoke response" "$SMOKE_FAILED_MARKDOWN_EXPORT"; then
    note "Exported failed Library chat markdown with turn state: $SMOKE_FAILED_MARKDOWN_EXPORT"
else
    warn_or_fail "Failed Library Markdown export did not preserve failed turn state"
fi
click_ax "$PID" "Export JSON chat Smoke chat session"
for _ in {1..25}; do
    [[ -f "$SMOKE_FAILED_JSON_EXPORT" ]] && break
    sleep 0.2
done
if [[ -f "$SMOKE_FAILED_JSON_EXPORT" ]] \
    && grep -q '"schemaVersion" : 1' "$SMOKE_FAILED_JSON_EXPORT" \
    && grep -q '"title" : "Smoke chat session"' "$SMOKE_FAILED_JSON_EXPORT" \
    && grep -q '"content" : "Smoke response"' "$SMOKE_FAILED_JSON_EXPORT" \
    && ! grep -q 'summaryExportPath' "$SMOKE_FAILED_JSON_EXPORT" \
    && ! grep -q 'summaryExportedAt' "$SMOKE_FAILED_JSON_EXPORT" \
    && ! grep -q "$SMOKE_STALE_SUMMARY_PATH" "$SMOKE_FAILED_JSON_EXPORT"; then
    note "Exported failed Library chat JSON without local summary metadata: $SMOKE_FAILED_JSON_EXPORT"
else
    warn_or_fail "Failed Library JSON export did not write portable expected session content"
fi
click_ax "$PID" "Export JSON chat Renamed smoke session"
for _ in {1..25}; do
    [[ -f "$SMOKE_JSON_EXPORT" ]] && break
    sleep 0.2
done
if [[ -f "$SMOKE_JSON_EXPORT" ]] \
    && grep -q '"schemaVersion" : 1' "$SMOKE_JSON_EXPORT" \
    && grep -q '"title" : "Renamed smoke session"' "$SMOKE_JSON_EXPORT" \
    && grep -q '"content" : "Second smoke response"' "$SMOKE_JSON_EXPORT" \
    && ! grep -q 'summaryExportPath' "$SMOKE_JSON_EXPORT" \
    && ! grep -q 'summaryExportedAt' "$SMOKE_JSON_EXPORT" \
    && ! grep -q "$SMOKE_SUMMARY_PATH" "$SMOKE_JSON_EXPORT"; then
    note "Exported Library chat JSON: $SMOKE_JSON_EXPORT"
else
    warn_or_fail "Library JSON export did not write portable expected session content"
fi
SELECTED_SESSION_AFTER_EXPORT="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ "$SELECTED_SESSION_AFTER_EXPORT" == "66666666-6666-6666-6666-666666666666" ]]; then
    note "Exporting Library chat preserved selected session"
else
    warn_or_fail "Exporting Library chat changed selected session unexpectedly"
fi
shot_ax "$PID" "library-chat-exported"
type_ax "$PID" "Search Library" "summary saved"
wait_ax "$PID" "Smoke chat session" 10
shot_ax "$PID" "library-search-summary-saved"
assert_ax_grep "$PID" "Summary saved"
assert_ax_grep "$PID" "Smoke chat session"
assert_ax_not_grep "$PID" "Renamed smoke session"
rm -f "$SMOKE_STALE_SUMMARY_PATH"
type_ax "$PID" "Search Library" "summary missing"
wait_ax "$PID" "Smoke chat session" 10
shot_ax "$PID" "library-search-summary-missing"
assert_ax_grep "$PID" "Summary missing"
assert_ax_grep "$PID" "Smoke chat session"
assert_ax_not_grep "$PID" "Renamed smoke session"
type_ax "$PID" "Search Library" ""
wait_ax "$PID" "Smoke chat session" 10
click_ax "$PID" "Unpin chat Smoke chat session"
wait_ax "$PID" "Pin chat Smoke chat session" 10
shot_ax "$PID" "library-chat-unpinned"
assert_ax_grep "$PID" "Pin chat Smoke chat session"
click_ax "$PID" "Pin chat Smoke chat session"
wait_ax "$PID" "Unpin chat Smoke chat session" 10
shot_ax "$PID" "library-chat-repinned"
assert_ax_grep "$PID" "Unpin chat Smoke chat session"

type_ax "$PID" "Search Library" "second smoke"
wait_ax "$PID" "Renamed smoke session" 10
shot_ax "$PID" "library-search-second"
assert_ax_grep "$PID" "Renamed smoke session"

type_ax "$PID" "Search Library" "$SMOKE_CHAT_ACTIVITY_DATE"
wait_ax "$PID" "Renamed smoke session" 10
shot_ax "$PID" "library-search-date"
assert_ax_grep "$PID" "Renamed smoke session"
assert_ax_grep "$PID" "Smoke chat session"

type_ax "$PID" "Search Library" "Smoke prompt"
wait_ax "$PID" "Smoke chat session" 10
shot_ax "$PID" "library-search-smoke"
assert_ax_grep "$PID" "1 failed"

type_ax "$PID" "Search Library" "failed"
wait_ax "$PID" "Smoke chat session" 10
shot_ax "$PID" "library-search-failed"
assert_ax_grep "$PID" "1 failed"

click_ax "$PID" "Pinned"
wait_ax "$PID" "Smoke chat session" 10
shot_ax "$PID" "library-pinned-filter"
assert_ax_grep "$PID" "Pinned"

click_ax "$PID" "Open chat Smoke chat session"
wait_ax "$PID" "Smoke prompt" 10
shot_ax "$PID" "library-session-open"
assert_ax_grep "$PID" "Smoke Model"
assert_ax_grep "$PID" "Smoke response"
assert_ax_grep "$PID" "Failed"
assert_ax_grep "$PID" "Copy"
assert_ax_grep "$PID" "Retry"
assert_ax_grep "$PID" "Retry response"
assert_ax_grep "$PID" "Session context"
assert_ax_grep "$PID" "Session brief"
assert_ax_grep "$PID" "Pinned in Library"
assert_ax_grep "$PID" "Saved with Smoke Model"
assert_ax_grep "$PID" "next replies use"
assert_ax_grep "$PID" "Reply model"
assert_ax_grep "$PID" "Saved model"
assert_ax_not_grep "$PID" "AITRADER/FLUX1-schnell-mlx-4bit"
click_ax "$PID" "Chat Model Picker"
wait_ax "$PID" "Chat Select Model Smoke-Switch-Model" 10
click_ax "$PID" "Chat Select Model Smoke-Switch-Model"
wait_ax "$PID" "Session model set: Smoke-Switch-Model" 10
assert_ax_grep "$PID" "Smoke-Switch-Model"
assert_ax_not_grep "$PID" "Saved with Smoke Model"
assert_ax_not_grep "$PID" "Saved model"
SELECTED_SESSION_AFTER_MODEL_SWITCH="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ "$SELECTED_SESSION_AFTER_MODEL_SWITCH" == "11111111-1111-1111-1111-111111111111" ]]; then
    note "Chat model switch preserved selected session"
else
    warn_or_fail "Chat model switch changed selected session: ${SELECTED_SESSION_AFTER_MODEL_SWITCH:-missing}"
fi
SMOKE_SESSION_MODEL_AFTER_SWITCH="$(chat_session_field "11111111-1111-1111-1111-111111111111" "modelName")"
SMOKE_SESSION_TURNS_AFTER_SWITCH="$(chat_session_turn_count "11111111-1111-1111-1111-111111111111")"
if [[ "$SMOKE_SESSION_MODEL_AFTER_SWITCH" == "Smoke-Switch-Model" && "$SMOKE_SESSION_TURNS_AFTER_SWITCH" == "2" ]]; then
    note "Chat model switch persisted active session model and preserved turns"
else
    warn_or_fail "Chat model switch persistence mismatch: model=${SMOKE_SESSION_MODEL_AFTER_SWITCH:-missing}, turns=${SMOKE_SESSION_TURNS_AFTER_SWITCH:-missing}"
fi
SMOKE_SESSION_SUMMARY_AFTER_SWITCH="$(chat_session_field "11111111-1111-1111-1111-111111111111" "summaryExportPath")"
if [[ -z "$SMOKE_SESSION_SUMMARY_AFTER_SWITCH" ]]; then
    note "Chat model switch cleared stale summary export state"
else
    warn_or_fail "Chat model switch left stale summary export path: $SMOKE_SESSION_SUMMARY_AFTER_SWITCH"
fi
shot_ax "$PID" "chat-model-switched-brief"
assert_ax_grep "$PID" "Explain failure next"
assert_ax_grep "$PID" "Explain failure"
click_ax "$PID" "Prompt starter Explain failure"
assert_ax_value "$PID" "Chat composer" "Explain why the last response failed and suggest the shortest fix."
click_ax "$PID" "Session quick prompt Explain failure"
assert_ax_value "$PID" "Chat composer" "Explain why the last response failed and suggest the shortest fix."
click_ax "$PID" "Keep moving Explain failure"
assert_ax_value "$PID" "Chat composer" "Explain why the last response failed and suggest the shortest fix."
shot_ax "$PID" "library-session-open-failed-recovery-prompt"
shot_ax "$PID" "library-session-open-failed-brief"

SELECTED_SESSION_AFTER_OPEN="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ "$SELECTED_SESSION_AFTER_OPEN" == "11111111-1111-1111-1111-111111111111" ]]; then
    note "Selected chat persisted after Library open"
else
    warn_or_fail "Library open did not persist selected chat session"
fi

note "Relaunching to verify selected chat persistence"
kill -TERM "$PID" 2>/dev/null || true
sleep 1
"$MLX_BIN" -ApplePersistenceIgnoreState YES >>"$LOG" 2>&1 &
PID="$!"
for _ in {1..60}; do
    if ps -p "$PID" >/dev/null; then
        break
    fi
    sleep 0.5
done
wait_ax "$PID" "Smoke prompt" 20
shot_ax "$PID" "chat-after-relaunch"
assert_ax_grep "$PID" "Smoke chat session"
assert_ax_grep "$PID" "Smoke-Switch-Model"
assert_ax_grep "$PID" "Smoke response"
assert_ax_grep "$PID" "Failed"
assert_ax_grep "$PID" "Retry response"
assert_ax_grep "$PID" "Session context"

click_ax "$PID" "Retry response"
for _ in {1..25}; do
    [[ -f "$SMOKE_CHAT_RETRY_DRAFT_LOG" ]] \
        && grep -q "11111111-1111-1111-1111-111111111111|turns=2|failed=0|streaming=1|last=streaming" "$SMOKE_CHAT_RETRY_DRAFT_LOG" \
        && break
    sleep 0.2
done
if [[ -f "$SMOKE_CHAT_RETRY_DRAFT_LOG" ]] \
    && grep -q "11111111-1111-1111-1111-111111111111|turns=2|failed=0|streaming=1|last=streaming" "$SMOKE_CHAT_RETRY_DRAFT_LOG"; then
    note "Retry response replaced failed turn with a streaming draft"
else
    warn_or_fail "Retry response did not persist expected retry draft"
fi
RETRY_UI_STATE="unknown"
for _ in {1..24}; do
    if ax_grep_contains "$PID" "Clean session" && ! ax_grep_contains "$PID" "Explain failure next"; then
        RETRY_UI_STATE="streaming"
        break
    fi
    if ax_grep_contains "$PID" "Retry response" && ax_grep_contains "$PID" "Explain failure next"; then
        RETRY_UI_STATE="refailed"
        break
    fi
    sleep 0.25
done
shot_ax "$PID" "chat-retry-response-draft"
if [[ "$RETRY_UI_STATE" == "streaming" ]]; then
    assert_ax_grep "$PID" "Clean session"
    assert_ax_grep "$PID" "Ready to continue"
    assert_ax_grep "$PID" "Branch idea"
    assert_ax_grep "$PID" "Make practical"
    assert_ax_not_grep "$PID" "Explain failure next"
    assert_ax_not_grep "$PID" "Explain failure"
elif [[ "$RETRY_UI_STATE" == "refailed" ]]; then
    note "Retry response re-failed quickly after clean draft; recovery affordances remain visible"
    assert_ax_grep "$PID" "Retry response"
    assert_ax_grep "$PID" "Explain failure next"
    assert_ax_grep "$PID" "Explain failure"
else
    warn_or_fail "Retry response did not settle into streaming or recoverable failed UI"
fi

RETRY_STOP_TREE="$REPORT_DIR/mlx-studio-smoke-$TS-chat-retry-stop-tree.txt"
if "$AX_BIN" dump "$PID" >"$RETRY_STOP_TREE" 2>&1 && grep -q 'AXButton.*desc="Stop"' "$RETRY_STOP_TREE"; then
    click_ax "$PID" "Stop"
    RETRY_STOP_CLEARED=0
    for _ in {1..20}; do
        "$AX_BIN" dump "$PID" >"$RETRY_STOP_TREE" 2>&1 || true
        if ! grep -q 'AXButton.*desc="Stop"' "$RETRY_STOP_TREE"; then
            RETRY_STOP_CLEARED=1
            break
        fi
        sleep 0.5
    done
    if [[ "$RETRY_STOP_CLEARED" == "1" ]]; then
        note "Retry response exposed Stop before New Chat"
    else
        warn_or_fail "Retry response Stop did not clear before New Chat"
    fi
else
    note "Retry response stream finished before Stop cleanup"
fi

key_ax "$PID" "n" "command"
wait_ax "$PID" "Start a local conversation" 10
shot_ax "$PID" "chat-new-draft"
assert_ax_grep "$PID" "Start a local conversation"
assert_ax_grep "$PID" "2 saved chat sessions"
assert_ax_grep "$PID" "Recent sessions"
SELECTED_SESSION_AFTER_NEW="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ -z "$SELECTED_SESSION_AFTER_NEW" ]]; then
    note "New Chat cleared selected saved session"
else
    warn_or_fail "New Chat left selected saved session: $SELECTED_SESSION_AFTER_NEW"
fi
key_ax "$PID" "t" "command,shift"
wait_ax "$PID" "Smoke prompt" 10
shot_ax "$PID" "chat-reopen-last-closed"
assert_ax_grep "$PID" "Smoke chat session"
assert_ax_grep "$PID" "Smoke-Switch-Model"
SELECTED_SESSION_AFTER_REOPEN="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ "$SELECTED_SESSION_AFTER_REOPEN" == "11111111-1111-1111-1111-111111111111" ]]; then
    note "Reopen Last Closed Chat restored selected Studio chat session"
else
    warn_or_fail "Reopen Last Closed Chat selected unexpected session: ${SELECTED_SESSION_AFTER_REOPEN:-missing}"
fi
key_ax "$PID" "n" "command"
wait_ax "$PID" "Start a local conversation" 10
SELECTED_SESSION_AFTER_REOPEN_NEW="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ -z "$SELECTED_SESSION_AFTER_REOPEN_NEW" ]]; then
    note "New Chat keyboard shortcut cleared reopened Studio chat session"
else
    warn_or_fail "New Chat after reopen left selected session: $SELECTED_SESSION_AFTER_REOPEN_NEW"
fi

click_ax "$PID" "Library"
wait_ax "$PID" "Search Library" 10
click_ax "$PID" "Chats"
type_ax "$PID" "Search Library" "second smoke"
wait_ax "$PID" "Renamed smoke session" 10
click_ax "$PID" "Delete chat Renamed smoke session"
wait_ax "$PID" "Delete chat session?" 10
assert_ax_grep "$PID" "This deletes the saved prompts"
assert_ax_grep "$PID" "Model files and image outputs are not deleted."
shot_ax "$PID" "library-chat-delete-confirmation"
if defaults export "$BUNDLE_ID" "$CHAT_DEFAULTS_PLIST" >/dev/null 2>&1; then
    CHAT_SESSIONS_JSON="$(/usr/libexec/PlistBuddy -c 'Print :mlxstudio.chat.sessions' "$CHAT_DEFAULTS_PLIST" 2>/dev/null || true)"
else
    CHAT_SESSIONS_JSON=""
fi
if [[ "$CHAT_SESSIONS_JSON" == *"Renamed smoke session"* ]]; then
    note "Delete chat required confirmation before removing persisted session"
else
    warn_or_fail "Delete chat removed session before confirmation"
fi
click_ax "$PID" "Confirm delete chat Renamed smoke session"
wait_ax "$PID" "No matching chat sessions" 10
shot_ax "$PID" "library-chat-deleted"
if defaults export "$BUNDLE_ID" "$CHAT_DEFAULTS_PLIST" >/dev/null 2>&1; then
    CHAT_SESSIONS_JSON="$(/usr/libexec/PlistBuddy -c 'Print :mlxstudio.chat.sessions' "$CHAT_DEFAULTS_PLIST" 2>/dev/null || true)"
else
    CHAT_SESSIONS_JSON=""
fi
if [[ "$CHAT_SESSIONS_JSON" != *"Renamed smoke session"* && "$CHAT_SESSIONS_JSON" == *"Smoke chat session"* ]]; then
    note "Deleted non-selected chat session from persisted history"
else
    warn_or_fail "Delete chat did not update persisted session history"
fi
SELECTED_SESSION_AFTER_CHAT_DELETE="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ -z "$SELECTED_SESSION_AFTER_CHAT_DELETE" ]]; then
    note "Deleting non-selected chat preserved draft selection"
else
    warn_or_fail "Delete chat reselected a saved session unexpectedly: $SELECTED_SESSION_AFTER_CHAT_DELETE"
fi
type_ax "$PID" "Search Library" "Smoke prompt"
wait_ax "$PID" "Smoke chat session" 10
shot_ax "$PID" "library-chat-delete-survivor"
click_ax "$PID" "Delete chat Smoke chat session"
wait_ax "$PID" "Delete chat session?" 10
assert_ax_grep "$PID" "Model files and image outputs are not deleted."
click_ax "$PID" "Confirm delete chat Smoke chat session"
wait_ax "$PID" "No matching chat sessions" 10
shot_ax "$PID" "library-remaining-chat-deleted"
if defaults export "$BUNDLE_ID" "$CHAT_DEFAULTS_PLIST" >/dev/null 2>&1; then
    CHAT_SESSIONS_JSON="$(/usr/libexec/PlistBuddy -c 'Print :mlxstudio.chat.sessions' "$CHAT_DEFAULTS_PLIST" 2>/dev/null || true)"
else
    CHAT_SESSIONS_JSON=""
fi
if [[ "$CHAT_SESSIONS_JSON" == "[]" ]]; then
    note "Deleted remaining chat session from persisted history"
else
    warn_or_fail "Delete remaining chat left persisted sessions: $CHAT_SESSIONS_JSON"
fi
SELECTED_SESSION_AFTER_SELECTED_DELETE="$(defaults read "$BUNDLE_ID" mlxstudio.chat.selectedSessionID 2>/dev/null || true)"
if [[ -z "$SELECTED_SESSION_AFTER_SELECTED_DELETE" ]]; then
    note "Deleting remaining chat kept draft selection empty"
else
    warn_or_fail "Delete remaining chat left selected session: $SELECTED_SESSION_AFTER_SELECTED_DELETE"
fi

if "$AX_BIN" grep "$PID" "Server" >"$REPORT_DIR/grep-${TS}-beginner-server.txt" 2>&1 \
    && grep -qi "Server" "$REPORT_DIR/grep-${TS}-beginner-server.txt"; then
    warn_or_fail "Server appeared in Beginner mode"
else
    note "Beginner nav hides Server"
fi

click_ax "$PID" "Advanced"
wait_ax "$PID" "Server" 10
shot_ax "$PID" "advanced"
assert_ax_grep "$PID" "Server"
assert_ax_grep "$PID" "Advanced Models"
assert_ax_grep "$PID" "Diagnostics"
click_ax "$PID" "Server"
wait_ax "$PID" "Control Plane" 10
shot_ax "$PID" "server"
assert_ax_grep "$PID" "API State"
assert_ax_grep "$PID" "Binding"
assert_ax_grep "$PID" "Route Surface"
assert_ax_grep "$PID" "Model Context"
assert_ax_grep "$PID" "$SMOKE_DEFAULT_CHAT_NAME"
assert_ax_grep "$PID" "Chat-capable server model"
assert_ax_not_grep "$PID" "image-only"
assert_ax_grep "$PID" "Control Plane"
assert_ax_grep "$PID" "Operator Checklist"
assert_ax_grep "$PID" "Traffic"
assert_ax_grep "$PID" "Last operation"
assert_ax_grep "$PID" "Start/stop result"
SERVER_EXPECTED_STATE="unknown"
if ax_grep_contains "$PID" "Accepting requests"; then
    SERVER_EXPECTED_STATE="running"
    assert_ax_grep "$PID" "Accepting requests"
    assert_ax_grep "$PID" "Start Server unavailable: Server is already running"
else
    SERVER_EXPECTED_STATE="stopped"
    assert_ax_grep "$PID" "Stopped"
    assert_ax_grep "$PID" "Standby"
    assert_ax_grep "$PID" "Start Server"
    assert_ax_grep "$PID" "Stop unavailable: Server is already stopped"
    note "Server control plane honestly stayed stopped until Start Server is pressed"
fi
assert_ax_grep "$PID" "Runtime Contract"
assert_ax_grep "$PID" "OpenAI-compatible loopback service"
assert_ax_grep "$PID" "Client Handshake"
assert_ax_not_grep "$PID" "8,000"
assert_ax_grep "$PID" "Copy cURL"
assert_ax_grep "$PID" "Health probe"
assert_ax_grep "$PID" "Copy Health"
assert_ax_grep "$PID" "Server Copy Health Probe at http://127.0.0.1:8000"
assert_ax_grep "$PID" "Confirm 127.0.0.1:8000"
assert_ax_grep "$PID" "Chat completion"
assert_ax_grep "$PID" "POST /v1/chat/completions"
assert_ax_grep "$PID" "Uses $SMOKE_DEFAULT_CHAT_REPO"
assert_ax_grep "$PID" "Auth Mode"
assert_ax_grep "$PID" "Route Coverage"
assert_ax_grep "$PID" "Copy Endpoint"
assert_ax_grep "$PID" "Server Copy cURL for $SMOKE_DEFAULT_CHAT_REPO at http://127.0.0.1:8000"
click_ax "$PID" "Server runtime Copy Endpoint"
COPIED_SERVER_ENDPOINT="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_SERVER_ENDPOINT" == "http://127.0.0.1:8000" ]]; then
    note "Copied Server endpoint to clipboard"
else
    warn_or_fail "Copy Endpoint wrote unexpected clipboard text"
fi
click_ax "$PID" "Server Copy Health Probe at http://127.0.0.1:8000"
COPIED_SERVER_HEALTH="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_SERVER_HEALTH" == "curl http://127.0.0.1:8000/health" ]]; then
    note "Copied Server health probe to clipboard"
else
    warn_or_fail "Copy Health wrote unexpected clipboard text"
fi
click_ax "$PID" "Server Copy cURL for $SMOKE_DEFAULT_CHAT_REPO at http://127.0.0.1:8000"
COPIED_SERVER_CURL="$(/usr/bin/pbpaste | tr -d '\r')"
export COPIED_SERVER_CURL
export SMOKE_DEFAULT_CHAT_REPO
if python3 - <<'PY'
import json
import os
import sys

cmd = os.environ.get("COPIED_SERVER_CURL", "")
required = [
    "curl http://127.0.0.1:8000/v1/chat/completions",
    "-H 'Content-Type: application/json'",
    "-d '",
]
if any(part not in cmd for part in required):
    sys.exit(1)
if "Authorization: Bearer" in cmd:
    sys.exit(2)
marker = "-d '"
start = cmd.find(marker)
if start < 0 or not cmd.endswith("'"):
    sys.exit(3)
body = cmd[start + len(marker):-1]
payload = json.loads(body)
if payload.get("model") != os.environ["SMOKE_DEFAULT_CHAT_REPO"]:
    sys.exit(4)
if payload.get("stream") is not False:
    sys.exit(5)
messages = payload.get("messages")
if messages != [{"content": "Say ready in one sentence.", "role": "user"}]:
    sys.exit(6)
PY
then
    note "Copied Server cURL to clipboard for active model and endpoint"
else
    warn_or_fail "Copy cURL wrote unexpected clipboard text"
fi

SERVER_START_ATTEMPT_RESULT="not-attempted"
if [[ "$SERVER_EXPECTED_STATE" == "stopped" ]]; then
    click_ax "$PID" "Start Server"
    SERVER_START_ATTEMPT_RESULT="pending"
    for _ in {1..180}; do
        if ax_grep_contains "$PID" "Accepting requests"; then
            SERVER_START_ATTEMPT_RESULT="running"
            break
        fi
        if ax_grep_contains "$PID" "Server did not start"; then
            SERVER_START_ATTEMPT_RESULT="failed"
            break
        fi
        sleep 0.5
    done
    case "$SERVER_START_ATTEMPT_RESULT" in
        running)
            SERVER_EXPECTED_STATE="running"
            assert_ax_grep "$PID" "Accepting requests"
            assert_ax_grep "$PID" "Start Server unavailable: Server is already running"
            if curl -fsS --max-time 10 "http://127.0.0.1:8000/health" >"$REPORT_DIR/server-health-$TS.json" 2>"$REPORT_DIR/server-health-$TS.err"; then
                note "Server Start reached a live health endpoint on port 8000"
            else
                warn_or_fail "Server Start reached running UI state but health probe failed"
            fi
            shot_ax "$PID" "server-started"
            ;;
        failed)
            SERVER_EXPECTED_STATE="stopped"
            assert_ax_grep "$PID" "Server did not start"
            assert_ax_grep "$PID" "Standby"
            assert_ax_grep "$PID" "Start Server"
            shot_ax "$PID" "server-start-failed"
            click_ax "$PID" "Stop"
            wait_ax "$PID" "Stopped" 30
            assert_ax_grep "$PID" "Stop unavailable: Server is already stopped"
            shot_ax "$PID" "server-start-failed-reset"
            note "Server Start failure stayed visible and reset to stopped without a listener"
            ;;
        *)
            warn_or_fail "Server Start did not reach running or a visible failure state"
            ;;
    esac
fi

click_ax "$PID" "Advanced Models"
wait_ax "$PID" "Model Inspector" 10
shot_ax "$PID" "advanced-models"
assert_ax_grep "$PID" "Selected Model"
assert_ax_grep "$PID" "Local Size"
assert_ax_grep "$PID" "Inspection"
assert_ax_grep "$PID" "Job Queue"
assert_ax_grep "$PID" "Run Inspect"
assert_ax_grep "$PID" "Copy Path"
assert_ax_grep "$PID" "Operator sequence"
assert_ax_grep "$PID" "Inspect files"
assert_ax_grep "$PID" "Validation gate"
assert_ax_grep "$PID" "Benchmark path"
assert_ax_grep "$PID" "Advanced Models Validate $SMOKE_DEFAULT_CHAT_REPO"
assert_ax_grep "$PID" "Report handoff"
assert_ax_grep "$PID" "Run Inspect before report export"
assert_ax_grep "$PID" "Advanced Models Export Report unavailable: Run Inspect before report export"
assert_ax_grep "$PID" "Preflight inspector"
assert_ax_grep "$PID" "Local artifacts before a deep inspect"
assert_ax_grep "$PID" "Artifact Ledger"
assert_ax_grep "$PID" "Evidence"
assert_ax_grep "$PID" "Operator signal"
assert_ax_grep "$PID" "Tokenizer"
assert_ax_grep "$PID" "Weights"
assert_ax_grep "$PID" "Next operation"
ADVANCED_BENCHMARK_AVAILABLE=0
if ax_grep_contains "$PID" "Advanced Models Benchmark $SMOKE_DEFAULT_CHAT_REPO"; then
    ADVANCED_BENCHMARK_AVAILABLE=1
    assert_ax_grep "$PID" "Runtime ready"
    assert_ax_grep "$PID" "Benchmark candidate"
    assert_ax_grep "$PID" "Advanced Models Benchmark $SMOKE_DEFAULT_CHAT_REPO"
else
    assert_ax_grep "$PID" "Not loaded"
    assert_ax_grep "$PID" "Load model before benchmark"
    assert_ax_grep "$PID" "Advanced Models Benchmark unavailable: Load model before benchmark"
    note "Advanced Models benchmark honestly gated until the selected text model is loaded"
fi
click_ax "$PID" "Advanced Models Validate $SMOKE_DEFAULT_CHAT_REPO"
wait_ax "$PID" "Validation passed" 15
assert_ax_grep "$PID" "Validate:"
assert_ax_grep "$PID" "Completed"
if [[ "$ADVANCED_BENCHMARK_AVAILABLE" == "1" ]]; then
    ADVANCED_BENCHMARK_MARKER="$REPORT_DIR/advanced-model-benchmark-marker-$TS"
    /usr/bin/touch "$ADVANCED_BENCHMARK_MARKER"
    click_ax "$PID" "Advanced Models Benchmark $SMOKE_DEFAULT_CHAT_REPO"
    ADVANCED_BENCHMARK_PATH=""
    for _ in {1..360}; do
        ADVANCED_BENCHMARK_PATH="$(/usr/bin/find "$HOME/Library/Application Support/MLX Studio/Reports" -type f -name '*-decode256-benchmark.json' -newer "$ADVANCED_BENCHMARK_MARKER" -print 2>/dev/null | /usr/bin/head -1 || true)"
        if [[ -n "$ADVANCED_BENCHMARK_PATH" ]]; then
            break
        fi
        sleep 0.5
    done
    if [[ -n "$ADVANCED_BENCHMARK_PATH" ]] \
        && ADVANCED_BENCHMARK_PATH="$ADVANCED_BENCHMARK_PATH" python3 - <<'PY'
import json
import os
import sys

with open(os.environ["ADVANCED_BENCHMARK_PATH"], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
ok = payload.get("suite") == "decode256"
ok = ok and os.environ["SMOKE_DEFAULT_CHAT_REPO"] in str(payload.get("modelId", ""))
ok = ok and float(payload.get("tokensPerSec") or 0) > 0
sys.exit(0 if ok else 1)
PY
    then
        note "Advanced Models Benchmark wrote decode256 report: $ADVANCED_BENCHMARK_PATH"
    else
        warn_or_fail "Advanced Models Benchmark did not write expected decode256 report"
    fi
    wait_ax "$PID" "Advanced Models Copy Benchmark Output" 10
    click_ax "$PID" "Advanced Models Copy Benchmark Output"
    COPIED_ADVANCED_BENCHMARK_PATH="$(/usr/bin/pbpaste | tr -d '\r')"
    if [[ "$COPIED_ADVANCED_BENCHMARK_PATH" == "$ADVANCED_BENCHMARK_PATH" ]]; then
        note "Copied Advanced Models benchmark output path"
    else
        warn_or_fail "Advanced Models Copy Benchmark Output wrote unexpected clipboard text"
    fi
else
    assert_ax_grep "$PID" "Advanced Models Benchmark unavailable: Load model before benchmark"
    assert_ax_not_grep "$PID" "Advanced Models Copy Benchmark Output"
fi
click_ax "$PID" "Advanced Models Run Inspect"
wait_ax "$PID" "Inspection ready" 15
assert_ax_grep "$PID" "Inspect:"
assert_ax_grep "$PID" "Inspection completed"
assert_ax_grep "$PID" "Export Report"
assert_ax_grep "$PID" "Ready to export"
if [[ "$ADVANCED_BENCHMARK_AVAILABLE" == "1" ]]; then
    assert_ax_grep "$PID" "Runtime ready"
    assert_ax_grep "$PID" "Benchmark candidate"
    assert_ax_grep "$PID" "Advanced Models Benchmark $SMOKE_DEFAULT_CHAT_REPO"
else
    assert_ax_grep "$PID" "Load model before benchmark"
    assert_ax_grep "$PID" "Advanced Models Benchmark unavailable: Load model before benchmark"
fi
assert_ax_grep "$PID" "Advanced Models Export Report for $SMOKE_DEFAULT_CHAT_REPO"
click_ax "$PID" "Advanced Models Copy Path"
COPIED_ADVANCED_MODEL_PATH="$(/usr/bin/pbpaste | tr -d '\r')"
export COPIED_ADVANCED_MODEL_PATH
if [[ -d "$COPIED_ADVANCED_MODEL_PATH" ]] \
    && [[ -f "$COPIED_ADVANCED_MODEL_PATH/config.json" || -f "$COPIED_ADVANCED_MODEL_PATH/model_index.json" ]]
then
    note "Copied Advanced Models model directory to clipboard: $COPIED_ADVANCED_MODEL_PATH"
else
    warn_or_fail "Advanced Models Copy Path wrote unexpected clipboard text"
fi
ADVANCED_REPORT_MARKER="$REPORT_DIR/advanced-model-report-marker-$TS"
/usr/bin/touch "$ADVANCED_REPORT_MARKER"
click_ax "$PID" "Advanced Models Export Report for $SMOKE_DEFAULT_CHAT_REPO"
wait_ax "$PID" "Report exported" 15
ADVANCED_REPORT_PATH=""
for _ in {1..20}; do
    ADVANCED_REPORT_PATH="$(/usr/bin/find "$HOME/Library/Application Support/MLX Studio/Reports" -type f -name '*-inspection.json' -newer "$ADVANCED_REPORT_MARKER" -print 2>/dev/null | /usr/bin/head -1 || true)"
    if [[ -n "$ADVANCED_REPORT_PATH" ]]; then
        break
    fi
    sleep 0.5
done
export ADVANCED_REPORT_PATH
if [[ -f "$ADVANCED_REPORT_PATH" ]] && /usr/bin/python3 - <<'PY'
import json
import os
import sys

path = os.environ.get("ADVANCED_REPORT_PATH", "")
try:
    with open(path, "r", encoding="utf-8") as handle:
        report = json.load(handle)
except Exception:
    sys.exit(1)

model = report.get("model") or {}
ok = bool(model.get("displayName"))
ok = ok and isinstance(report.get("sizeBytes"), int)
ok = ok and isinstance(report.get("configKeys"), list)
ok = ok and isinstance(report.get("notes"), list)
clipboard_path = os.environ.get("COPIED_ADVANCED_MODEL_PATH", "").rstrip("/")
model_url = str(model.get("localURL") or "")
if model_url.startswith("file://"):
    from urllib.parse import unquote, urlparse
    report_path = unquote(urlparse(model_url).path).rstrip("/")
else:
    report_path = model_url.rstrip("/")
ok = ok and bool(clipboard_path) and os.path.isdir(clipboard_path)
ok = ok and report_path == clipboard_path
sys.exit(0 if ok else 1)
PY
then
    note "Exported Advanced Models inspection report matching copied path: $ADVANCED_REPORT_PATH"
else
    warn_or_fail "Advanced Models Export Report did not write expected JSON for copied model path"
fi
assert_ax_grep "$PID" "Advanced Models Copy Report Output for $SMOKE_DEFAULT_CHAT_REPO"
click_ax "$PID" "Advanced Models Copy Report Output"
COPIED_ADVANCED_REPORT_PATH="$(/usr/bin/pbpaste | tr -d '\r')"
if [[ "$COPIED_ADVANCED_REPORT_PATH" == "$ADVANCED_REPORT_PATH" ]]; then
    note "Copied Advanced Models report output path"
else
    warn_or_fail "Advanced Models Copy Report Output wrote unexpected clipboard text"
fi
shot_ax "$PID" "advanced-models-after-inspect"
click_ax "$PID" "Diagnostics"
wait_ax "$PID" "Recent Errors" 10
shot_ax "$PID" "diagnostics"
assert_ax_grep "$PID" "Engine State"
assert_ax_grep "$PID" "Issue Triage"
assert_ax_grep "$PID" "Runtime Pulse"
assert_ax_grep "$PID" "Recent Errors"
assert_ax_grep "$PID" "Inspector Logs"
assert_ax_grep "$PID" "Incident Brief"
assert_ax_grep "$PID" "Copy Brief"
assert_ax_grep "$PID" "Recovery Path"
assert_ax_grep "$PID" "Diagnostics Copy Brief for Chat Stream Smoke diagnostic issue"
assert_ax_grep "$PID" "Diagnostics Copy Recovery Path for Chat Stream Smoke diagnostic issue"
assert_ax_grep "$PID" "Confirm impact"
assert_ax_grep "$PID" "Execute move"
assert_ax_grep "$PID" "Impact"
assert_ax_grep "$PID" "Evidence"
assert_ax_grep "$PID" "Next Move"
assert_ax_grep "$PID" "Freshness"
assert_ax_grep "$PID" "Fresh"
assert_ax_grep "$PID" "Stale"
assert_ax_grep "$PID" "Workflow blocked"
assert_ax_grep "$PID" "Retry or inspect logs"
assert_ax_grep "$PID" "Manual only"
assert_ax_grep "$PID" "Smoke diagnostic issue"
assert_ax_grep "$PID" "Chat Stream"
assert_ax_grep "$PID" "Smoke stream failed for diagnostics"
DIAGNOSTICS_OPEN_COUNT=2
DIAGNOSTICS_CLEAR_LABEL="Diagnostics Clear 2 Issues"
if ax_grep_contains "$PID" "4 open"; then
    DIAGNOSTICS_OPEN_COUNT=4
    DIAGNOSTICS_CLEAR_LABEL="Diagnostics Clear 4 Issues"
    note "Diagnostics includes runtime chat failure, server start failure, and seeded issues"
    assert_ax_grep "$PID" "4 open"
    assert_ax_grep "$PID" "3 errors - 1 warnings - 0 info"
    assert_ax_grep "$PID" "Server start failed"
    assert_ax_grep "$PID" "Server did not start"
elif ax_grep_contains "$PID" "3 open"; then
    DIAGNOSTICS_OPEN_COUNT=3
    DIAGNOSTICS_CLEAR_LABEL="Diagnostics Clear 3 Issues"
    note "Diagnostics includes runtime chat failure plus seeded issues"
    assert_ax_grep "$PID" "3 open"
    assert_ax_grep "$PID" "2 errors - 1 warnings - 0 info"
else
    assert_ax_grep "$PID" "2 open"
    assert_ax_grep "$PID" "1 errors - 1 warnings - 0 info"
fi
export DIAGNOSTICS_OPEN_COUNT
assert_ax_grep "$PID" "$DIAGNOSTICS_CLEAR_LABEL"
assert_ax_grep "$PID" "Newest first"
assert_ax_grep "$PID" "Old server binding issue"
assert_ax_grep "$PID" "Server could not bind"
assert_ax_grep "$PID" "Server"
DIAGNOSTICS_REDACTED_TOKEN_GREP="$REPORT_DIR/grep-${TS}-diagnostics-redacted-token.txt"
if "$AX_BIN" grep "$PID" "token=[redacted]" >"$DIAGNOSTICS_REDACTED_TOKEN_GREP" 2>&1 \
    && grep -Fqi "token=[redacted]" "$DIAGNOSTICS_REDACTED_TOKEN_GREP"; then
    note "Diagnostics shows redacted token"
else
    warn_or_fail "Diagnostics did not show redacted token"
fi
for raw_secret in \
    "hf_smokesecret123456" \
    "smoke-secret-123456" \
    "hf_oldserversecret123456" \
    "old-server-secret-123456"
do
    if "$AX_BIN" grep "$PID" "$raw_secret" >"$REPORT_DIR/grep-${TS}-diagnostics-raw-$(echo "$raw_secret" | tr -c 'A-Za-z0-9' '_').txt" 2>&1 \
        && grep -qi "$raw_secret" "$REPORT_DIR/grep-${TS}-diagnostics-raw-$(echo "$raw_secret" | tr -c 'A-Za-z0-9' '_').txt"; then
        warn_or_fail "Diagnostics exposed raw secret in accessibility tree"
    else
        note "Diagnostics redacted raw secret from accessibility tree: $raw_secret"
    fi
done
click_ax "$PID" "Diagnostics Copy Brief for Chat Stream Smoke diagnostic issue"
COPIED_DIAGNOSTICS_BRIEF="$(/usr/bin/pbpaste | tr -d '\r')"
export COPIED_DIAGNOSTICS_BRIEF
if /usr/bin/python3 - <<'PY'
import os
import sys

brief = os.environ.get("COPIED_DIAGNOSTICS_BRIEF", "")
required = [
    "MLX Studio Diagnostics Brief",
    "Incident: Smoke diagnostic issue",
    "Severity: error",
    "Source: Chat Stream",
    "Recorded:",
    "Freshness: Fresh -",
    "Message: Smoke stream failed for diagnostics token=[redacted]",
    "Impact: Workflow blocked",
    "Evidence: Smoke Model at ~/private/model Authorization: Bearer [redacted]",
    "Next move: Retry or inspect logs",
    "Recovery action: Manual only - use Chat Retry; no prompt is resent here",
    f"Open issues: {os.environ.get('DIAGNOSTICS_OPEN_COUNT', '')}",
]
for item in required:
    if item not in brief:
        sys.exit(1)

for forbidden in [
    "/Users/hermes",
    "hf_smokesecret123456",
    "smoke-secret-123456",
    "hf_oldserversecret123456",
    "old-server-secret-123456",
]:
    if forbidden in brief:
        sys.exit(1)

sys.exit(0)
PY
then
    note "Copied redacted Diagnostics brief to clipboard"
else
    warn_or_fail "Copy Brief wrote unexpected diagnostics payload"
fi
click_ax "$PID" "Diagnostics Copy Recovery Path for Chat Stream Smoke diagnostic issue"
COPIED_RECOVERY_PATH="$(/usr/bin/pbpaste | tr -d '\r')"
export COPIED_RECOVERY_PATH
if /usr/bin/python3 - <<'PY'
import os
import sys

path = os.environ.get("COPIED_RECOVERY_PATH", "")
required = [
    "MLX Studio Recovery Path",
    "Incident: Smoke diagnostic issue",
    "Source: Chat Stream",
    "Recorded:",
    "Freshness: Fresh -",
    "1. Confirm impact: Workflow blocked (Gate retry or continue)",
    "2. Inspect evidence: Smoke Model at ~/private/model Authorization: Bearer [redacted] (Match source against logs)",
    "3. Execute move: Retry or inspect logs (Manual only - use Chat Retry; no prompt is resent here)",
]
for item in required:
    if item not in path:
        sys.exit(1)

for forbidden in [
    "/Users/hermes",
    "hf_smokesecret123456",
    "smoke-secret-123456",
    "hf_oldserversecret123456",
    "old-server-secret-123456",
]:
    if forbidden in path:
        sys.exit(1)

sys.exit(0)
PY
then
    note "Copied redacted Diagnostics recovery path to clipboard"
else
    warn_or_fail "Copy Path wrote unexpected diagnostics payload"
fi
click_ax "$PID" "$DIAGNOSTICS_CLEAR_LABEL"
wait_ax "$PID" "No recent issues" 10
shot_ax "$PID" "diagnostics-cleared"
assert_ax_grep "$PID" "0 open"
assert_ax_grep "$PID" "0 errors - 0 warnings - 0 info"
assert_ax_grep "$PID" "No recent issues"
assert_ax_grep "$PID" "Diagnostics Clear Issues unavailable: No open issues"

click_ax "$PID" "Server"
wait_ax "$PID" "Control Plane" 10
if [[ "$SERVER_EXPECTED_STATE" == "running" ]]; then
    click_ax "$PID" "Stop"
    wait_ax "$PID" "Stopped" 30
else
    assert_ax_grep "$PID" "Stop unavailable: Server is already stopped"
fi
assert_ax_grep "$PID" "Standby"
assert_ax_grep "$PID" "Stop unavailable: Server is already stopped"
shot_ax "$PID" "server-stopped"
SERVER_LISTENER_CLEARED=0
for _ in {1..20}; do
    if ! lsof -nP -iTCP:8000 -sTCP:LISTEN >/dev/null 2>&1; then
        SERVER_LISTENER_CLEARED=1
        break
    fi
    sleep 0.5
done
if [[ "$SERVER_LISTENER_CLEARED" == "1" ]]; then
    if [[ "$SERVER_EXPECTED_STATE" == "running" ]]; then
        note "Server Stop cleared listener on port 8000"
    else
        note "Server stopped state left no listener on port 8000"
    fi
else
    if [[ "$SERVER_EXPECTED_STATE" == "running" ]]; then
        warn_or_fail "Server Stop left listener on port 8000"
    else
        warn_or_fail "Server stopped state still had listener on port 8000"
    fi
fi

SHOT="$REPORT_DIR/mlx-studio-smoke-$TS.png"
"$AX_BIN" shot "$PID" "$SHOT" >>"$LOG" 2>&1 || true
note "Screenshot attempt: $SHOT"

note "Stopping app"
kill -TERM "$PID" 2>/dev/null || true
sleep 1
pkill -x MLXStudio 2>/dev/null || true

note "Smoke complete"
