#!/usr/bin/env bash
# check-i18n.sh — i18n parity 검사 (ADR-0011)
#
# ① 각 *.lproj/Localizable.strings 의 키 집합이 en.lproj 와 동일한지,
#    키별 %@/%d/%% 등 format specifier multiset 이 일치하는지 검증한다.
# ② 코드(Sources/)가 NSL/NSLf 로 참조하는 리터럴 키가 en.lproj 에 실재하는지
#    검증한다 — lproj 끼리만 비교하던 ①은 "코드엔 있는데 모든 lproj 에 없는"
#    클래스를 못 잡는다 (2026-06-11 실측: 툴팁 키 13개가 이렇게 누락돼
#    영어 fallback 으로만 노출). 반대 방향(lproj 에만 있는 미사용 키)은 동적
#    키 조합 가능성이 있어 경고만 한다.
# 불일치 발견 시 diff 리포트를 출력하고 exit 1.
#
# 사용법:
#   ./scripts/check-i18n.sh               # repo root 기준 자동 탐색
#   ./scripts/check-i18n.sh <resources>   # Resources 디렉터리 직접 지정

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES="${1:-$REPO_ROOT/Resources}"

EN_FILE="$RESOURCES/en.lproj/Localizable.strings"

if [[ ! -f "$EN_FILE" ]]; then
    echo "ERROR: en.lproj/Localizable.strings 를 찾을 수 없음: $EN_FILE" >&2
    exit 1
fi

# 키 추출: "key" = ... 형식의 줄에서 첫 번째 quoted string 을 꺼낸다.
extract_keys() {
    python3 - "$1" <<'PYEOF'
import sys, re
keys = []
with open(sys.argv[1], encoding='utf-8') as f:
    for line in f:
        m = re.match(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', line)
        if m:
            keys.append(m.group(1))
print('\n'.join(sorted(keys)))
PYEOF
}

# format specifier multiset 추출 (키별로 해당 값의 specifier 나열)
extract_specifiers() {
    python3 - "$1" <<'PYEOF'
import sys, re
from collections import Counter
pairs = {}
with open(sys.argv[1], encoding='utf-8') as f:
    for line in f:
        m = re.match(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"', line)
        if m:
            key, val = m.group(1), m.group(2)
            specs = re.findall(r'%(?:\d+\$)?[@disfg]|%%', val)
            pairs[key] = sorted(specs)
for k, v in sorted(pairs.items()):
    print(f"{k}\t{' '.join(v) if v else ''}")
PYEOF
}

FAIL=0
EN_KEYS_FILE="$(mktemp)"
EN_SPECS_FILE="$(mktemp)"
trap 'rm -f "$EN_KEYS_FILE" "$EN_SPECS_FILE"' EXIT

extract_keys "$EN_FILE" > "$EN_KEYS_FILE"
extract_specifiers "$EN_FILE" > "$EN_SPECS_FILE"

for lproj_dir in "$RESOURCES"/*.lproj; do
    lang="$(basename "$lproj_dir" .lproj)"
    [[ "$lang" == "en" ]] && continue

    LANG_FILE="$lproj_dir/Localizable.strings"
    if [[ ! -f "$LANG_FILE" ]]; then
        echo "MISSING: $lang.lproj/Localizable.strings" >&2
        FAIL=1
        continue
    fi

    LANG_KEYS_FILE="$(mktemp)"
    LANG_SPECS_FILE="$(mktemp)"
    extract_keys "$LANG_FILE" > "$LANG_KEYS_FILE"
    extract_specifiers "$LANG_FILE" > "$LANG_SPECS_FILE"

    # 1) 키 집합 비교
    KEYS_DIFF="$(diff "$EN_KEYS_FILE" "$LANG_KEYS_FILE" || true)"
    if [[ -n "$KEYS_DIFF" ]]; then
        echo ""
        echo "=== [$lang] 키 집합 불일치 (< en 에만 있음, > $lang 에만 있음) ==="
        echo "$KEYS_DIFF"
        FAIL=1
    fi

    # 2) format specifier 비교
    SPEC_DIFF="$(diff "$EN_SPECS_FILE" "$LANG_SPECS_FILE" || true)"
    if [[ -n "$SPEC_DIFF" ]]; then
        echo ""
        echo "=== [$lang] format specifier 불일치 (< en, > $lang) ==="
        echo "$SPEC_DIFF"
        FAIL=1
    fi

    rm -f "$LANG_KEYS_FILE" "$LANG_SPECS_FILE"
done

# ② 코드 ↔ en.lproj 교차 검사 (Sources/ 가 있을 때만 — Resources 단독 호출 허용)
SOURCES_DIR="$REPO_ROOT/Sources"
if [[ -d "$SOURCES_DIR" ]]; then
    CODE_KEYS_FILE="$(mktemp)"
    EN_KEYS_C_FILE="$(mktemp)"
    # NSL("key", …) / NSLf("key", …) 의 리터럴 첫 인자만 수집 (변수 키는 제외됨).
    # comm 은 양쪽이 같은 collation 으로 정렬돼야 하므로 LC_ALL=C 로 통일
    # (python sorted() = codepoint 순 = LC_ALL=C).
    grep -rhoE 'NSLf?\("([^"\\]|\\.)+"' "$SOURCES_DIR" \
        | sed -E 's/^NSLf?\("//; s/"$//' | LC_ALL=C sort -u > "$CODE_KEYS_FILE"
    LC_ALL=C sort "$EN_KEYS_FILE" > "$EN_KEYS_C_FILE"

    MISSING="$(LC_ALL=C comm -23 "$CODE_KEYS_FILE" "$EN_KEYS_C_FILE")"
    if [[ -n "$MISSING" ]]; then
        echo ""
        echo "=== 코드가 참조하지만 en.lproj 에 없는 키 (영어 fallback 으로만 노출됨) ==="
        echo "$MISSING"
        FAIL=1
    fi

    UNUSED="$(LC_ALL=C comm -13 "$CODE_KEYS_FILE" "$EN_KEYS_C_FILE")"
    if [[ -n "$UNUSED" ]]; then
        echo ""
        echo "(경고) en.lproj 에 있지만 코드 리터럴 참조가 없는 키 — 동적 키이거나 dead key:"
        echo "$UNUSED" | sed 's/^/  /'
    fi
    rm -f "$CODE_KEYS_FILE" "$EN_KEYS_C_FILE"
fi

if [[ $FAIL -eq 0 ]]; then
    KEY_COUNT="$(wc -l < "$EN_KEYS_FILE" | tr -d ' ')"
    echo "i18n parity OK — $KEY_COUNT keys × $(find "$RESOURCES" -name 'Localizable.strings' | wc -l | tr -d ' ') lproj files"
    exit 0
else
    exit 1
fi
