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
