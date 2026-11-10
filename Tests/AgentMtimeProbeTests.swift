import Foundation

@main
enum AgentMtimeProbeTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func transcript(_ workspace: String, age: Double) throws -> String {
            let file = root.appendingPathComponent(".claude/projects/-\(workspace)/session.jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
            return file.path
        }
        let activeA = try transcript("A", age: 10)
        let stoppedB = try transcript("B", age: 1)
        let future = try transcript("future", age: -86400)
        let paths = [stoppedB, future, activeA]
        let paired = AgentMtimeProbe.freshest(paths: paths, now: now, claudeWorkspaces: ["A"])
        precondition(paired?.path == activeA, "newer stopped workspace must not hide active A")
        let unpaired = AgentMtimeProbe.freshest(paths: paths, now: now)
        precondition(unpaired?.path == stoppedB, "future file must not eclipse valid candidates")
        precondition(AgentMtimeProbe.freshest(paths: paths, now: now, claudeWorkspaces: ["C"]) == nil)
        precondition(AgentMtimeProbe.freshest(paths: [future], now: now) == nil)
        precondition(AgentMtimeProbe.freshest(paths: [root.appendingPathComponent("missing").path], now: now) == nil)
        let tolerated = try transcript("clock-skew", age: -5)
        precondition(AgentMtimeProbe.freshest(paths: [tolerated], now: now) != nil)
        print("PASS transcript selection: live workspace first, future exclusion, tolerance, missing file")
    }
}
