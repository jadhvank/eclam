#!/usr/bin/env bash
# smoke.sh — 출시 전 통합 스모크 테스트.
# 빌드·단위 테스트·i18n parity·CLI 동작을 순서대로 검증한다.
#
# 주의: 파이프로 호출하면 build.sh 의 실패가 삼켜지는 사고가 실측됐다
# (2026-06-11 기록 — 앱 바이너리 누락을 늦게 발견). 그래서 이 스크립트가
# set -euo pipefail 을 사용하고 서브스크립트를 직접 실행한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP="$ROOT/build/ElectronicClam.app"
BIN="$APP/Contents/MacOS/ElectronicClam"

# ── 1. 빌드 ──────────────────────────────────────────────────────────────────
echo "==> [smoke] 빌드 시작"
# `VAR="$(cmd)"` 는 set -e 아래에서 cmd 실패 시 즉시 종료해 BUILD_OUT 을
# 한 줄도 못 찍는다 (2026-06-13 CI 실측 — codesign 실패가 무출력으로 죽음).
# `|| BUILD_STATUS=$?` 로 errexit 을 억제해 실패 출력을 보존한다.
BUILD_STATUS=0
BUILD_OUT="$("$SCRIPT_DIR/build.sh" 2>&1)" || BUILD_STATUS=$?

# 파이프 우회 — 출력에 "error:" 가 있는지 직접 grep (경고·노트 제외)
if echo "$BUILD_OUT" | grep -qE '^.*error:'; then
    echo "==> [smoke] 빌드 출력에 error: 발견"
    echo "$BUILD_OUT"
    exit 1
fi

if [ $BUILD_STATUS -ne 0 ]; then
    echo "==> [smoke] build.sh 가 exit $BUILD_STATUS 로 실패"
    echo "$BUILD_OUT"
    exit 1
fi

# 바이너리 실존 확인 (파이프 우회의 핵심 — 빌드 성공해도 바이너리 없으면 후속 검증이 의미 없음)
if [ ! -f "$BIN" ]; then
    echo "==> [smoke] 바이너리 없음: $BIN"
    exit 1
fi
echo "==> [smoke] 빌드 OK (바이너리 확인: $BIN)"

# ── 2. 단위 테스트 ────────────────────────────────────────────────────────────
echo "==> [smoke] 단위 테스트 실행"
"$SCRIPT_DIR/test.sh"
echo "==> [smoke] 단위 테스트 OK"

# ── 3. i18n parity ───────────────────────────────────────────────────────────
echo "==> [smoke] i18n parity 확인"
"$SCRIPT_DIR/check-i18n.sh"
echo "==> [smoke] i18n OK"

# ── 4. `debug agents` — exit 0 + 출력에 "Traces:" 포함 ───────────────────────
echo "==> [smoke] debug agents 실행"
DEBUG_OUT="$("$BIN" debug agents 2>&1)" || {
    echo "==> [smoke] debug agents 가 비정상 종료"
    echo "$DEBUG_OUT"
    exit 1
}
if ! echo "$DEBUG_OUT" | grep -q "Traces:"; then
    echo "==> [smoke] debug agents 출력에 'Traces:' 없음"
    echo "$DEBUG_OUT"
    exit 1
fi
echo "==> [smoke] debug agents OK"

# ── 5. `status` — exit 0 + 출력에 "helper:" 줄 포함 ─────────────────────────
echo "==> [smoke] status 실행"
STATUS_OUT="$("$BIN" status 2>&1)" || {
    echo "==> [smoke] status 가 비정상 종료"
    echo "$STATUS_OUT"
    exit 1
}
if ! echo "$STATUS_OUT" | grep -q "helper:"; then
    echo "==> [smoke] status 출력에 'helper:' 없음"
    echo "$STATUS_OUT"
    exit 1
fi
echo "==> [smoke] status OK"

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo "==> SMOKE PASS"
