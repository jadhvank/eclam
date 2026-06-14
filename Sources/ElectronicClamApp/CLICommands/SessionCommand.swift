import Darwin
import Dispatch
import Foundation

/// `eclam session start|stop|list` — named work sessions that block idle
/// sleep while the foreground CLI process is alive. ADR-0007 §A/§C (v0.3.2).
///
/// Protocol (shared with `AgentDetector.SessionWatcher`):
///
///   - Directory: `<NSTemporaryDirectory()>/eclam_sessions/` (mode 0700).
///   - Filename: sanitized session name — lowercased, `[a-z0-9_-]` only,
///     max 64 chars. No path separators, no traversal.
///   - File contents (line-based plain text, ASCII):
///       line 1: decimal PID of the foreground `session start` process
///       line 2 (optional): the `--message` argument verbatim
///     No trailing newline beyond what's needed to separate the two lines.
///   - mtime: refreshed every 5s by `start` while it owns the file.
///   - Alive rule: file exists AND `mtime > now - 30s` AND `kill(pid, 0)` does
///     not fail with `ESRCH`.
///
/// `SessionCommand` only writes / heartbeats / cleans up the file. The
/// detector / `SessionWatcher` parses the directory independently.
enum SessionCommand: CLISubcommand {
    static func run(args: [String]) -> Int32 {
        guard let sub = args.first else {
            CLIStderr.print(usage)
            return 1
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "start": return SessionStart.run(args: rest)
        case "stop":  return SessionStop.run(args: rest)
        case "list":  return SessionList.run(args: rest)
        case "-h", "--help", "help":
            print(usage)
            return 0
        default:
            CLIStderr.print("eclam session: unknown subcommand '\(sub)'.")
            CLIStderr.print(usage)
            return 1
        }
    }

    static let usage = """
    usage:
      eclam session start <name> [--message <text>] [--json]
      eclam session stop <name>
      eclam session list [--json]
    """
}

// MARK: - Shared helpers (ADR-0007 §C session protocol)

