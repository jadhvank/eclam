import Foundation

@main enum AgentTraceTests {
    static func main() throws {
        let minimal = Data(#"{"id":"external","label":"External","globPattern":"/tmp/*.jsonl"}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentTrace.self, from: minimal)
        precondition(decoded.freshness == 60 && decoded.hookKey == nil && decoded.comm == nil)
        let explicit = AgentTrace(id: "explicit", label: "Explicit", globPattern: "/tmp/*.jsonl",
                                  freshness: 90, hookKey: "explicit", comm: "agent")
        let roundTrip = try JSONDecoder().decode(AgentTrace.self, from: JSONEncoder().encode(explicit))
        precondition(roundTrip == explicit)
        let override = AgentTrace(id: "claude", label: "External Claude", globPattern: "/external/*.jsonl")
        let custom = AgentTrace(id: "claude", label: "My Claude", globPattern: "/custom/*.jsonl")
        let externalPool = AgentTrace.resolved(external: [decoded, override], custom: [])
        precondition(externalPool.first == override)
        precondition(externalPool.contains(decoded), "external agents must be selectable in both watch lists")
        let customPool = AgentTrace.resolved(external: [decoded, override], custom: [custom])
        precondition(customPool.first == custom)
        precondition(customPool.filter { $0.id == "claude" }.count == 1)
        precondition(customPool.map(\.id).prefix(AgentTrace.M1Defaults.count) == AgentTrace.M1Defaults.map(\.id)[...])
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("eclam-omp-glob-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let paths = ["project/parent.jsonl", "project/parent/child.jsonl",
                     "project/parent/child/nested.jsonl", "project/parent/child/nested/deeper.jsonl"]
        for path in paths {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        for (id, expected) in zip(["omp", "omp-subagents", "omp-subagents-nested"], paths) {
            let trace = AgentTrace.M1Defaults.first { $0.id == id }!
            let pattern = trace.globPattern.replacingOccurrences(of: "~/.omp/agent/sessions", with: root.path)
            precondition(Set(Glob.expand(pattern)) == [root.appendingPathComponent(expected).path])
            precondition(trace.freshness == 90 && trace.comm == nil)
        }
        precondition(AgentTrace.M1Defaults.first { $0.id == "omp" }!.hookKey == "omp")
        print("PASS omp glob: parent, child, one nested level; deeper paths excluded")
        print("PASS trace decoding: omitted freshness defaults to 60; explicit fields round-trip")
        print("PASS trace catalog: external visibility, override precedence, stable default order")
    }
}
