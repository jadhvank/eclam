import AppKit
import Foundation

/// 사용자 제보용 진단 번들 생성기 (proposal §2).
///
/// `export()` 를 호출하면 ~/Desktop/eclam-diagnostics-YYYYMMDD-HHmmss.zip 을 만들고
/// URL 을 반환한다. 실패하면 nil.
///
/// 수집 항목 각각이 실패해도 나머지는 계속 진행되며, 해당 파일에
/// "unavailable: <이유>" 를 기록하고 zip 에 포함한다.
///
/// 민감정보 주의 — 자사 subsystem(`com.jadhvank.eclam`) 로그만 수집하고,
/// 환경변수·홈 경로 외 개인정보는 수집하지 않는다.
enum DiagnosticsExporter {

    // MARK: - Public API

    /// 진단 번들을 ~/Desktop 에 zip 으로 내보낸다.
    /// - Returns: 생성된 zip URL, 실패 시 nil.
    static func export() -> URL? {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        collectAgents(into: tmp)
        collectStatus(into: tmp)
        collectLog(into: tmp)
        collectHistory(into: tmp)
        collectSysinfo(into: tmp)
        collectBundleEnvironment(into: tmp)

        return zipAndPlace(source: tmp)
    }

    // MARK: - Collectors

    /// `eclam debug agents` 출력 → agents.txt
    private static func collectAgents(into dir: URL) {
        let dest = dir.appendingPathComponent("agents.txt")
        let execPath = Bundle.main.executablePath ?? ""
        guard !execPath.isEmpty,
              let out = Subprocess.capture(execPath, ["debug", "agents"]) else {
            write("unavailable: executable not found or capture failed", to: dest)
            return
        }
        write(out, to: dest)
    }

    /// `eclam status` 출력 → status.txt
    private static func collectStatus(into dir: URL) {
        let dest = dir.appendingPathComponent("status.txt")
        let execPath = Bundle.main.executablePath ?? ""
        guard !execPath.isEmpty,
              let out = Subprocess.capture(execPath, ["status"]) else {
            write("unavailable: executable not found or capture failed", to: dest)
            return
        }
        write(out, to: dest)
    }

    /// `/usr/bin/log show` — 자사 subsystem 최근 30분 → log.txt
    ///
    /// 풀패스(`/usr/bin/log`) 사용 필수 — zsh `log` 빌트인과 혼동 방지.
    private static func collectLog(into dir: URL) {
        let dest = dir.appendingPathComponent("log.txt")
        // 10m + 30s 타임아웃: log show 는 아카이브 크기에 따라 시간/메모리를
        // 폭식할 수 있다 — 2026-06-11 스왑 포화 사고의 마지막 지푸라기가
        // 정확히 이 호출(30m, 무제한)이었다.
        let out = Subprocess.capture(
            "/usr/bin/log",
            [
                "show",
                "--predicate", "subsystem == \"com.jadhvank.eclam\"",
                "--last", "10m",
                "--style", "compact",
            ],
            timeoutSeconds: 30
        )
        if let out = out {
            write(out, to: dest)
        } else {
            write("unavailable: /usr/bin/log capture failed", to: dest)
        }
    }

    /// ~/Library/Application Support/eclam/history.json 복사 → history.json
    private static func collectHistory(into dir: URL) {
        let src = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("eclam/history.json")
        let dest = dir.appendingPathComponent("history.json")
        guard let src = src, FileManager.default.fileExists(atPath: src.path) else {
            write("{\"unavailable\": \"history.json not found\"}", to: dest)
            return
        }
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            write("{\"unavailable\": \"\(error.localizedDescription)\"}", to: dest)
        }
    }

    /// sw_vers + sysctl hw.model + 앱 번들 버전 → sysinfo.txt
    private static func collectSysinfo(into dir: URL) {
        let dest = dir.appendingPathComponent("sysinfo.txt")
        var lines: [String] = []

        // sw_vers
        if let v = Subprocess.capture("/usr/bin/sw_vers", []) {
            lines.append(v.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            lines.append("sw_vers: unavailable")
        }
        lines.append("")

        // hw.model
        if let model = Subprocess.capture("/usr/sbin/sysctl", ["-n", "hw.model"]) {
            lines.append("hw.model: \(model.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            lines.append("hw.model: unavailable")
        }
        lines.append("")

        // 앱 버전 (Info.plist CFBundleShortVersionString)
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        lines.append("eclam version: \(appVersion) (\(buildNumber))")

        write(lines.joined(separator: "\n"), to: dest)
    }

    /// ADR-0039 — 번들 환경(중복본 · launchctl helper job · 설치 위치 차단 판정) →
    /// bundle-env.txt. 원격 제보에서 split-brain / EX_CONFIG(spawn failed) 원인을
    /// 추적 가능하게 한다. 각 소스는 빈 결과/nil 을 자체적으로 처리하므로(throw 없음)
    /// 기존 수집기처럼 실패는 파일 안의 안내 문자열로 격리된다.
    private static func collectBundleEnvironment(into dir: URL) {
        let dest = dir.appendingPathComponent("bundle-env.txt")
        var lines: [String] = []

        // BundleScan.copies() — 같은 bundle id 복사본 (Spotlight off/무결과면 빈 목록)
        lines.append("== bundle copies (mdfind) ==")
        let copies = BundleScan.copies()
        if copies.isEmpty {
            lines.append("mdfind: no copies found")
        } else {
            for c in copies {
                lines.append("\(c.shortVersion ?? "?")  \(c.path)  (inApplications: \(c.inApplications))")
            }
        }
        lines.append("")

        // LaunchctlInspect.helperJob() — helper 데몬 job 상태 (미적재면 nil)
        lines.append("== helper job (launchctl) ==")
        if let job = LaunchctlInspect.helperJob() {
            lines.append("jobState: \(job.jobState ?? "?")")
            lines.append("lastExitCode: \(job.lastExitCode.map(String.init) ?? "?")")
            lines.append("parentBundleVersion: \(job.parentBundleVersion ?? "?")")
            lines.append("spawnFailed: \(job.spawnFailed)")
        } else {
            lines.append("launchctl: job not loaded")
        }
        lines.append("")

        // InstallLocation.registrationBlock() — 등록 차단 판정(quarantine/translocation)
        lines.append("== install location ==")
        if let block = InstallLocation.registrationBlock(bundlePath: Bundle.main.bundlePath) {
            lines.append("registrationBlock: \(block.kind.rawValue)")
        } else {
            lines.append("registrationBlock: none")
        }

        write(lines.joined(separator: "\n"), to: dest)
    }

    // MARK: - Zip & Place

    /// 임시 디렉터리 내용을 ~/Desktop/eclam-diagnostics-YYYYMMDD-HHmmss.zip 으로 압축.
    private static func zipAndPlace(source: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let zipName = "eclam-diagnostics-\(stamp).zip"

        let desktop = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let zipURL = desktop.appendingPathComponent(zipName)

        // /usr/bin/ditto -c -k --sequesterRsrc <src> <dst>
        guard Subprocess.capture(
            "/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", source.path, zipURL.path]
        ) != nil else {
            return nil
        }

        // ditto 성공 여부는 파일 존재로 재확인 (ditto 는 실패해도 exit 0 가능)
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            return nil
        }

        return zipURL
    }

    // MARK: - Helpers

    private static func makeTempDir() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eclam-diagnostics-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func write(_ content: String, to url: URL) {
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