private enum SessionFS {
    /// Directory all session files live in.
    static func sessionsDir() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("eclam_sessions", isDirectory: true)
    }

    /// Create the sessions directory if missing, with 0700 perms so a shared
    /// `/tmp` doesn't leak session names / messages across users.
    @discardableResult
    static func ensureDir() -> URL {
        let dir = sessionsDir()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        } else {
            // Tighten perms in case a previous run created it loosely.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        return dir
    }

    /// Lowercased, `[a-z0-9_-]` only, 1..64 chars. Returns nil for any input
    /// that could be a path traversal or contain separators.
    static func sanitize(_ name: String) -> String? {
        let lower = name.lowercased()
        if lower.isEmpty || lower.count > 64 { return nil }
        for ch in lower.unicodeScalars {
            let ok = (ch >= "a" && ch <= "z")
                  || (ch >= "0" && ch <= "9")
                  || ch == "_" || ch == "-"
            if !ok { return nil }
        }
        // Defense in depth — these should already be impossible above.
        if lower.contains("/") || lower.contains("\\") || lower == "." || lower == ".." {
            return nil
        }
        return lower
    }

    /// Validate a `--message` string. ASCII printable + space only, max 200.
    static func validateMessage(_ text: String) -> String? {
        if text.count > 200 { return nil }
        for ch in text.unicodeScalars {
            let v = ch.value
            // Printable ASCII (space..~). Disallow CR/LF so the second line
            // stays single-line.
            if v < 0x20 || v > 0x7E { return nil }
        }
        return text
    }

    static func fileURL(forSanitized name: String) -> URL {
        return ensureDir().appendingPathComponent(name, isDirectory: false)
    }

    /// Parse a session file. Returns (pid, message?) or nil on malformed input.
    static func parse(_ url: URL) -> (pid: pid_t, message: String?)? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first,
              let pid = pid_t(first.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        var message: String? = nil
        if lines.count >= 2 {
            let m = String(lines[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if !m.isEmpty { message = m }
        }
        return (pid, message)
    }

    /// `kill(pid, 0)` succeeds (or fails with EPERM) for live processes; only
    /// `ESRCH` proves the process is gone.
    static func isAlive(pid: pid_t) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// mtime of a file in seconds since 1970, or nil.
    static func mtime(_ url: URL) -> TimeInterval? {
        var st = stat()
        if stat(url.path, &st) != 0 { return nil }
        return TimeInterval(st.st_mtimespec.tv_sec)
             + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    /// Refresh mtime to now without rewriting contents. Mirrors `touch`.
    static func touch(_ url: URL) {
        // utimensat(AT_FDCWD, path, NULL, 0) sets both atime and mtime to now.
        _ = url.path.withCString { cstr in
            utimensat(AT_FDCWD, cstr, nil, 0)
        }
    }

    /// Atomic write: tmp file in the same dir then `rename(2)`.
    static func writeAtomic(_ url: URL, contents: String) -> Bool {
        guard let data = contents.data(using: .utf8) else { return false }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid())")
        do {
            try data.write(to: tmp, options: [.atomic])
            // Restrict to owner-only just like the dir.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: tmp.path)
            // rename(2) is atomic within the same filesystem.
            let ok = tmp.path.withCString { src in
                url.path.withCString { dst in
                    rename(src, dst) == 0
                }
            }
            if !ok {
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}

// MARK: - `eclam session start`

private enum SessionStart {
    static func run(args: [String]) -> Int32 {
        // Parse args.
        var positional: [String] = []
        var message: String? = nil
        var json = false
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--message":
                guard i + 1 < args.count else {
                    CLIStderr.print("eclam session start: --message requires a value.")
                    return 1
                }
                let raw = args[i + 1]
                guard let m = SessionFS.validateMessage(raw) else {
                    CLIStderr.print("eclam session start: --message must be ASCII printable, max 200 chars.")
                    return 1
                }
                message = m
                i += 2
            case "--json":
                json = true
                i += 1
            case "-h", "--help":
                print(SessionCommand.usage)
                return 0
            default:
                if a.hasPrefix("--") {
                    CLIStderr.print("eclam session start: unknown option '\(a)'.")
                    return 1
                }
                positional.append(a)
                i += 1
            }
        }
        guard let rawName = positional.first else {
            CLIStderr.print("usage: eclam session start <name> [--message <text>] [--json]")
            return 1
        }
        if positional.count > 1 {
            CLIStderr.print("eclam session start: unexpected extra arguments.")
            return 1
        }
        guard let name = SessionFS.sanitize(rawName) else {
            CLIStderr.print("eclam session start: invalid name '\(rawName)'. Allowed: 1-64 chars of [a-z0-9_-] (case-insensitive).")
            return 1
        }

        let url = SessionFS.fileURL(forSanitized: name)

        // Collision check. If a live session owns the file, refuse.
        if FileManager.default.fileExists(atPath: url.path) {
            if let parsed = SessionFS.parse(url),
               SessionFS.isAlive(pid: parsed.pid),
               let mt = SessionFS.mtime(url),
               Date().timeIntervalSince1970 - mt < 30 {
                CLIStderr.print("eclam session start: session '\(name)' already running (pid=\(parsed.pid)).")
                return 1
            }
            // Stale (dead pid or aged-out mtime) — overwrite.
            try? FileManager.default.removeItem(at: url)
        }

        // Write our pid + optional message atomically.
        let myPid = getpid()
        var body = "\(myPid)"
        if let m = message { body += "\n\(m)" }
        guard SessionFS.writeAtomic(url, contents: body) else {
            CLIStderr.print("eclam session start: failed to write session file at \(url.path).")
            return 1
        }

        // Install signal handlers BEFORE entering the keep-alive loop so a
        // signal during setup also cleans up.
        SessionSignalTrap.install(url: url)

        // Heartbeat timer: touch mtime every 5s.
        let queue = DispatchQueue(label: "com.jadhvank.eclam.session.tick")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0, leeway: .milliseconds(500))
        timer.setEventHandler {
            // If the file disappeared (manual `session stop` from another
            // shell), bail out gracefully so we don't recreate it on touch.
            if !FileManager.default.fileExists(atPath: url.path) {
                SessionSignalTrap.fireExit(reason: .fileGone)
                return
            }
            SessionFS.touch(url)
        }
        timer.resume()
        SessionSignalTrap.attachTimer(timer)

        // Emit startup line.
        if json {
            emitJSON([
                "event": "start",
                "name": name,
                "pid": Int(myPid),
                "message": message as Any,
            ])
        } else {
            let suffix = message.map { " — \($0)" } ?? ""
            print("eclam session '\(name)' started (pid=\(myPid)).\(suffix) Ctrl-C to stop.")
        }

        // Park the main thread until a signal fires. `dispatchMain()` never
        // returns; we exit from the signal handler with the right code.
        dispatchMain()
    }

    private static func emitJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }
}

