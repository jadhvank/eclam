#!/usr/bin/env bash
# Lightweight swiftc test harness (no SwiftPM) — mirrors scripts/build.sh's
# single-invocation swiftc style. Compiles each test suite as an independent
# standalone program against the framework-free pure source(s) and runs it.
# Exits nonzero if any test program fails. See docs/TODO.md (:28) and
# docs/architecture.md "Pure-policy layer + test harness".
set -euo pipefail

# Resolve repo root regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET="arm64-apple-macos13.0"
TMP="$(mktemp -d /tmp/eclam_tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── Policy tests ──────────────────────────────────────────────────────────
# Pure decision logic. SafetyPolicy.swift is framework-free (Swift stdlib only),
# so it compiles standalone with the test program. PolicyTests.swift is the main
# file (top-level code = entry point).
echo "==> Compiling policy tests"
swiftc -target "$TARGET" \
    -o "$TMP/eclam_policytests" \
    "$ROOT/Sources/ElectronicClamApp/SafetyPolicy.swift" \
    "$ROOT/Tests/PolicyTests.swift"
echo "==> Running policy tests"
"$TMP/eclam_policytests"

# ── Helper protocol tests (added by a sibling branch) ─────────────────────
# Guarded: absent in this worktree (skipped), runs automatically after merge.
if [ -f "$ROOT/Tests/HelperProtocolTests.swift" ]; then
    echo "==> Compiling helper protocol tests"
    swiftc -target "$TARGET" \
        -o "$TMP/eclam_helpertests" \
        "$ROOT/Sources/Shared/HelperProtocol.swift" \
        "$ROOT/Tests/HelperProtocolTests.swift"
    echo "==> Running helper protocol tests"
    "$TMP/eclam_helpertests"
else
    echo "==> Skipping helper protocol tests (Tests/HelperProtocolTests.swift absent)"
fi

# ── HelperCallerIdentity 가드 requirement 테스트 (ADR-0023 §④ 방법 A) ───────
# HelperCallerIdentity.swift 의 *순수* requirement-string 빌더만 테스트한다.
# audit-token → SecCode 경로는 live signed peer + GUI 가 필요해 수동 검증.
# Security 프레임워크 링크 필요(SecRequirementCreateWithString).
if [ -f "$ROOT/Tests/HelperCallerIdentityTests.swift" ]; then
    echo "==> Compiling helper caller identity tests"
    swiftc -target "$TARGET" \
        -framework Foundation -framework Security \
        -o "$TMP/eclam_calleridtests" \
        "$ROOT/Sources/ElectronicClamHelper/HelperCallerIdentity.swift" \
        "$ROOT/Tests/HelperCallerIdentityTests.swift"
    echo "==> Running helper caller identity tests"
    "$TMP/eclam_calleridtests"
else
    echo "==> Skipping helper caller identity tests (Tests/HelperCallerIdentityTests.swift absent)"
fi

# ── ClaudeWorkspacePathing 라운드트립 테스트 ─────────────────────────────────
# ClaudeWorkspacePathing.swift 는 stdlib-only 라 단독 컴파일 가능.
if [ -f "$ROOT/Tests/PathingTests.swift" ]; then
    echo "==> Compiling pathing tests"
    swiftc -target "$TARGET" \
        -o "$TMP/eclam_pathingtests" \
        "$ROOT/Sources/ElectronicClamApp/ClaudeWorkspacePathing.swift" \
        "$ROOT/Tests/PathingTests.swift"
    echo "==> Running pathing tests"
    "$TMP/eclam_pathingtests"
else
    echo "==> Skipping pathing tests (Tests/PathingTests.swift absent)"
fi

# ── DurationParse 테스트 (ADR-0025) ──────────────────────────────────────
# DurationParse.swift 는 stdlib-only 라 단독 컴파일 가능.
if [ -f "$ROOT/Tests/DurationParseTests.swift" ]; then
    echo "==> Compiling duration tests"
    swiftc -target "$TARGET" \
        -o "$TMP/eclam_durationtests" \
        "$ROOT/Sources/Shared/DurationParse.swift" \
        "$ROOT/Tests/DurationParseTests.swift"
    echo "==> Running duration tests"
    "$TMP/eclam_durationtests"
else
    echo "==> Skipping duration tests (Tests/DurationParseTests.swift absent)"
fi

