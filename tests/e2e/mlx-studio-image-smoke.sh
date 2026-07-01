#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

MODEL_PATH="${MLX_STUDIO_IMAGE_E2E_MODEL_PATH:-}"
if [[ -z "$MODEL_PATH" ]]; then
  echo "SKIP: set MLX_STUDIO_IMAGE_E2E_MODEL_PATH=/path/to/local/image/model to run the image smoke."
  exit 0
fi

if [[ ! -d "$MODEL_PATH" ]]; then
  echo "ERROR: model path does not exist or is not a directory: $MODEL_PATH" >&2
  exit 2
fi

CLI_BIN="${VMLXCTL_BIN:-}"
if [[ -z "$CLI_BIN" ]]; then
  if [[ -x ".build/arm64-apple-macosx/release/vmlxctl" ]]; then
    CLI_BIN=".build/arm64-apple-macosx/release/vmlxctl"
  elif [[ -x ".build/release/vmlxctl" ]]; then
    CLI_BIN=".build/release/vmlxctl"
  fi
  if [[ -z "$CLI_BIN" ]] \
    || find "$REPO_ROOT/Sources" "$REPO_ROOT/Package.swift" -newer "$CLI_BIN" -print -quit | grep -q .; then
    swift build -c release --product vmlxctl
    if [[ -x ".build/arm64-apple-macosx/release/vmlxctl" ]]; then
      CLI_BIN=".build/arm64-apple-macosx/release/vmlxctl"
    else
      CLI_BIN=".build/release/vmlxctl"
    fi
  fi
fi

PROMPT="${MLX_STUDIO_IMAGE_E2E_PROMPT:-a small graphite workstation rendering on a Mac, crisp product photo}"
RUNTIME="${MLX_STUDIO_IMAGE_E2E_RUNTIME:-}"
WIDTH="${MLX_STUDIO_IMAGE_E2E_WIDTH:-1024}"
HEIGHT="${MLX_STUDIO_IMAGE_E2E_HEIGHT:-1024}"
STEPS="${MLX_STUDIO_IMAGE_E2E_STEPS:-4}"
GUIDANCE="${MLX_STUDIO_IMAGE_E2E_GUIDANCE:-0}"
SEED="${MLX_STUDIO_IMAGE_E2E_SEED:-42}"
if [[ "${MLX_STUDIO_IMAGE_E2E_BYPASS_TEXT_ENCODERS:-0}" == "1" ]]; then
  export VMLX_FLUX_BYPASS_TEXT_ENCODERS=1
  export VMLX_FLUX_SWIFT_LATENTS=1
  export VMLX_MLXNN_ZERO_RANDOM_INIT=1
fi
if [[ "${MLX_STUDIO_IMAGE_E2E_EXTERNAL_METAL_JIT:-0}" == "1" ]]; then
  export VMLX_METAL_EXTERNAL_JIT=1
fi

REPORT_DIR="${MLX_STUDIO_IMAGE_E2E_REPORT_DIR:-tests/e2e/reports}"
mkdir -p "$REPORT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_SLUG="${RUNTIME:-$(basename "$MODEL_PATH")}"
REPORT_SLUG="$(printf '%s' "$REPORT_SLUG" | tr -c '[:alnum:]_.-' '-')"
OUTPUT="${MLX_STUDIO_IMAGE_E2E_OUTPUT:-$REPORT_DIR/mlx-studio-image-smoke-$REPORT_SLUG-$STAMP-$$.png}"
LOG="$REPORT_DIR/mlx-studio-image-smoke-$REPORT_SLUG-$STAMP-$$.log"

echo "[image-smoke] model=$MODEL_PATH" | tee "$LOG"
if [[ -n "$RUNTIME" ]]; then
  echo "[image-smoke] runtime=$RUNTIME" | tee -a "$LOG"
fi
echo "[image-smoke] output=$OUTPUT" | tee -a "$LOG"

