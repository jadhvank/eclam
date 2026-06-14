import Foundation

/// `eclam debug [agents] [--json]` — ADR-0006 §M debug snapshot.
/// `debug` alone is equivalent to `debug agents`. ADR-0007 §C.
enum DebugCommand: CLISubcommand {
    static func run(args: [String]) -> Int32 {
        // Accept: `debug`, `debug agents`, `debug --json`, `debug agents --json`.
        var positional = args.filter { !$0.hasPrefix("--") }
        let json = args.contains("--json")

        if let sub = positional.first {
            if sub == "agents" {
                positional.removeFirst()
            } else {
                CLIStderr.print("eclam debug: unknown subcommand '\(sub)'. Try `debug agents`.")
                return 1
            }
        }
        if !positional.isEmpty {
            CLIStderr.print("eclam debug: unexpected arguments: \(positional.joined(separator: " "))")
            return 1
        }

        DebugAgentsCommand.run(json: json)
        return 0
    }
}
