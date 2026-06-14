import AppKit
import Foundation

// ADR-0007 §B/§F — CLI dispatch MUST run before any AppKit / NSApplication
// reference so that headless contexts (SSH, CI) don't crash trying to attach
// to the window server. `CLI.dispatch` returns nil when argv is not a CLI
// command, letting us fall through to GUI bootstrap.
let argv = Array(CommandLine.arguments.dropFirst())
if let exitCode = CLI.dispatch(argv) {
    exit(exitCode)
}

// ADR-0006 §M — back-compat: the v0.2.1 `--debug-agents` flag form has no
// leading subcommand, so `CLI.dispatch` returns nil and we land here.
if argv.contains("--debug-agents") {
    let json = argv.contains("--json")
    DebugAgentsCommand.run(json: json)
    exit(0)
}

// macOS 13 guard before any AppKit work that depends on SMAppService.
let osv = ProcessInfo.processInfo.operatingSystemVersion
if osv.majorVersion < 13 {
    let alert = NSAlert()
    alert.messageText = "macOS 13.0 Ventura or later is required."
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    _ = alert.runModal()
    exit(EXIT_FAILURE)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