diagnose_metal_runtime() {
  echo "[metal-diagnose] MTLCompilerService processes:"
  ps aux | grep -i '[M]TLCompilerService' || true

  local temp
  temp="$(mktemp -d "${TMPDIR:-/tmp}/mlx-studio-metal-diagnose.XXXXXX")"
  local source="$temp/preflight.metal"
  local library="$temp/preflight.metallib"
  cat > "$source" <<'METAL'
#include <metal_stdlib>
using namespace metal;
kernel void mlx_studio_external_jit_preflight(
    device const float* a [[buffer(0)]],
    device const float* b [[buffer(1)]],
    device float* out [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    out[gid] = a[gid] * b[gid];
}
METAL

  if xcrun -sdk macosx metal "$source" -o "$library" >/dev/null 2>&1; then
    echo "[metal-diagnose] offline xcrun metal compile: ok"
  else
    echo "[metal-diagnose] offline xcrun metal compile: failed"
    rm -rf "$temp"
    return 0
  fi

  swift - "$library" <<'SWIFT' || true
import Foundation
import Metal

let path = CommandLine.arguments[1]
guard let device = MTLCreateSystemDefaultDevice() else {
    print("[metal-diagnose] no default Metal device")
    exit(0)
}
do {
    let library = try device.makeLibrary(URL: URL(fileURLWithPath: path))
    print("[metal-diagnose] metallib load: ok")
    guard let function = library.makeFunction(name: "mlx_studio_external_jit_preflight") else {
        print("[metal-diagnose] metallib function lookup: missing")
        exit(0)
    }
    print("[metal-diagnose] metallib function lookup: ok")
    _ = try device.makeComputePipelineState(function: function)
    print("[metal-diagnose] compute pipeline creation: ok")
} catch {
    print("[metal-diagnose] compute pipeline creation: failed: \(error)")
}
SWIFT
  rm -rf "$temp"
}

summarize_metal_failure() {
  if grep -q 'Unable to reach MTLCompilerService' "$LOG"; then
    echo "[image-smoke] HOST_METAL_UNAVAILABLE: macOS cannot reach MTLCompilerService from this launch context; local Metal image generation is blocked before pixel synthesis." | tee -a "$LOG"
    echo "[image-smoke] Try relaunching MLX Studio/vmlxctl from a normal user session, or restart the stale MTLCompilerService/session before rerunning this smoke." | tee -a "$LOG"
  fi
}

if [[ "${MLX_STUDIO_IMAGE_E2E_SKIP_METAL_PREFLIGHT:-0}" != "1" ]]; then
  set +e
  swift tests/e2e/metal-jit-preflight.swift 2>&1 | tee -a "$LOG"
  PREFLIGHT_STATUS=${PIPESTATUS[0]}
  set -e
  if [[ "$PREFLIGHT_STATUS" -ne 0 ]]; then
    diagnose_metal_runtime 2>&1 | tee -a "$LOG"
    summarize_metal_failure
    exit "$PREFLIGHT_STATUS"
  fi
fi

set +e
IMAGE_ARGS=(
  --model "$MODEL_PATH"
  --prompt "$PROMPT"
  --output "$OUTPUT"
  --width "$WIDTH"
  --height "$HEIGHT"
  --steps "$STEPS"
  --guidance "$GUIDANCE"
  --seed "$SEED"
)
if [[ -n "$RUNTIME" ]]; then
  IMAGE_ARGS+=(--runtime "$RUNTIME")
fi
"$CLI_BIN" images \
  "${IMAGE_ARGS[@]}" 2>&1 | tee -a "$LOG"
CLI_STATUS=${PIPESTATUS[0]}
set -e
if [[ "$CLI_STATUS" -ne 0 ]]; then
  diagnose_metal_runtime 2>&1 | tee -a "$LOG"
  summarize_metal_failure
  exit "$CLI_STATUS"
fi

python3 - "$OUTPUT" "$WIDTH" "$HEIGHT" "$MODEL_PATH" "$RUNTIME" "$STEPS" "$SEED" <<'PY'
from datetime import datetime, timezone
import json
import os
import struct
import sys
import zlib

path, expected_w, expected_h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
model_path, runtime_name = sys.argv[4], sys.argv[5]
steps, seed = int(sys.argv[6]), int(sys.argv[7])
data = open(path, "rb").read()
if not data.startswith(b"\x89PNG\r\n\x1a\n"):
    raise SystemExit(f"ERROR: not a PNG: {path}")

pos = 8
width = height = bit_depth = color_type = None
idat = []
while pos + 8 <= len(data):
    length = struct.unpack(">I", data[pos:pos + 4])[0]
    chunk_type = data[pos + 4:pos + 8]
    chunk = data[pos + 8:pos + 8 + length]
    pos += 12 + length
    if chunk_type == b"IHDR":
        width, height, bit_depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", chunk)
    elif chunk_type == b"IDAT":
        idat.append(chunk)
    elif chunk_type == b"IEND":
        break

if (width, height) != (expected_w, expected_h):
    raise SystemExit(f"ERROR: PNG dimensions {width}x{height}, expected {expected_w}x{expected_h}")
if bit_depth != 8:
    raise SystemExit(f"ERROR: unsupported PNG bit depth {bit_depth}; expected 8")

bpp_by_color = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
if color_type not in bpp_by_color:
    raise SystemExit(f"ERROR: unsupported PNG color type {color_type}")

bpp = bpp_by_color[color_type]
stride = width * bpp
raw = zlib.decompress(b"".join(idat))
rows = []
offset = 0
prev = bytearray(stride)

for _ in range(height):
    filt = raw[offset]
    offset += 1
    row = bytearray(raw[offset:offset + stride])
    offset += stride
    for i in range(stride):
        left = row[i - bpp] if i >= bpp else 0
        up = prev[i]
        up_left = prev[i - bpp] if i >= bpp else 0
        if filt == 1:
            row[i] = (row[i] + left) & 0xFF
        elif filt == 2:
            row[i] = (row[i] + up) & 0xFF
        elif filt == 3:
            row[i] = (row[i] + ((left + up) // 2)) & 0xFF
        elif filt == 4:
            p = left + up - up_left
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
            pred = left if pa <= pb and pa <= pc else up if pb <= pc else up_left
            row[i] = (row[i] + pred) & 0xFF
        elif filt != 0:
            raise SystemExit(f"ERROR: unsupported PNG filter {filt}")
    rows.append(bytes(row))
    prev = row

pixels = b"".join(rows)
if color_type == 6:
    samples = bytearray()
    for i in range(0, len(pixels), 4):
        samples.extend(pixels[i:i + 3])
elif color_type == 4:
    samples = pixels[0::2]
else:
    samples = pixels

if not samples:
    raise SystemExit("ERROR: PNG has no pixel samples")
mean = sum(samples) / len(samples)
variance = sum((x - mean) ** 2 for x in samples) / len(samples)
if variance < 1.0:
    raise SystemExit(f"ERROR: PNG appears blank; pixel variance {variance:.4f}")

print(f"OK: {path} {width}x{height} variance={variance:.2f}")
if runtime_name and os.environ.get("MLX_STUDIO_IMAGE_E2E_RECORD_PROOF", "1") != "0":
    proof_dir = os.environ.get(
        "MLX_STUDIO_IMAGE_PROOF_DIR",
        os.path.expanduser("~/Library/Application Support/vMLX/image-runtime-proofs"),
    )
    os.makedirs(proof_dir, exist_ok=True)
    safe_name = "".join(c if c.isalnum() or c in "-_." else "-" for c in runtime_name).strip("-.")
    proof_path = os.path.join(proof_dir, f"{safe_name or 'unknown-runtime'}.json")
    with open(proof_path, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "height": height,
                "modelPath": os.path.abspath(model_path),
                "outputPath": os.path.abspath(path),
                "pixelVariance": variance,
                "runtimeName": runtime_name,
                "seed": seed,
                "steps": steps,
                "verifiedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "width": width,
            },
            fh,
            indent=2,
            sort_keys=True,
        )
        fh.write("\n")
    print(f"OK: recorded image runtime proof: {proof_path}")
PY
