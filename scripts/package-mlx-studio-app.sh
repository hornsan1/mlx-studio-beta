#!/usr/bin/env bash
# Build a local MLX Studio macOS .app bundle from the SwiftPM product.
#
# Usage:
#   scripts/package-mlx-studio-app.sh [version] [build-number]
#
# Optional env:
#   CONFIGURATION=debug|release        Defaults to release.
#   DIST_DIR=/path/to/output           Defaults to /tmp/mlx-studio-beta-dist.
#   BUNDLE_ID=ai.dealign.mlxstudio     Defaults to ai.dealign.mlxstudio.beta.
#   CODESIGN_IDENTITY="Developer ID..." Defaults to ad-hoc signing (-).
#   BUNDLE_MFLUX=1|0                   Defaults to 1 when a local mflux venv exists.
#   MFLUX_VENV=/path/to/venv           Defaults to ~/Library/Application Support/vMLX/mflux-venv.
#   BUNDLE_LFM=1|0                     Defaults to 1 when local LFM snapshot exists.
#   LFM_MODEL_SRC=/path/to/snapshot    Defaults to HF cache LiquidAI/LFM2.5-350M main snapshot.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MLX Studio"
PRODUCT_NAME="MLXStudio"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION="${1:-${VERSION:-0.1.0}}"
BUILD_NUMBER="${2:-${BUILD_NUMBER:-1}}"
BUNDLE_ID="${BUNDLE_ID:-ai.dealign.mlxstudio.beta}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
MFLUX_VENV="${MFLUX_VENV:-$HOME/Library/Application Support/vMLX/mflux-venv}"
LFM_MODEL_SRC="${LFM_MODEL_SRC:-$HOME/.cache/huggingface/hub/models--LiquidAI--LFM2.5-350M/snapshots/main}"
if [[ -z "${BUNDLE_MFLUX+x}" ]]; then
    if [[ -x "$MFLUX_VENV/bin/mflux-generate" ]]; then
        BUNDLE_MFLUX=1
    else
        BUNDLE_MFLUX=0
    fi
fi
if [[ -z "${BUNDLE_LFM+x}" ]]; then
    if [[ -f "$LFM_MODEL_SRC/config.json" && -f "$LFM_MODEL_SRC/model.safetensors" ]]; then
        BUNDLE_LFM=1
    else
        BUNDLE_LFM=0
    fi
fi

ARCH="$(uname -m)"
BUILD_PRODUCTS_DIR="$ROOT_DIR/.build/${ARCH}-apple-macosx/$CONFIGURATION"
SWIFT_BIN="$BUILD_PRODUCTS_DIR/$PRODUCT_NAME"
DIST_DIR="${DIST_DIR:-/tmp/mlx-studio-beta-dist}"
FINAL_APP_PATH="$DIST_DIR/$APP_NAME.app"
PACKAGE_STAGE_DIR="${PACKAGE_STAGE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/mlx-studio-package.XXXXXX")}"
APP_PATH="$PACKAGE_STAGE_DIR/$APP_NAME.app"
PARTIAL_INFO="$DIST_DIR/AppIcon-partial.plist"
SIGN_LOG="$DIST_DIR/codesign-sign.log"
VERIFY_LOG="$DIST_DIR/codesign-verify.log"
mkdir -p "$DIST_DIR"
if [[ -z "${PACKAGE_STAGE_DIR_PERSIST:-}" ]]; then
    trap 'rm -rf "$PACKAGE_STAGE_DIR"' EXIT
fi

echo "==> [1/5] SwiftPM build ($CONFIGURATION, $PRODUCT_NAME)"
swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"

if [[ ! -x "$SWIFT_BIN" ]]; then
    FALLBACK_BIN="$ROOT_DIR/.build/$CONFIGURATION/$PRODUCT_NAME"
    if [[ -x "$FALLBACK_BIN" ]]; then
        SWIFT_BIN="$FALLBACK_BIN"
        BUILD_PRODUCTS_DIR="$(dirname "$FALLBACK_BIN")"
    else
        echo "ERROR: SwiftPM did not produce $SWIFT_BIN" >&2
        exit 1
    fi
