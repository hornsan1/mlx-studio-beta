#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

REPORT_DIR="${MLX_STUDIO_INSTALL_E2E_REPORT_DIR:-Tests/e2e/reports}"
mkdir -p "$REPORT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$REPORT_DIR/mlx-studio-install-chat-smoke-$STAMP-$$.log"
JSON_REPORT="$REPORT_DIR/mlx-studio-install-chat-smoke-$STAMP-$$.json"

REPO="${MLX_STUDIO_E2E_REPO:-LiquidAI/LFM2.5-350M}"
# Supply an already-verified local model directory to exercise the complete
# scan → load → chat path without invoking `pull`. This is the safe release
# smoke mode for machines that already have the starter model cached; it
# prevents a test run from mutating a shared Hugging Face cache.
MODEL_PATH_OVERRIDE="${MLX_STUDIO_E2E_MODEL_PATH:-}"
PROMPT="${MLX_STUDIO_CHAT_E2E_PROMPT:-Reply with exactly one word: pong}"
EXPECTED="${MLX_STUDIO_CHAT_E2E_EXPECTED_SUBSTRING:-pong}"
TIMEOUT="${MLX_STUDIO_CHAT_E2E_TIMEOUT:-240}"

note() {
  printf '[install-chat-smoke] %s\n' "$*" | tee -a "$LOG" >&2
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

require_model_files() {
  local model_path="$1"
  [[ -d "$model_path" ]] || { note "ERROR: model path is not a directory: $model_path"; exit 2; }
  [[ -f "$model_path/config.json" ]] || { note "ERROR: config.json missing in $model_path"; exit 2; }
  if ! find "$model_path" -maxdepth 2 \( -name tokenizer.json -o -name tokenizer.model -o -name vocab.json \) -print -quit | grep -q .; then
    note "ERROR: tokenizer evidence missing in $model_path"
    exit 2
  fi
  if ! find "$model_path" -maxdepth 2 \( -name '*.safetensors' -o -name '*.bin' -o -name '*.gguf' \) -print -quit | grep -q .; then
    note "ERROR: weight files missing in $model_path"
    exit 2
  fi
}

CLI_BIN="$(resolve_cli)"
PULL_LOG="$REPORT_DIR/mlx-studio-install-chat-pull-$STAMP-$$.log"
LIST_LOG="$REPORT_DIR/mlx-studio-install-chat-list-$STAMP-$$.log"

note "cli=$CLI_BIN"
note "repo=$REPO"
if [[ -n "$MODEL_PATH_OVERRIDE" ]]; then
  MODEL_PATH="$(cd "$MODEL_PATH_OVERRIDE" && pwd -P)"
  note "using supplied local model path; skipping pull: $MODEL_PATH"
  : > "$PULL_LOG"
  printf 'Skipped pull; MLX_STUDIO_E2E_MODEL_PATH=%s\n' "$MODEL_PATH" \
    | tee -a "$PULL_LOG" | tee -a "$LOG" >&2
else
  note "pulling/verifying via vmlxctl pull"
  set +e
  "$CLI_BIN" pull "$REPO" 2>&1 | tee "$PULL_LOG" | tee -a "$LOG" >&2
  PULL_STATUS=${PIPESTATUS[0]}
  set -e
  if [[ "$PULL_STATUS" -ne 0 ]]; then
    note "ERROR: pull failed; see $PULL_LOG"
    exit "$PULL_STATUS"
  fi

  MODEL_PATH="$(awk -F'Done: ' '/Done: / {print $2}' "$PULL_LOG" | tail -1 | tr -d '\r')"
  if [[ -z "$MODEL_PATH" || "$MODEL_PATH" == "(unknown path)" ]]; then
    note "ERROR: pull did not report a usable Done path"
    exit 2
  fi
  MODEL_PATH="$(cd "$MODEL_PATH" && pwd -P)"
fi
require_model_files "$MODEL_PATH"

note "scanning model library via vmlxctl ls"
"$CLI_BIN" ls 2>&1 | tee "$LIST_LOG" | tee -a "$LOG" >&2
if ! grep -Fq "$MODEL_PATH" "$LIST_LOG"; then
  note "ERROR: vmlxctl ls did not discover $MODEL_PATH"
  exit 3
fi

note "loading and streaming chat"
python3 - "$CLI_BIN" "$MODEL_PATH" "$PROMPT" "$EXPECTED" "$TIMEOUT" "$JSON_REPORT" "$PULL_LOG" "$LIST_LOG" <<'PY' 2>&1 | tee -a "$LOG"
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

cli, model_path, prompt, expected, timeout_s, report_path, pull_log, list_log = sys.argv[1:9]
timeout_s = float(timeout_s)
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
    "expectedSubstring": expected,
    "finishedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "modelPath": os.path.abspath(model_path),
    "prompt": prompt,
    "pullLog": os.path.abspath(pull_log),
    "repo": os.environ.get("MLX_STUDIO_E2E_REPO", "LiquidAI/LFM2.5-350M"),
    "returnCode": proc.returncode,
    "libraryListLog": os.path.abspath(list_log),
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
if not clean_stdout:
    print("ERROR: streamed response was empty")
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

print(f"OK: install-to-chat streamed {len(clean_stdout)} chars in {duration:.1f}s")
print(clean_stdout[:500])
PY

note "Install-to-chat smoke complete"
