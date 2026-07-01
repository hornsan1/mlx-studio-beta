#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

REPORT_DIR="${MLX_STUDIO_CHAT_E2E_REPORT_DIR:-Tests/e2e/reports}"
mkdir -p "$REPORT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$REPORT_DIR/mlx-studio-chat-smoke-$STAMP-$$.log"
JSON_REPORT="$REPORT_DIR/mlx-studio-chat-smoke-$STAMP-$$.json"

note() {
  printf '[chat-smoke] %s\n' "$*" | tee -a "$LOG" >&2
}

resolve_hf_cache_path() {
  local repo="$1"
  local slug="models--${repo//\//--}"
  local snapshots="$HOME/.cache/huggingface/hub/$slug/snapshots"

  if [[ -d "$snapshots/main" ]]; then
    printf '%s\n' "$snapshots/main"
    return 0
  fi

  if [[ -d "$snapshots" ]]; then
    local latest=""
    latest="$(find "$snapshots" -mindepth 1 -maxdepth 1 -type d -print | sort | tail -1 || true)"
    if [[ -n "$latest" ]]; then
      printf '%s\n' "$latest"
      return 0
    fi
  fi

  return 1
}

resolve_cli() {
  local cli="${VMLXCTL_BIN:-}"
  if [[ -n "$cli" && -x "$cli" ]]; then
    printf '%s\n' "$cli"
    return
  fi

  if [[ -x ".build/arm64-apple-macosx/release/vmlxctl" ]]; then
    cli=".build/arm64-apple-macosx/release/vmlxctl"
  elif [[ -x ".build/release/vmlxctl" ]]; then
    cli=".build/release/vmlxctl"
  fi

  if [[ -z "$cli" ]] \
    || find "$REPO_ROOT/Sources" "$REPO_ROOT/Package.swift" -newer "$cli" -print -quit | grep -q .; then
    note "Building vmlxctl release binary"
    swift build -c release --product vmlxctl 2>&1 | tee -a "$LOG" >&2
    if [[ -x ".build/arm64-apple-macosx/release/vmlxctl" ]]; then
      cli=".build/arm64-apple-macosx/release/vmlxctl"
    else
      cli=".build/release/vmlxctl"
    fi
  fi

  printf '%s\n' "$cli"
}

resolve_model_path() {
  local model_path="${MLX_STUDIO_E2E_MODEL_PATH:-}"
  local live_download="${MLX_STUDIO_E2E_LIVE_DOWNLOAD:-0}"
  local repo="${MLX_STUDIO_E2E_REPO:-LiquidAI/LFM2.5-350M}"
  local cli="$1"

  if [[ -n "$model_path" ]]; then
    printf '%s\n' "$model_path"
    return
  fi

  if [[ "$live_download" == "1" ]]; then
    note "Downloading live HF model $repo"
    local pull_log="$REPORT_DIR/mlx-studio-chat-pull-$STAMP-$$.log"
    set +e
    "$cli" pull "$repo" 2>&1 | tee "$pull_log" | tee -a "$LOG" >&2
    local pull_status=${PIPESTATUS[0]}
    set -e
    if [[ "$pull_status" -ne 0 ]]; then
      note "ERROR: live download failed; see $pull_log"
      exit "$pull_status"
    fi
    model_path="$(awk -F'Done: ' '/Done: / {print $2}' "$pull_log" | tail -1 | tr -d '\r')"
    if [[ "$model_path" == "(unknown path)" ]]; then
      model_path=""
    fi
    if [[ -n "$model_path" && -d "$model_path" ]]; then
      printf '%s\n' "$model_path"
      return
    fi
    if [[ -n "$model_path" ]]; then
      note "WARN: pull reported a path that is not a directory: $model_path"
    else
      note "WARN: pull did not report a usable Done path"
    fi
  fi

  local cache_path=""
  if cache_path="$(resolve_hf_cache_path "$repo")" && [[ "${MLX_STUDIO_E2E_USE_DEFAULT_CACHE:-1}" == "1" ]]; then
    note "Using existing HF cache path for $repo"
    printf '%s\n' "$cache_path"
    return
  fi

  note "SKIP: set MLX_STUDIO_E2E_MODEL_PATH=/path/to/local/chat/model, or MLX_STUDIO_E2E_LIVE_DOWNLOAD=1 to download $repo."
  exit 0
}

