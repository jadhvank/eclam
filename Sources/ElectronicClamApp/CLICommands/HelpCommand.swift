import Foundation

/// `eclam help` — static usage block.
enum HelpCommand: CLISubcommand {
    static let usage = """
    Electronic Clam — menu bar utility to keep macOS awake while agents work.

    USAGE:
      eclam on [--for <dur>] [--forever]   (default: auto-release in 2h)
      eclam off
      eclam status [--json]
      eclam repair                         (repair a wedged/unreachable helper)
      eclam keep --while <pid>
      eclam watch <agent> [--grace s] [--check-interval s] [--max minutes] [--json]
      eclam session start <name> [--message <text>] [--json]
      eclam session stop <name>
      eclam session list [--json]
      eclam debug [agents] [--json]
      eclam help

    EXIT CODES:
      0  success
      1  bad arguments
      2  helper unreachable
      3  helper requires approval
      4  user cancel (keep / watch / session)
    """

    static func run(args: [String]) -> Int32 {
        printUsage()
        return 0
    }

    static func printUsage() {
        print(usage)
    }
}