fi

echo "==> [2/5] Staging $APP_NAME.app"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$SWIFT_BIN" "$APP_PATH/Contents/MacOS/$PRODUCT_NAME"
cp "$ROOT_DIR/MLXStudio/Info.plist" "$APP_PATH/Contents/Info.plist"

plist_set_string() {
    local key="$1"
    local value="$2"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP_PATH/Contents/Info.plist"
}

strip_signing_xattrs() {
    chmod -R u+w "$APP_PATH"
    xattr -cr "$APP_PATH" 2>/dev/null || true
    strip_bad_signing_xattrs
    sleep 0.2
    strip_bad_signing_xattrs
}

strip_bad_signing_xattrs() {
    {
        printf '%s\0' "$APP_PATH"
        find "$APP_PATH/Contents" -maxdepth 2 -type d -print0
        find "$APP_PATH/Contents" \
            -path "$APP_PATH/Contents/Resources/mflux-venv" -prune \
            -o -type d \( -name '*.bundle' -o -name '*.framework' -o -name '_CodeSignature' \) -print0
    } | while IFS= read -r -d '' path; do
        xattr -d 'com.apple.fileprovider.fpfs#P' "$path" 2>/dev/null || true
        xattr -d com.apple.FinderInfo "$path" 2>/dev/null || true
        xattr -d com.apple.ResourceFork "$path" 2>/dev/null || true
        xattr -d com.apple.provenance "$path" 2>/dev/null || true
    done
    strip_root_xattrs
}

strip_root_xattrs() {
    xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_PATH" 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
    xattr -d com.apple.ResourceFork "$APP_PATH" 2>/dev/null || true
    xattr -d com.apple.provenance "$APP_PATH" 2>/dev/null || true
}

rewrite_mflux_launcher() {
    local script="$1"
    local body
    body="$(mktemp)"
    tail -n +4 "$script" > "$body"
    cat > "$script" <<'EOF'
#!/bin/sh
''':'
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VENV_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PYTHON_FRAMEWORK="$(CDPATH= cd -- "$SCRIPT_DIR/../../../Frameworks/Python.framework/Versions/3.14" && pwd)"
export PYTHONHOME="$PYTHON_FRAMEWORK"
export PYTHONPATH="$VENV_DIR/lib/python3.14/site-packages${PYTHONPATH:+:$PYTHONPATH}"
exec "$SCRIPT_DIR/python3.14" "$0" "$@"
' '''
EOF
    cat "$body" >> "$script"
    rm -f "$body"
    chmod +x "$script"
}

plist_set_string "CFBundleExecutable" "$PRODUCT_NAME"
plist_set_string "CFBundleIdentifier" "$BUNDLE_ID"
plist_set_string "CFBundleShortVersionString" "$VERSION"
plist_set_string "CFBundleVersion" "$BUILD_NUMBER"

if [[ -f "$ROOT_DIR/Sources/Cmlx/default.metallib" ]]; then
    cp "$ROOT_DIR/Sources/Cmlx/default.metallib" "$APP_PATH/Contents/Resources/default.metallib"
fi

