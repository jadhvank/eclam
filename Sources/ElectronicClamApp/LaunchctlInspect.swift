import Foundation

/// ADR-0039 — split-brain(중복본·버전 스큐) 탐지의 데이터 소스 ②.
///
/// `launchctl print system/<helper label>` 출력에서 helper job 의 진단 신호를
/// 읽는다. 사건 당시 `last exit code = 78`(EX_CONFIG) / `job state = spawn failed`
/// 는 launchctl 에 다 있었지만 어느 도구도 노출하지 않아 사용자가 손으로 쳐야
/// 원인이 보였다 — `helperJob()` 이 이를 status/repair/diagnostics 로 흘린다.
///
/// 파싱은 순수 함수 `parse(_:)` 로 분리해 단위 테스트한다(`Tests/LaunchctlInspectTests.swift`).
/// 읽기 전용. 미적재/파싱 실패면 `helperJob()` 은 nil.
enum LaunchctlInspect {
    static let helperLabel = "com.jadhvank.eclam.helper"

    struct JobInfo: Equatable {
        let jobState: String?            // "running" / "spawn failed" / ...
        let lastExitCode: Int?           // 78 == EX_CONFIG
        let parentBundleVersion: String? // 등록 소유 번들 버전

        var spawnFailed: Bool {
            (jobState?.contains("spawn failed") ?? false) || lastExitCode == 78
        }
    }

    /// `launchctl print system/<label>` 을 실행해 파싱. 실행 실패·job 미적재
    /// ("Could not find service")·빈 출력이면 nil.
    static func helperJob() -> JobInfo? {
        guard let out = Subprocess.capture(
            "/bin/launchctl", ["print", "system/\(helperLabel)"])
        else { return nil }

        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("Could not find service") {
            return nil
        }
        return parse(out)
    }

    /// 순수 파서 — Subprocess 비의존, 단위 테스트 대상.
    /// 각 줄을 *첫* '=' 에서 한 번만 쪼개고 trim 한 뒤, 키
    /// "job state" / "last exit code" / "parent bundle version" 만 골라낸다.
    /// 여분 공백·뒤따르는 토큰(예: `78: EX_CONFIG`)에 견고하다. 못 찾으면 모두 nil.
    static func parse(_ output: String) -> JobInfo {
        var jobState: String?
        var lastExitCode: Int?
        var parentBundleVersion: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "job state":
                jobState = value
            case "last exit code":
                // value 는 "78" 또는 "78: EX_CONFIG" 형태 — 선행 정수만 취한다.
                let digits = value.prefix(while: { $0.isNumber })
                lastExitCode = Int(digits)
            case "parent bundle version":
                parentBundleVersion = value
            default:
                break
            }
        }

        return JobInfo(jobState: jobState,
                       lastExitCode: lastExitCode,
                       parentBundleVersion: parentBundleVersion)
    }
}