/// Signal plumbing for `session start`.
///
/// The original design installed a C `signal()` handler that called straight
/// into `fireExit` — i.e. `NSLock.lock()`, `FileManager.removeItem`, file
/// read + parse, all from *signal context*. None of that is async-signal-safe
/// (POSIX limits handlers to a short allowlist; malloc/objc/Foundation are
/// not on it). A SIGINT landing while the heartbeat queue held the malloc
/// lock could deadlock or corrupt the heap.
///
/// Now the signal disposition is `SIG_IGN` (nothing at all runs in signal
/// context) and delivery happens via `DispatchSource.makeSignalSource` on a
/// private serial queue, so the cleanup runs in a normal execution context.
/// KeepCommand uses the same dispatch-source pattern; WatchCommand's handlers
/// stay flag-only (its timer loop polls the flag, so nothing else is needed).
private final class SessionSignalState {
    var url: URL?
    var timer: DispatchSourceTimer?
    var signalSources: [DispatchSourceSignal] = []   // kept alive for process lifetime
    var fired: Bool = false      // re-entrancy guard
    let lock = NSLock()
}
private let sessionSignalState = SessionSignalState()

private enum SessionExitReason {
    case userCancel    // SIGINT/SIGTERM/SIGHUP/SIGQUIT
    case fileGone      // file deleted from under us by `session stop`
}

private enum SessionSignalTrap {
    /// Serial queue where signal delivery and cleanup run — never in signal
    /// context.
    private static let signalQueue =
        DispatchQueue(label: "com.jadhvank.eclam.session.signal")

    static func install(url: URL) {
        sessionSignalState.lock.lock()
        sessionSignalState.url = url
        sessionSignalState.lock.unlock()

        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            // SIG_IGN first: the default disposition would terminate the
            // process before the dispatch source could deliver. Ignored
            // signals are still observable through kqueue (EVFILT_SIGNAL),
            // which is what dispatch signal sources use.
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig,
                                                      queue: signalQueue)
            src.setEventHandler {
                SessionSignalTrap.fireExit(reason: .userCancel)
            }
            src.resume()
            sessionSignalState.lock.lock()
            sessionSignalState.signalSources.append(src)
            sessionSignalState.lock.unlock()
        }
    }

    static func attachTimer(_ t: DispatchSourceTimer) {
        sessionSignalState.lock.lock()
        sessionSignalState.timer = t
        sessionSignalState.lock.unlock()
    }

    /// Idempotent cleanup. Removes the session file (if we still own it) and
    /// terminates the process with the appropriate exit code. Runs on
    /// `signalQueue` (signal path) or the heartbeat queue (fileGone path) —
    /// the `fired` guard serializes the two.
    static func fireExit(reason: SessionExitReason) {
        sessionSignalState.lock.lock()
        if sessionSignalState.fired {
            sessionSignalState.lock.unlock()
            return
        }
        sessionSignalState.fired = true
        let url = sessionSignalState.url
        let timer = sessionSignalState.timer
        sessionSignalState.lock.unlock()

        timer?.cancel()
        if let url = url {
            // Only remove if it still points at us — if `stop` from another
            // shell already removed it (or replaced it), leave it alone.
            if let parsed = SessionFS.parse(url), parsed.pid == getpid() {
                try? FileManager.default.removeItem(at: url)
            } else if !FileManager.default.fileExists(atPath: url.path) {
                // already gone; nothing to do
            } else {
                // Foreign file content — don't touch.
            }
        }

        switch reason {
        case .userCancel: _exit(4)
        case .fileGone:   _exit(0)
        }
    }
}

