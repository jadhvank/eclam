import Foundation

/// ADR-0006 §M — `--debug-agents` subcommand.
///
/// Wires up a `StateStore` + `AgentDetector` exactly like the app does, but
/// without starting `NSApplication.shared.run()`, the menu bar, or any helper
/// XPC. Runs ONE detector tick synchronously and prints the resulting state.
///
/// Field-triage entry point. `awake debug-codex` inspired.
enum DebugAgentsCommand {
    static func run(json: Bool) {
        let store = StateStore()
        let detector = AgentDetector()
        // For debug we surface ALL known traces (defaults + customs), not just
        // the user-enabled subset — operators are usually asking "why isn't X
        // firing", so an unchecked trace should still appear with its status.
        detector.setTraces(store.allKnownTraces())
        let snap = detector.debugSnapshot()

        if json {
            printJSON(snap)
        } else {
            printTable(snap)
        }
    }

    // MARK: - Table

    private static func printTable(_ snap: AgentDetectorDebugSnapshot) {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]

        print("Electronic Clam agent-detector debug snapshot")
        print("  generated: \(fmt.string(from: snap.generatedAt))")
        let activeList = snap.active.sorted().joined(separator: ", ")
        print("  active   : \(activeList.isEmpty ? "(none)" : activeList)")
        print("")

        print("Traces:")
        print("  " + pad("label", 12) + " " + pad("active", 6) + " " +
              pad("age(s)", 8) + " " + pad("glob", 50) + " reason")
        for row in snap.traces {
            let age = row.mtimeAge.map { String(format: "%.1f", $0) } ?? "-"
            print("  " + pad(row.label, 12) + " " +
                  pad(row.active ? "YES" : "no", 6) + " " +
                  pad(age, 8) + " " +
                  pad(truncate(row.glob, 50), 50) + " " + row.reason)
            if let path = row.latestMatch {
                print("              path: \(path)")
            }
        }
        print("")

        print("Hook pings (Darwin notify):")
        if snap.hookPings.isEmpty {
            print("  (none received this process lifetime)")
        } else {
            let now = Date()
            for (k, t) in snap.hookPings.sorted(by: { $0.0 < $1.0 }) {
                let age = now.timeIntervalSince(t)
                print("  " + pad(k, 12) + String(format: " age=%.1fs", age))
            }
        }
        print("")

        print("Live `claude` process workspaces (sanitized cwds):")
        if snap.liveClaudeWorkspaces.isEmpty {
            print("  (none — pairing skipped or no claude proc running)")
        } else {
            for w in snap.liveClaudeWorkspaces.sorted() {
                print("  \(w)")
            }
        }
        print("")

        print("PID-file fallback (/tmp/eclam_working_pids/*):")
        if snap.pidFileSources.isEmpty {
            print("  (no fresh entries)")
        } else {
            for s in snap.pidFileSources.sorted() {
                print("  \(s)")
            }
        }
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        if s.count <= n { return s }
        let i = s.index(s.startIndex, offsetBy: n - 1)
        return String(s[..<i]) + "…"
    }

    // MARK: - JSON

    private static func printJSON(_ snap: AgentDetectorDebugSnapshot) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var traceArr: [[String: Any]] = []
        for row in snap.traces {
            var d: [String: Any] = [
                "label": row.label,
                "glob": row.glob,
                "active": row.active,
                "reason": row.reason,
            ]
            if let p = row.latestMatch { d["latestMatch"] = p }
            if let a = row.mtimeAge { d["mtimeAgeSeconds"] = a }
            traceArr.append(d)
        }

        var hookArr: [[String: Any]] = []
        let now = Date()
        for (k, t) in snap.hookPings {
            hookArr.append([
                "source": k,
                "stamp": iso.string(from: t),
                "ageSeconds": now.timeIntervalSince(t),
            ])
        }

        let root: [String: Any] = [
            "generatedAt": iso.string(from: snap.generatedAt),
            "active": snap.active.sorted(),
            "traces": traceArr,
            "hookPings": hookArr,
            "liveClaudeWorkspaces": Array(snap.liveClaudeWorkspaces).sorted(),
            "pidFileSources": snap.pidFileSources.sorted(),
        ]

        if let data = try? JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}
