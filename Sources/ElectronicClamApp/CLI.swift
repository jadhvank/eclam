import Foundation

/// ADR-0007 — CLI dispatch. Argv branch is evaluated in `main.swift` BEFORE
/// any AppKit/`NSApplication.shared` reference so the CLI works in headless
/// contexts (SSH, CI runners, …) without a window server.
///
/// `dispatch` returns:
///   - `Int32` — caller should `exit()` with that code (recognized CLI command).
///   - `nil`   — argv is not a CLI command; caller proceeds to GUI bootstrap.
enum CLI {
    static func dispatch(_ args: [String]) -> Int32? {
        guard let first = args.first else { return nil }
        switch first {
        case "on":      return OnCommand.run(args: Array(args.dropFirst()))
        case "off":     return OffCommand.run(args: Array(args.dropFirst()))
        case "status":  return StatusCommand.run(args: Array(args.dropFirst()))
        case "keep":    return KeepCommand.run(args: Array(args.dropFirst()))
        case "watch":   return WatchCommand.run(args: Array(args.dropFirst()))
        case "session": return SessionCommand.run(args: Array(args.dropFirst()))
        case "debug":   return DebugCommand.run(args: Array(args.dropFirst()))
        case "help", "-h", "--help":
            HelpCommand.printUsage()
            return 0
        default:
            // Preserve back-compat for `--debug-agents` (handled in main.swift)
            // and any future GUI-only flags; anything else falls through to GUI
            // mode. We DO NOT print "unknown command" here — that would break
            // the legacy `ElectronicClam --debug-agents` form.
            return nil
        }
    }
}

protocol CLISubcommand {
    static func run(args: [String]) -> Int32
}

/// Shared stderr printer for CLI handlers. Avoids `FileHandle.standardError`
/// boilerplate at every call site. Data goes to stdout via `print(...)`.
enum CLIStderr {
    static func print(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