# ── WeeklySummary 경계 케이스 테스트 (proposal §1) ──────────────────────────
# 순수 계층(AwakeEpisode.swift)만 컴파일 — AwakeHistoryStore 는 StateStore 결합.
if [ -f "$ROOT/Tests/WeeklySummaryTests.swift" ]; then
    echo "==> Compiling weekly summary tests"
    swiftc -target "$TARGET" \
        -framework Foundation \
        -o "$TMP/eclam_weeklysummarytests" \
        "$ROOT/Sources/ElectronicClamApp/SafetyPolicy.swift" \
        "$ROOT/Sources/ElectronicClamApp/AwakeEpisode.swift" \
        "$ROOT/Tests/WeeklySummaryTests.swift"
    echo "==> Running weekly summary tests"
    "$TMP/eclam_weeklysummarytests"
else
    echo "==> Skipping weekly summary tests (Tests/WeeklySummaryTests.swift absent)"
fi

# ── HookConfigEditing 순수 변환 테스트 (L1, ADR-0006 §E) ────────────────────
# HookConfigEditing.swift 는 Foundation-only(OSLog·Bundle·FileManager 불필요)라
# 단독 컴파일 가능 — HookInstaller 의 파일 I/O 는 끌고 오지 않는다.
if [ -f "$ROOT/Tests/HookConfigEditingTests.swift" ]; then
    echo "==> Compiling hook config editing tests"
    swiftc -target "$TARGET" \
        -framework Foundation \
        -o "$TMP/eclam_hookconfigtests" \
        "$ROOT/Sources/ElectronicClamApp/HookConfigEditing.swift" \
        "$ROOT/Tests/HookConfigEditingTests.swift"
    echo "==> Running hook config editing tests"
    "$TMP/eclam_hookconfigtests"
else
    echo "==> Skipping hook config editing tests (Tests/HookConfigEditingTests.swift absent)"
fi

# ── AgentActivity 판정 테스트 (L1, ADR-0006 §A/§C/§J/§L) ────────────────────
# AgentActivity.swift 는 Foundation-only(TimeInterval) 라 단독 컴파일 가능 —
# AgentDetector 의 Darwin notify·ps/lsof·Timer 결합은 끌고 오지 않는다.
if [ -f "$ROOT/Tests/AgentActivityTests.swift" ]; then
    echo "==> Compiling agent activity tests"
    swiftc -target "$TARGET" \
        -framework Foundation \
        -o "$TMP/eclam_agentactivitytests" \
        "$ROOT/Sources/ElectronicClamApp/AgentActivity.swift" \
        "$ROOT/Tests/AgentActivityTests.swift"
    echo "==> Running agent activity tests"
    "$TMP/eclam_agentactivitytests"
else
    echo "==> Skipping agent activity tests (Tests/AgentActivityTests.swift absent)"
fi

# ── ClaudeRemoteDetect argv 분류 테스트 (ADR-0031) ─────────────────────────
# ClaudeRemoteDetect.swift 는 Foundation-only(argv 문자열 분류)라 단독 컴파일
# 가능 — RemoteWatcher 의 ps exec·StateStore 결합은 끌고 오지 않는다.
if [ -f "$ROOT/Tests/ClaudeRemoteDetectTests.swift" ]; then
    echo "==> Compiling claude remote detect tests"
    swiftc -target "$TARGET" \
        -framework Foundation \
        -o "$TMP/eclam_clauderemotetests" \
        "$ROOT/Sources/ElectronicClamApp/ClaudeRemoteDetect.swift" \
        "$ROOT/Tests/ClaudeRemoteDetectTests.swift"
    echo "==> Running claude remote detect tests"
    "$TMP/eclam_clauderemotetests"
else
    echo "==> Skipping claude remote detect tests (Tests/ClaudeRemoteDetectTests.swift absent)"
fi

# ── CodexRemoteDetect argv 분류 테스트 (ADR-0031) ──────────────────────────
# CodexRemoteDetect.swift 는 Foundation-only(argv 문자열 분류)라 단독 컴파일 가능.
if [ -f "$ROOT/Tests/CodexRemoteDetectTests.swift" ]; then
    echo "==> Compiling codex remote detect tests"
    swiftc -target "$TARGET" \
        -framework Foundation \
        -o "$TMP/eclam_codexremotetests" \
        "$ROOT/Sources/ElectronicClamApp/CodexRemoteDetect.swift" \
        "$ROOT/Tests/CodexRemoteDetectTests.swift"
    echo "==> Running codex remote detect tests"
    "$TMP/eclam_codexremotetests"
else
    echo "==> Skipping codex remote detect tests (Tests/CodexRemoteDetectTests.swift absent)"
fi