CLI_BIN="$(resolve_cli)"
MODEL_PATH="$(resolve_model_path "$CLI_BIN")"
PROMPT="${MLX_STUDIO_CHAT_E2E_PROMPT:-Reply with exactly one word: pong}"
EXPECTED="${MLX_STUDIO_CHAT_E2E_EXPECTED_SUBSTRING:-pong}"
TIMEOUT="${MLX_STUDIO_CHAT_E2E_TIMEOUT:-240}"
MIN_CHARS="${MLX_STUDIO_CHAT_E2E_MIN_CHARS:-1}"

if [[ ! -d "$MODEL_PATH" ]]; then
  note "ERROR: model path does not exist or is not a directory: $MODEL_PATH"
  exit 2
fi

note "cli=$CLI_BIN"
note "model=$MODEL_PATH"
note "report=$JSON_REPORT"

python3 - "$CLI_BIN" "$MODEL_PATH" "$PROMPT" "$EXPECTED" "$TIMEOUT" "$MIN_CHARS" "$JSON_REPORT" <<'PY' 2>&1 | tee -a "$LOG"
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

cli, model_path, prompt, expected, timeout_s, min_chars, report_path = sys.argv[1:8]
timeout_s = float(timeout_s)
min_chars = int(min_chars)

cmd = [
    cli,
    "chat",
    "--model",
    model_path,
    "--no-tools",
    "true",
    "--temperature",
    "0",
    "--max-tokens",
    os.environ.get("MLX_STUDIO_CHAT_E2E_MAX_TOKENS", "32"),
    "--enable-thinking",
    "false",
    "--show-reasoning",
    "false",
    "--reasoning",
    "none",
    "--system",
    "You are a concise smoke-test assistant. Answer the user directly.",
]

started = time.monotonic()
proc = subprocess.Popen(
    cmd,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ.copy(),
)

try:
    stdout, stderr = proc.communicate(f"{prompt}\n/quit\n", timeout=timeout_s)
    timed_out = False
except subprocess.TimeoutExpired:
    proc.kill()
    stdout, stderr = proc.communicate()
    timed_out = True

duration = time.monotonic() - started
clean_stdout = re.sub(r"\x1B\[[0-?]*[ -/]*[@-~]", "", stdout or "").strip()
clean_stderr = re.sub(r"\x1B\[[0-?]*[ -/]*[@-~]", "", stderr or "").strip()

report = {
    "command": cmd,
    "durationSeconds": duration,
    "finishedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "expectedSubstring": expected,
    "minChars": min_chars,
    "modelPath": os.path.abspath(model_path),
    "prompt": prompt,
    "returnCode": proc.returncode,
    "stderrTail": clean_stderr[-4000:],
    "stdout": clean_stdout,
    "stdoutChars": len(clean_stdout),
    "timedOut": timed_out,
}

with open(report_path, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, sort_keys=True)
    fh.write("\n")

if timed_out:
    print(f"ERROR: chat smoke timed out after {timeout_s:.0f}s")
    sys.exit(124)
if proc.returncode != 0:
    print(f"ERROR: chat command exited with {proc.returncode}")
    print(clean_stderr[-2000:])
    sys.exit(proc.returncode)
if len(clean_stdout) < min_chars:
    print(f"ERROR: streamed response was empty or too short ({len(clean_stdout)} chars)")
    print(clean_stderr[-2000:])
    sys.exit(1)
if "<|im_start|>" in clean_stdout or "<|im_end|>" in clean_stdout:
    print("ERROR: streamed response leaked raw chat-template control tokens")
    print(clean_stdout[-2000:])
    sys.exit(1)
if expected and expected.lower() not in clean_stdout.lower():
    print(f"ERROR: streamed response did not include expected substring: {expected!r}")
    print(clean_stdout[-2000:])
    sys.exit(1)

print(f"OK: streamed {len(clean_stdout)} chars in {duration:.1f}s")
print(clean_stdout[:500])
PY

note "Chat smoke complete"
