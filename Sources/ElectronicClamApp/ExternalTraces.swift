import Foundation
import OSLog

/// proposal §1 — 외부 trace 선언 로더.
///
/// `~/.config/eclam/traces.d/*.json` 의 `AgentTrace` JSON(단일 객체 또는
/// 배열)을 읽어 known pool 에 합류시킨다. 형식은 `AgentTrace` 의 Codable
/// 그대로: `id`/`label`/`globPattern` (+선택 `freshness`/`hookKey`/`comm`).
/// 새 에이전트를 코드 수정 없이 지원하는 통로이자 커뮤니티 기여 포맷
/// (`traces/README.md`).
///
/// - 잘못된 파일은 경고 로그 후 무시 (전체 로딩은 계속).
/// - `tracesToWatch()` 가 converge 마다 부르므로 5s 스로틀 캐시.
/// - 입력 cap (ADR-0023 정신): 파일 ≤64개, 합계 trace ≤128개, id 는
///   `sanitizeActivitySource` 통과 + 비어있지 않아야 채택.
enum ExternalTraces {
    private static let log = Logger(subsystem: "com.jadhvank.eclam", category: "traces")
    private static let lock = NSLock()
    private static var cached: [AgentTrace] = []
    private static var lastScan: Date = .distantPast
    private static var loggedFiles: Set<String> = []

    static var directory: String { NSHomeDirectory() + "/.config/eclam/traces.d" }

    static func load(now: Date = Date()) -> [AgentTrace] {
        lock.lock(); defer { lock.unlock() }
        if now.timeIntervalSince(lastScan) < 5 { return cached }
        lastScan = now

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else {
            cached = []
            return []
        }
        var out: [AgentTrace] = []
        let decoder = JSONDecoder()
        for name in entries.sorted().prefix(64) where name.hasSuffix(".json") {
            let path = directory + "/" + name
            guard let data = fm.contents(atPath: path) else { continue }
            var traces: [AgentTrace] = []
            if let arr = try? decoder.decode([AgentTrace].self, from: data) {
                traces = arr
            } else if let one = try? decoder.decode(AgentTrace.self, from: data) {
                traces = [one]
            } else {
                if !loggedFiles.contains(name) {
                    loggedFiles.insert(name)
                    log.warning("traces.d/\(name, privacy: .public): not valid AgentTrace JSON — skipped")
                }
                continue
            }
            for t in traces {
                let cleanId = HelperServiceName.sanitizeActivitySource(t.id)
                guard !cleanId.isEmpty, cleanId == t.id else {
                    if !loggedFiles.contains(name + ":" + t.id) {
                        loggedFiles.insert(name + ":" + t.id)
                        log.warning("traces.d/\(name, privacy: .public): id '\(t.id, privacy: .public)' rejected (lowercase [a-z0-9_-.] only)")
                    }
                    continue
                }
                out.append(t)
                if out.count >= 128 { break }
            }
            if out.count >= 128 { break }
        }
        if out.count != cached.count {
            log.info("external traces loaded: \(out.count, privacy: .public)")
        }
        cached = out
        return out
    }
}