# ── TelegramSupport 게이팅·파싱 테스트 (ADR-0028) ──────────────────────────
# 순수 계층(TelegramSupport.swift)만 컴파일 — TelegramNotifier 는 URLSession·NSL 결합.
if [ -f "$ROOT/Tests/TelegramSupportTests.swift" ]; then
    echo "==> Compiling telegram support tests"
    swiftc -target "$TARGET" \
        -framework Foundation \
        -o "$TMP/eclam_telegramtests" \
        "$ROOT/Sources/ElectronicClamApp/SafetyPolicy.swift" \
        "$ROOT/Sources/ElectronicClamApp/AwakeEpisode.swift" \
        "$ROOT/Sources/ElectronicClamApp/TelegramSupport.swift" \
        "$ROOT/Tests/TelegramSupportTests.swift"
    echo "==> Running telegram support tests"
    "$TMP/eclam_telegramtests"
else
    echo "==> Skipping telegram support tests (Tests/TelegramSupportTests.swift absent)"
fi

# ── HoldState 직렬화/파싱 테스트 (P3, ADR-0025) ────────────────────────────
# HoldState.swift 는 stdlib-only(영속 포맷 직렬화) 라 단독 컴파일 가능 —
# HoldManager 의 IOKit·타이머·파일 I/O 결합은 끌고 오지 않는다.
if [ -f "$ROOT/Tests/HoldStateTests.swift" ]; then
    echo "==> Compiling hold state tests"
    swiftc -target "$TARGET" \
        -framework Foundation \
        -o "$TMP/eclam_holdstatetests" \
        "$ROOT/Sources/Shared/HoldState.swift" \
        "$ROOT/Tests/HoldStateTests.swift"
    echo "==> Running hold state tests"
    "$TMP/eclam_holdstatetests"
else
    echo "==> Skipping hold state tests (Tests/HoldStateTests.swift absent)"
fi

# ── HelperHealth 순수 판정 테스트 (handoff 2026-06-24 — liveness honest status) ──
# HelperHealth.swift 는 stdlib-only(도달성 판정 → 상태 문자열·exit code) 라 단독
# 컴파일 가능 — StatusCommand 의 XPC·ServiceManagement 결합은 끌고 오지 않는다.
if [ -f "$ROOT/Tests/HelperHealthTests.swift" ]; then
    echo "==> Compiling helper health tests"
    swiftc -target "$TARGET" \
        -o "$TMP/eclam_helperhealthtests" \
        "$ROOT/Sources/Shared/HelperHealth.swift" \
        "$ROOT/Tests/HelperHealthTests.swift"
    echo "==> Running helper health tests"
    "$TMP/eclam_helperhealthtests"
else
    echo "==> Skipping helper health tests (Tests/HelperHealthTests.swift absent)"
fi

# ── InstallLocation 게이트 판정 테스트 (ADR-0038) ──────────────────────────
# InstallLocation.swift 는 framework-free(Foundation + Darwin getxattr) 라 단독
# 컴파일 가능 — HelperRegistration 의 SMAppService 결합은 끌고 오지 않는다.
if [ -f "$ROOT/Tests/InstallLocationTests.swift" ]; then
    echo "==> Compiling install location tests"
    swiftc -target "$TARGET" \
        -framework Foundation \
        -o "$TMP/eclam_installlocationtests" \
        "$ROOT/Sources/Shared/InstallLocation.swift" \
        "$ROOT/Tests/InstallLocationTests.swift"
    echo "==> Running install location tests"
    "$TMP/eclam_installlocationtests"
else
    echo "==> Skipping install location tests (Tests/InstallLocationTests.swift absent)"
fi

# ── LaunchctlInspect 파싱 테스트 (ADR-0039) ────────────────────────────────
# parse(_:) 는 순수 함수라 테스트 가능 — Subprocess.swift 를 함께 컴파일해
# helperJob() 의 심볼만 해소하고, 테스트는 parse 만 검증한다.
if [ -f "$ROOT/Tests/LaunchctlInspectTests.swift" ]; then
    echo "==> Compiling launchctl inspect tests"
    swiftc -target "$TARGET" \
        -framework Foundation \
        -o "$TMP/eclam_launchctlinspecttests" \
        "$ROOT/Sources/ElectronicClamApp/LaunchctlInspect.swift" \
        "$ROOT/Sources/ElectronicClamApp/Subprocess.swift" \
        "$ROOT/Tests/LaunchctlInspectTests.swift"
    echo "==> Running launchctl inspect tests"
    "$TMP/eclam_launchctlinspecttests"
else
    echo "==> Skipping launchctl inspect tests (Tests/LaunchctlInspectTests.swift absent)"
fi

echo "==> All tests passed"