if [[ "$BUNDLE_MFLUX" == "1" ]]; then
    if [[ ! -x "$MFLUX_VENV/bin/mflux-generate" ]]; then
        echo "ERROR: BUNDLE_MFLUX=1 but $MFLUX_VENV/bin/mflux-generate is not executable" >&2
        exit 1
    fi
    echo "==> Bundling mflux image backend"
    PYTHON_SRC="$(readlink "$MFLUX_VENV/bin/python3.14" || true)"
    if [[ -z "$PYTHON_SRC" || ! -x "$PYTHON_SRC" ]]; then
        PYTHON_SRC="$MFLUX_VENV/bin/python3.14"
    fi
    if [[ ! -x "$PYTHON_SRC" ]]; then
        echo "ERROR: could not resolve Python executable for bundled mflux venv" >&2
        exit 1
    fi
    PYTHON_DYLIB="$(otool -L "$PYTHON_SRC" | awk '/Python.framework/ { print $1; exit }')"
    if [[ -z "$PYTHON_DYLIB" || ! -f "$PYTHON_DYLIB" ]]; then
        echo "ERROR: could not resolve Python.framework dylib for $PYTHON_SRC" >&2
        exit 1
    fi
    PYTHON_FRAMEWORK_SRC="${PYTHON_DYLIB%/Versions/*}"
    mkdir -p "$APP_PATH/Contents/Frameworks"
    /usr/bin/ditto "$PYTHON_FRAMEWORK_SRC" "$APP_PATH/Contents/Frameworks/Python.framework"
    find "$APP_PATH/Contents/Frameworks/Python.framework/Versions" \
        -path '*/lib/python*/site-packages' -type l -delete

    /usr/bin/ditto "$MFLUX_VENV" "$APP_PATH/Contents/Resources/mflux-venv"
    MFLUX_BIN_DIR="$APP_PATH/Contents/Resources/mflux-venv/bin"
    rm -f "$MFLUX_BIN_DIR/python" "$MFLUX_BIN_DIR/python3" \
        "$MFLUX_BIN_DIR/python3.14" "$MFLUX_BIN_DIR/𝜋thon"
    cp "$PYTHON_SRC" "$MFLUX_BIN_DIR/python3.14"
    chmod +x "$MFLUX_BIN_DIR/python3.14"
    install_name_tool \
        -change "$PYTHON_DYLIB" \
        "@executable_path/../../../Frameworks/Python.framework/Versions/3.14/Python" \
        "$MFLUX_BIN_DIR/python3.14"
    ln -s python3.14 "$MFLUX_BIN_DIR/python"
    ln -s python3.14 "$MFLUX_BIN_DIR/python3"
    ln -s python3.14 "$MFLUX_BIN_DIR/𝜋thon"
    while IFS= read -r -d '' script; do
        if LC_ALL=C grep -q "$MFLUX_VENV/bin/python" "$script"; then
            rewrite_mflux_launcher "$script"
        fi
    done < <(find "$MFLUX_BIN_DIR" -type f -perm -111 -print0)
fi

if [[ "$BUNDLE_LFM" == "1" ]]; then
    echo "==> Bundling LiquidAI/LFM2.5-350M starter model"
    for required in config.json tokenizer.json tokenizer_config.json model.safetensors; do
        if [[ ! -f "$LFM_MODEL_SRC/$required" ]]; then
            echo "ERROR: BUNDLE_LFM=1 but $LFM_MODEL_SRC/$required is missing" >&2
            exit 1
        fi
    done
    LFM_DEST="$APP_PATH/Contents/Resources/Models/LiquidAI/LFM2.5-350M"
    rm -rf "$LFM_DEST"
    mkdir -p "$(dirname "$LFM_DEST")"
    /usr/bin/ditto --noextattr "$LFM_MODEL_SRC" "$LFM_DEST"
fi

find "$BUILD_PRODUCTS_DIR" -maxdepth 1 -name '*.bundle' -type d -print0 | while IFS= read -r -d '' bundle; do
    /usr/bin/ditto "$bundle" "$APP_PATH/Contents/Resources/$(basename "$bundle")"
done

echo "==> [3/5] Compiling AppIcon"
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool \
        --compile "$APP_PATH/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$PARTIAL_INFO" \
        --compress-pngs \
        --enable-on-demand-resources NO \
        --development-region en \
        --errors --warnings --notices \
        "$ROOT_DIR/vMLX/Assets.xcassets" >/dev/null

    for key in CFBundleIconFile CFBundleIconName; do
        value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$PARTIAL_INFO" 2>/dev/null || true)
        if [[ -n "$value" ]]; then
            plist_set_string "$key" "$value"
        fi
    done
    rm -f "$PARTIAL_INFO"
