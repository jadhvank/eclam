import Foundation
import Darwin

/// Shared GUI/CLI file probe. Filter eligible workspaces and invalid clocks
/// before selecting a winner, so one unrelated or future-dated file cannot
/// suppress a valid active session. Reads metadata only.
enum AgentMtimeProbe {
    static func freshest(paths: [String], now: Date,
                         claudeWorkspaces: Set<String>? = nil) -> AgentActivity.MtimeMatch? {
        var best: AgentActivity.MtimeMatch?
        for path in paths {
            if let workspaces = claudeWorkspaces {
                guard let segment = ClaudeWorkspacePathing.projectSegment(fromMatchedPath: path),
                      workspaces.contains(segment) else { continue }
            }
            var info = stat()
            guard stat(path, &info) == 0 else { continue }
            let modified = TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            let age = now.timeIntervalSince1970 - modified
            guard AgentActivity.isPlausibleAge(age) else { continue }
            if best == nil || age < best!.age {
                best = .init(path: path, age: age)
            }
        }
        return best
    }
}
