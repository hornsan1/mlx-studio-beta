#!/usr/bin/env bash
# model-route-verify.sh — behavioral tests for the fixes that need a REAL
# loaded model (which the XCTest-free `regression-check` harness cannot cover
# because it has no weights). Covers:
#   • LOW-16 — Ollama /api/generate non-stream `done_reason` reflects the real
#              finish reason ("length" on truncation, not hardcoded "stop").
#   • MED-12 — Whisper 30s truncation is surfaced: `truncated` body field +
#              `X-vMLX-Whisper-Truncated` header, with a short-clip negative.
#
# Usage:
#   ./scripts/stage-metallib.sh debug          # colocate mlx.metallib once
#   tests/e2e/model-route-verify.sh <chat-model-path> [whisper-hint]
#
# Requires: a chat model dir (safetensors) and, for MED-12, a whisper model in
# the HF cache (e.g. `vmlxctl pull mlx-community/whisper-tiny-mlx`). MLX
# Whisper repos ship weights/config while DownloadManager supplements tokenizer
# sidecars from the matching upstream OpenAI Whisper repo; the npz→safetensors
# transcode needs Python `mlx`. Verified passing on 2026-07-01 with
# mlx-community/Qwen3.5-27B-4bit + whisper-tiny-mlx on an M4 Pro
# (see REVIEW-2026-07-01.md §0).
set -uo pipefail

MODEL="${1:?usage: model-route-verify.sh <chat-model-path> [whisper-hint]}"
WHISPER_HINT="${2:-whisper-tiny-mlx}"
PORT="${PORT:-18920}"
BASE="http://127.0.0.1:$PORT"
BIN=".build/arm64-apple-macosx/debug/vmlxctl"
[ -x "$BIN" ] || BIN=".build/debug/vmlxctl"

pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }

echo "▸ booting $BIN serve --model $MODEL --port $PORT"
"$BIN" serve --model "$MODEL" --port "$PORT" >/tmp/mrv-server.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
# Listener opens only after the model finishes loading.
curl -s --retry-connrefused --retry 60 --retry-delay 5 --max-time 30 "$BASE/v1/models" -o /dev/null || { echo "server never came up"; exit 1; }

echo "▸ LOW-16 — /api/generate done_reason on forced truncation"
DR=$(curl -s --max-time 120 "$BASE/api/generate" -H 'Content-Type: application/json' \
  -d "{\"model\":\"m\",\"prompt\":\"Count slowly to five hundred, one per line:\",\"stream\":false,\"options\":{\"num_predict\":5}}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('done_reason'))" 2>/dev/null)
[ "$DR" = "length" ] && ok "/api/generate done_reason='length' (not hardcoded 'stop')" || no "/api/generate done_reason='$DR' (expected 'length')"

echo "▸ MED-12 — Whisper 30s truncation signal"
python3 - <<'PY'
import wave,struct,math
for name,secs in (("/tmp/mrv-long.wav",31),("/tmp/mrv-short.wav",2)):
    with wave.open(name,'w') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        for i in range(16000*secs): w.writeframes(struct.pack('<h',int(3000*math.sin(2*math.pi*220*i/16000))))
PY
LONG=$(curl -s --max-time 240 "$BASE/v1/audio/transcriptions" -F "file=@/tmp/mrv-long.wav;type=audio/wav" -F "model=$WHISPER_HINT" -F "response_format=json" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('truncated'))" 2>/dev/null)
[ "$LONG" = "True" ] && ok "31s clip → truncated=true (body)" || no "31s clip → truncated=$LONG (expected True)"
curl -s --max-time 240 -D /tmp/mrv.hdr "$BASE/v1/audio/transcriptions" -F "file=@/tmp/mrv-long.wav;type=audio/wav" -F "model=$WHISPER_HINT" -F "response_format=srt" -o /dev/null
grep -qi "x-vmlx-whisper-truncated: true" /tmp/mrv.hdr && ok "31s srt → X-vMLX-Whisper-Truncated header" || no "31s srt → missing truncated header"
SHORT=$(curl -s --max-time 240 "$BASE/v1/audio/transcriptions" -F "file=@/tmp/mrv-short.wav;type=audio/wav" -F "model=$WHISPER_HINT" -F "response_format=json" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('truncated'))" 2>/dev/null)
[ "$SHORT" = "False" ] && ok "2s clip → truncated=false (negative control)" || no "2s clip → truncated=$SHORT (expected False)"

echo; echo "$pass ok / $fail fail"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