// MARK: - `eclam session stop`

private enum SessionStop {
    static func run(args: [String]) -> Int32 {
        guard let rawName = args.first else {
            CLIStderr.print("usage: eclam session stop <name>")
            return 1
        }
        if args.count > 1 {
            CLIStderr.print("eclam session stop: unexpected extra arguments.")
            return 1
        }
        guard let name = SessionFS.sanitize(rawName) else {
            CLIStderr.print("eclam session stop: invalid name '\(rawName)'.")
            return 1
        }
        let url = SessionFS.fileURL(forSanitized: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            CLIStderr.print("eclam session stop: no such session '\(name)'.")
            return 1
        }

        // Best-effort SIGTERM the foreground owner. Ignore ESRCH (dead already).
        if let parsed = SessionFS.parse(url) {
            if kill(parsed.pid, SIGTERM) != 0 {
                let saved = errno
                if saved != ESRCH && saved != EPERM {
                    CLIStderr.print("eclam session stop: kill(\(parsed.pid)) failed: \(String(cString: strerror(saved)))")
                    // continue — we still want to delete the file
                }
            }
        }

        // Idempotent file removal.
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // If it vanished between exists() and removeItem, that's fine.
            if FileManager.default.fileExists(atPath: url.path) {
                CLIStderr.print("eclam session stop: failed to remove \(url.path): \(error.localizedDescription)")
                return 1
            }
        }

        print("eclam session '\(name)' stopped.")
        return 0
    }
}

// MARK: - `eclam session list`

private enum SessionList {
    static func run(args: [String]) -> Int32 {
        var json = false
        for a in args {
            switch a {
            case "--json": json = true
            case "-h", "--help":
                print(SessionCommand.usage)
                return 0
            default:
                CLIStderr.print("eclam session list: unknown option '\(a)'.")
                return 1
            }
        }

        let dir = SessionFS.ensureDir()
        let fm = FileManager.default
        let entries: [URL]
        if let listed = try? fm.contentsOfDirectory(at: dir,
                                                    includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles]) {
            entries = listed.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            entries = []
        }

        struct Row {
            let name: String
            let pid: pid_t
            let alive: Bool
            let ageSeconds: Int
            let message: String?
        }
        var rows: [Row] = []
        let now = Date().timeIntervalSince1970
        for url in entries {
            let name = url.lastPathComponent
            // Skip stray tmp files from a crashed atomic write.
            if name.hasPrefix(".") { continue }
            guard let parsed = SessionFS.parse(url) else { continue }
            let mt = SessionFS.mtime(url) ?? now
            let age = max(0, Int(now - mt))
            let alive = SessionFS.isAlive(pid: parsed.pid) && (now - mt) < 30
            rows.append(Row(name: name,
                            pid: parsed.pid,
                            alive: alive,
                            ageSeconds: age,
                            message: parsed.message))
        }

        if json {
            let array: [[String: Any]] = rows.map { r in
                var d: [String: Any] = [
                    "name": r.name,
                    "pid": Int(r.pid),
                    "alive": r.alive,
                    "ageSeconds": r.ageSeconds,
                ]
                if let m = r.message { d["message"] = m } else { d["message"] = NSNull() }
                return d
            }
            if let data = try? JSONSerialization.data(withJSONObject: array,
                                                      options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            } else {
                print("[]")
            }
            return 0
        }

        if rows.isEmpty {
            print("(none)")
            return 0
        }
        // Human table.
        print("NAME                             PID    ALIVE  AGE   MESSAGE")
        for r in rows {
            let name = r.name.padding(toLength: 32, withPad: " ", startingAt: 0)
            let pid = String(r.pid).padding(toLength: 6, withPad: " ", startingAt: 0)
            let alive = (r.alive ? "yes" : "no").padding(toLength: 5, withPad: " ", startingAt: 0)
            let age = "\(r.ageSeconds)s".padding(toLength: 5, withPad: " ", startingAt: 0)
            let msg = r.message ?? "-"
            print("\(name) \(pid) \(alive)  \(age) \(msg)")
        }
        return 0
    }
}