else
    echo "WARN: actool not available; app will use the default macOS icon." >&2
fi

echo "==> [4/5] Signing"
strip_signing_xattrs
if [[ "$BUNDLE_MFLUX" == "1" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" \
        "$APP_PATH/Contents/Resources/mflux-venv/bin/python3.14"
fi
SIGN_ARGS=(
    --force
    --deep
    --options runtime
    --entitlements "$ROOT_DIR/vMLX/vMLX.entitlements"
    --sign "$SIGN_IDENTITY"
)
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)
fi
signed=0
for attempt in 1 2 3 4 5; do
    strip_signing_xattrs
    if codesign "${SIGN_ARGS[@]}" "$APP_PATH" >"$SIGN_LOG" 2>&1; then
        cat "$SIGN_LOG"
        signed=1
        break
    fi
    sleep 0.3
done
if [[ "$signed" != "1" ]]; then
    cat "$SIGN_LOG" >&2
    exit 1
fi
rm -f "$SIGN_LOG"
strip_signing_xattrs

echo "==> [5/5] Validating bundle"
plutil -lint "$APP_PATH/Contents/Info.plist"
verified=0
for attempt in 1 2 3 4 5; do
    strip_signing_xattrs
    if codesign --verify --deep --strict --verbose=2 "$APP_PATH" >"$VERIFY_LOG" 2>&1; then
        cat "$VERIFY_LOG"
        verified=1
        break
    fi
    sleep 0.3
done
if [[ "$verified" != "1" ]]; then
    cat "$VERIFY_LOG" >&2
    exit 1
fi
rm -f "$VERIFY_LOG"
/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$APP_PATH/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" >/dev/null
test -x "$APP_PATH/Contents/MacOS/$PRODUCT_NAME"
test -d "$APP_PATH/Contents/Resources/vmlx_Cmlx.bundle"
test -f "$APP_PATH/Contents/Resources/vmlx_Cmlx.bundle/default.metallib"
if [[ "$BUNDLE_MFLUX" == "1" ]]; then
    test -x "$APP_PATH/Contents/Resources/mflux-venv/bin/mflux-generate"
fi
if [[ "$BUNDLE_LFM" == "1" ]]; then
    test -f "$APP_PATH/Contents/Resources/Models/LiquidAI/LFM2.5-350M/config.json"
    test -f "$APP_PATH/Contents/Resources/Models/LiquidAI/LFM2.5-350M/tokenizer.json"
    test -f "$APP_PATH/Contents/Resources/Models/LiquidAI/LFM2.5-350M/model.safetensors"
fi
strip_signing_xattrs

echo "==> Publishing $FINAL_APP_PATH"
rm -rf "$FINAL_APP_PATH"
/usr/bin/ditto --noextattr "$APP_PATH" "$FINAL_APP_PATH"
APP_PATH="$FINAL_APP_PATH"
strip_signing_xattrs
if codesign --verify --deep --strict --verbose=2 "$APP_PATH" >"$VERIFY_LOG" 2>&1; then
    cat "$VERIFY_LOG"
else
    cat "$VERIFY_LOG" >&2
    if grep -q "resource fork, Finder information, or similar detritus not allowed" "$VERIFY_LOG" \
        && xattr -p 'com.apple.fileprovider.fpfs#P' "$APP_PATH" >/dev/null 2>&1; then
        echo "WARN: Final copy is under a File Provider path and has FinderInfo detritus; staged bundle was strictly verified before publish." >&2
    else
        exit 1
    fi
fi
rm -f "$VERIFY_LOG"

echo ""
echo "App: $FINAL_APP_PATH"
echo "Executable: $APP_PATH/Contents/MacOS/$PRODUCT_NAME"
echo "Bundle ID: $BUNDLE_ID"
echo "Signature: $SIGN_IDENTITY"
echo "Bundled LFM: $BUNDLE_LFM"
