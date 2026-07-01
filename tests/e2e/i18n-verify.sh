#!/usr/bin/env bash
# i18n-verify.sh — REVIEW MED-11 regression guard.
#
# Verifies the active MLX Studio screens are fully localized:
#   1. Zero hardcoded Text("…")/Label("…") string literals remain in the
#      active screens (SetupScreen + MLXStudioScreens) — everything routes
#      through the L10n catalog.
#   2. Every StudioStrings L10nEntry has non-empty en/ja/ko/zh (the L10nEntry
#      type also enforces this at compile time).
#   3. Translations are real, not English copies: the large majority of
#      entries have ja AND zh distinct from en (proper nouns like "vMLX",
#      "MLX Studio", "MLX/JANG/HF" are legitimately identical, so we assert a
#      high threshold rather than 100%).
set -uo pipefail
cd "$(dirname "$0")/../.."

SCREENS="Sources/vMLXApp/MLXStudio/MLXStudioScreens.swift Sources/vMLXApp/Onboarding/SetupScreen.swift"
CATALOG="Sources/vMLXApp/Locale/StudioStrings.swift"
fail=0

resid=$(grep -hcE '(Text|Label)\("[^"\\]+"' $SCREENS | paste -sd+ - | bc)
if [ "${resid:-0}" -eq 0 ]; then echo "ok   no hardcoded plain literals in active screens"; else echo "FAIL $resid hardcoded literals remain"; fail=1; fi

python3 - "$CATALOG" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
entries=re.findall(r'L10nEntry\(en: "((?:[^"\\]|\\.)*)", ja: "((?:[^"\\]|\\.)*)", ko: "((?:[^"\\]|\\.)*)", zh: "((?:[^"\\]|\\.)*)"\)', s)
# also multi-line onboarding entries
entries+=re.findall(r'L10nEntry\(\s*en: "((?:[^"\\]|\\.)*)",\s*ja: "((?:[^"\\]|\\.)*)",\s*ko: "((?:[^"\\]|\\.)*)",\s*zh: "((?:[^"\\]|\\.)*)"', s)
assert entries, "no entries parsed"
empty=[e for e in entries if not all(e)]
translated=[e for e in entries if e[1]!=e[0] and e[3]!=e[0]]
frac=len(translated)/len(entries)
print(f"  parsed {len(entries)} L10n entries")
print(f"  {'ok  ' if not empty else 'FAIL'} all locales non-empty ({len(empty)} empty)")
print(f"  {'ok  ' if frac>=0.85 else 'FAIL'} real translations: {len(translated)}/{len(entries)} ({frac:.0%}) have ja&zh != en (>=85%)")
sys.exit(0 if (not empty and frac>=0.85) else 1)
PY
[ $? -eq 0 ] || fail=1

echo
[ $fail -eq 0 ] && { echo "I18N VERIFY: PASS"; exit 0; } || { echo "I18N VERIFY: FAIL"; exit 1; }
