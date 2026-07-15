#!/usr/bin/env bash
# Verify the PR 20 boundary without deleting historical JANG sources or releases.
#
# Usage:
#   scripts/verify-jang-studio-retirement.sh \
#     [--jang-source /path/to/jangq-private] \
#     [--release-host /path/to/jang-studio-beta]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JANG_SOURCE=""
RELEASE_HOST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jang-source)
            JANG_SOURCE="${2:?missing path after --jang-source}"
            shift 2
            ;;
        --release-host)
            RELEASE_HOST="${2:?missing path after --release-host}"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

cd "$ROOT_DIR"

echo "==> Canonical product boundary"
test ! -d JANGStudio || fail "the legacy JANGStudio shell exists in the product repository"

for symbol in \
    JANGStudioApp \
    InferenceRunner \
    StudioChatScreen \
    StudioChatService \
    StudioChatModelSelection \
    StudioLibraryScreen \
    StudioJobService
do
    if rg -n --glob '*.swift' "$symbol" Sources; then
        fail "retired production symbol remains: $symbol"
    fi
done

if rg -n --glob '*.swift' '^[[:space:]]*import[[:space:]]+JANGKit([[:space:]]|$)' Sources; then
    fail "a production target still imports JANGKit"
fi
if rg -n --glob '*.swift' '^[[:space:]]*import[[:space:]]+' Sources/MLXStudioDomain \
    | rg -v ':import Foundation$'; then
    fail "MLXStudioDomain imports a framework other than Foundation"
fi

PROVIDER_MATCHES="$(
    rg -n --glob '*.swift' ':[[:space:]]*ModelInferenceProvider([[:space:],{]|$)' Sources || true
)"
PROVIDER_COUNT="$(printf '%s\n' "$PROVIDER_MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$PROVIDER_COUNT" -eq 1 ]] || fail "expected one concrete ModelInferenceProvider, found $PROVIDER_COUNT"
[[ "$PROVIDER_MATCHES" == Sources/vMLXEngine/VMLXInferenceProvider.swift:* ]] \
    || fail "vMLXEngine is not the sole inference-provider implementation"

test -f Sources/MLXStudioOptimization/PythonJANGWorker.swift \
    || fail "structured JANG worker is missing"
test -f Sources/MLXStudioOptimization/JANGPublishingCoordinator.swift \
    || fail "structured publishing coordinator is missing"
test -f Sources/vMLXApp/MLXStudio/StudioPublishingSheets.swift \
    || fail "publishing/model-card application flow is missing"
rg -q 'publishHuggingFace' Sources/MLXStudioDomain/OptimizationWorkerContracts.swift \
    || fail "publishing operation is absent from the domain worker contract"
rg -q 'generateModelCard' Sources/MLXStudioDomain/OptimizationWorkerContracts.swift \
    || fail "model-card operation is absent from the domain worker contract"

echo "==> SwiftPM dependency direction"
PACKAGE_JSON="$(mktemp "${TMPDIR:-/tmp}/mlx-studio-package.XXXXXX")"
trap 'rm -f "$PACKAGE_JSON"' EXIT
swift package dump-package > "$PACKAGE_JSON"
python3 - "$PACKAGE_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    package = json.load(handle)

targets = {target["name"]: target for target in package["targets"]}

def dependency_names(target_name):
    names = set()
    for dependency in targets[target_name].get("dependencies", []):
        if "byName" in dependency:
            names.add(dependency["byName"][0])
        elif "target" in dependency:
            names.add(dependency["target"][0])
        elif "product" in dependency:
            names.add(dependency["product"][0])
    return names

exact = {
    "MLXStudioDomain": set(),
    "MLXStudioPersistence": {"MLXStudioDomain"},
    "MLXStudioEvaluation": {"MLXStudioDomain", "MLXStudioPersistence"},
    "MLXStudioOptimization": {
        "MLXStudioDomain", "MLXStudioPersistence", "MLXStudioEvaluation"
    },
    "JANGExpertLab": {"MLXStudioDomain", "MLXStudioEvaluation"},
}

required = {
    "vMLXEngine": {"MLXStudioDomain"},
    "vMLXApp": {
        "MLXStudioDomain", "MLXStudioPersistence", "MLXStudioEvaluation",
        "MLXStudioOptimization", "JANGExpertLab", "vMLXEngine"
    },
}

for name, expected in exact.items():
    if name not in targets:
        raise SystemExit(f"ERROR: missing SwiftPM target {name}")
    actual = dependency_names(name)
    if actual != expected:
        raise SystemExit(
            f"ERROR: {name} dependencies changed; expected {sorted(expected)}, "
            f"found {sorted(actual)}"
        )

for name, expected in required.items():
    if name not in targets:
        raise SystemExit(f"ERROR: missing SwiftPM target {name}")
    actual = dependency_names(name)
    missing = expected - actual
    if missing:
        raise SystemExit(f"ERROR: {name} misses dependencies: {sorted(missing)}")

if "JANGKit" in dependency_names("JANGExpertLab"):
    raise SystemExit("ERROR: JANGExpertLab still depends on JANGKit")

print("SwiftPM retirement graph OK")
PY

if [[ -n "$JANG_SOURCE" ]]; then
    echo "==> Frozen migration source"
    test -d "$JANG_SOURCE/.git" || fail "not a git checkout: $JANG_SOURCE"
    git -C "$JANG_SOURCE" merge-base --is-ancestor \
        5d5487c27fa81d9f51da27264ae855964e334070 HEAD \
        || fail "migration source no longer descends from the Phase 0 pin"
    rg -q 'JANG Studio application is retired' "$JANG_SOURCE/README.md" \
        || fail "migration-source README.md does not carry the retirement notice"
    rg -q 'JANG Studio application is retired' "$JANG_SOURCE/README-USER.md" \
        || fail "migration-source README-USER.md does not carry the retirement notice"
    rg -q 'frozen migration source' "$JANG_SOURCE/README.md" \
        || fail "migration source is not labeled frozen"
fi

if [[ -n "$RELEASE_HOST" ]]; then
    echo "==> Public release redirect"
    test -d "$RELEASE_HOST/.git" || fail "not a git checkout: $RELEASE_HOST"
    git -C "$RELEASE_HOST" merge-base --is-ancestor \
        cfcc8f058065ec25371c45ad035eea2ca2399ab5 HEAD \
        || fail "release host no longer descends from the Phase 0 pin"
    rg -q 'JANG Studio has been consolidated into MLX Studio' "$RELEASE_HOST/README.md" \
        || fail "release host does not redirect to MLX Studio"
    rg -q 'Historical releases remain available' "$RELEASE_HOST/README.md" \
        || fail "release host does not preserve historical-release guidance"
    git -C "$RELEASE_HOST" rev-parse -q --verify \
        'refs/tags/v0.2.0-beta-2026-07-14' >/dev/null \
        || fail "historical JANG Studio release tag is missing"
fi

echo "JANG_STUDIO_RETIREMENT_OK"
