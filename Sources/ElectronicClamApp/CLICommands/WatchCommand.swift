import Darwin
import Dispatch
import Foundation
import ServiceManagement

// `<notify.h>` is not exposed via the Darwin umbrella module on the swiftc
// command line. Re-declare the two symbols we need by hand (stable libSystem
// ABI). Mirrors the pattern used by `AgentDetector` / `ActivityRelay`.
@_silgen_name("notify_register_dispatch")
private func notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ outToken: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @convention(block) (Int32) -> Void
) -> UInt32

@_silgen_name("notify_cancel")
private func notify_cancel(_ token: Int32) -> UInt32

private let WATCH_NOTIFY_STATUS_OK: UInt32 = 0

/// `eclam watch <agent>` — block idle sleep ONLY while `<agent>` is
/// actively working. One-shot foreground process; releases on every exit path.
/// ADR-0007 §A/§C/§D.
///
/// Resolution order for `<agent>`:
///   1. `AgentTrace.M1Defaults` id
///   2. `AgentTrace.CustomizeOnly` id
///   3. `UserDefaults.standard["CustomAgentTraces"]` (user-registered)
///   4. Path-shaped literal (`~`, `/`, `.`, or contains `*`/`?`) → ad-hoc trace
///
/// Activity = freshest glob match's mtime within `--grace` seconds, OR a
/// Darwin notify ping arrives on the trace's hook channel.
enum WatchCommand: CLISubcommand {
    static func run(args: [String]) -> Int32 {
        // ---------------- 1) Parse args ----------------
        var positional: [String] = []
        var grace: TimeInterval = 60
        var checkInterval: TimeInterval = 5
        var maxMinutes: Double = 0   // 0 ⇒ unlimited
        var json = false

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--grace":
                guard i + 1 < args.count, let v = Double(args[i + 1]), v > 0 else {
                    CLIStderr.print("eclam watch: --grace requires a positive number of seconds.")
                    return 1
                }
                grace = v
                i += 2
            case "--check-interval":
                guard i + 1 < args.count, let v = Double(args[i + 1]), v > 0 else {
                    CLIStderr.print("eclam watch: --check-interval requires a positive number of seconds.")
                    return 1
                }
                checkInterval = v
                i += 2
            case "--max":
                guard i + 1 < args.count, let v = Double(args[i + 1]), v >= 0 else {
                    CLIStderr.print("eclam watch: --max requires a non-negative number of minutes.")
                    return 1
                }
                maxMinutes = v
                i += 2
            case "--json":
                json = true
                i += 1
            case "-h", "--help":
                print(helpText)
                return 0
            default:
                if a.hasPrefix("--") {
                    CLIStderr.print("eclam watch: unknown option '\(a)'.")
                    return 1
                }
                positional.append(a)
                i += 1
            }
        }

        guard let agentArg = positional.first else {
            CLIStderr.print("usage: eclam watch <agent> [--grace s] [--check-interval s] [--max minutes] [--json]")
            return 1
        }
        if positional.count > 1 {
            CLIStderr.print("eclam watch: unexpected extra arguments: \(positional.dropFirst().joined(separator: " "))")
            return 1
        }

        // ---------------- 2) Resolve <agent> → AgentTrace ----------------
        guard let trace = resolveTrace(agentArg) else {
            CLIStderr.print("eclam watch: unknown agent '\(agentArg)'. Try one of: \(knownAgentIds().joined(separator: ", ")), or pass an explicit path/glob (starts with ~, /, ., or contains *).")
            return 1
        }

        // ---------------- 3) Helper status preflight ----------------
        let service = SMAppService.daemon(plistName: HelperRegistration.plistName)
        switch service.status {
        case .enabled:
            break
        case .requiresApproval:
            CLIStderr.print("eclam watch: helper requires approval. Open System Settings > General > Login Items & Extensions and enable Electronic Clam.")
            return 3
        case .notFound:
            CLIStderr.print("eclam watch: helper not registered (.notFound). Launch ElectronicClam.app once to register the daemon.")
            return 3
        case .notRegistered:
            CLIStderr.print("eclam watch: helper not registered. Launch ElectronicClam.app once to register the daemon.")
            return 3
        @unknown default:
            CLIStderr.print("eclam watch: helper in an unknown registration state.")
            return 3
        }

        // ---------------- 4) Open one-shot XPC connection ----------------
        let conn = NSXPCConnection(machServiceName: HelperServiceName.mach, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: ElectronicClamHelperProtocol.self)
        conn.resume()

        let session = WatchSession(
            trace: trace,
            connection: conn,
            grace: grace,
            checkInterval: checkInterval,
            maxMinutes: maxMinutes,
            json: json
        )

        return session.run()
    }

    // MARK: - Resolution

    private static func resolveTrace(_ arg: String) -> AgentTrace? {
        // 1) M1 defaults
        if let t = AgentTrace.M1Defaults.first(where: { $0.id == arg }) { return t }
        // 2) Customize-only
        if let t = AgentTrace.CustomizeOnly.first(where: { $0.id == arg }) { return t }
        // 3) UserDefaults custom traces
        if let data = UserDefaults.standard.data(forKey: "CustomAgentTraces"),
           let decoded = try? JSONDecoder().decode([AgentTrace].self, from: data),
           let t = decoded.first(where: { $0.id == arg }) {
            return t
        }
        // 4) Ad-hoc path/glob literal
        if looksLikePath(arg) {
            return AgentTrace(
                id: "adhoc",
                label: "Ad-hoc (\(arg))",
                globPattern: arg,
                freshness: 60,
                hookKey: nil
            )
        }
        return nil
    }

    private static func looksLikePath(_ s: String) -> Bool {
        if s.hasPrefix("~") || s.hasPrefix("/") || s.hasPrefix(".") { return true }
        if s.contains("*") || s.contains("?") { return true }
        return false
    }

    private static func knownAgentIds() -> [String] {
        var ids = AgentTrace.M1Defaults.map(\.id) + AgentTrace.CustomizeOnly.map(\.id)
        if let data = UserDefaults.standard.data(forKey: "CustomAgentTraces"),
           let decoded = try? JSONDecoder().decode([AgentTrace].self, from: data) {
            ids.append(contentsOf: decoded.map(\.id))
        }
        return Array(Set(ids)).sorted()
    }

    private static let helpText = """
    usage: eclam watch <agent> [--grace s] [--check-interval s] [--max minutes] [--json]

    Block idle sleep while <agent> is actively working.

    <agent> may be a default id (claude, codex, cursor, opencode,
    opencode-sessions, antigravity), a Customize-only id (aider, cline, roo,
    openhands, hermes, openclaw, openclaw-legacy, cursor-legacy), a
    user-registered CustomAgentTraces id, or a literal path/glob beginning
    with ~, /, ., or containing * / ?.

    Options:
      --grace <seconds>      Idle grace after last activity. Default 60.
      --check-interval <s>   mtime poll interval. Default 5.
      --max <minutes>        Hard cap; release & exit 0. Default 0 (unlimited).
      --json                 Emit line-delimited JSON status instead of human text.
    """
}

// MARK: - Session

/// Signal plumbing for `watch`.
///
/// The original design installed C `signal()` handlers that stored into a Swift
/// global straight from *signal context*. A bare `Bool` store is far milder
/// than the `objc_msgSend` KeepCommand used to run there, but it is still not on
/// the POSIX async-signal-safe allowlist and it raced the tick queue's read.
///
/// Same fix as KeepCommand / SessionCommand: the signal disposition is
/// `SIG_IGN` (nothing at all runs in signal context) and delivery happens via
/// `DispatchSource.makeSignalSource` on a private serial queue, so the cancel
/// flag is flipped from a normal execution context and lock-guarded against the
/// tick queue. The tick timer (≤ `checkInterval`) observes the flag and drives
/// the release — Ctrl-C latency is unchanged and bounded by the helper's 20s
/// watchdog anyway.
private final class WatchSignalState {
    var signalSources: [DispatchSourceSignal] = []   // kept alive for process lifetime
    var userCancelled: Bool = false
    var shouldExit: Bool = false
    let lock = NSLock()
}
private let watchSignalState = WatchSignalState()

private enum WatchSignalTrap {
    /// Serial queue where signal delivery runs — never in signal context.
    private static let signalQueue =
        DispatchQueue(label: "com.jadhvank.eclam.watch.signal")

    /// Lock-guarded read for the tick queue.
    static var shouldExit: Bool {
        watchSignalState.lock.lock()
        defer { watchSignalState.lock.unlock() }
        return watchSignalState.shouldExit
    }

    static func install() {
        for sig in [SIGINT, SIGTERM] {
            // SIG_IGN first: the default disposition would terminate the
            // process before the dispatch source could deliver. Ignored
            // signals are still observable through kqueue (EVFILT_SIGNAL),
            // which is what dispatch signal sources use.
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig,
                                                      queue: signalQueue)
            src.setEventHandler {
                watchSignalState.lock.lock()
                watchSignalState.userCancelled = true
                watchSignalState.shouldExit = true
                watchSignalState.lock.unlock()
            }
            src.resume()
            watchSignalState.lock.lock()
            watchSignalState.signalSources.append(src)
            watchSignalState.lock.unlock()
        }
    }
}

private final class WatchSession {
    let trace: AgentTrace
    let connection: NSXPCConnection
    let grace: TimeInterval
    let checkInterval: TimeInterval
    let maxMinutes: Double
    let json: Bool

    private var sleepEnabled: Bool = false
    private var hookToken: Int32 = -1
    private var hasHookToken: Bool = false
    private var lastHookPing: Date?
    private var lastActivity: Date?
    private var lastReportedActive: Bool?
    private let started: Date = Date()

    /// Concurrency guard for `lastHookPing` (mutated from dispatch queue).
    private let lock = NSLock()

    init(trace: AgentTrace,
         connection: NSXPCConnection,
         grace: TimeInterval,
         checkInterval: TimeInterval,
         maxMinutes: Double,
         json: Bool) {
        self.trace = trace
        self.connection = connection
        self.grace = grace
        self.checkInterval = checkInterval
        self.maxMinutes = maxMinutes
        self.json = json
    }

    func run() -> Int32 {
        WatchSignalTrap.install()

        // Try to engage sleep-disabled up front. We don't wait for activity to
        // arrive — the user invoked `watch` because they expect coverage now.
        if let err = syncSetSleepDisabled(true) {
            CLIStderr.print("eclam watch: failed to engage sleep block: \(err.localizedDescription)")
            cleanupSubscriptions()
            connection.invalidate()
            return 2
        }
        sleepEnabled = true
        lastActivity = Date()
        emitInitial()

        // Subscribe to the hook channel if this trace has one.
        if let key = trace.hookKey {
            subscribeHook(key: key)
        }

        // ---------------- Main loop ----------------
        // Use a periodic DispatchSourceTimer on a background queue so SIGINT /
        // SIGTERM don't have to interrupt a Thread.sleep call.
        let queue = DispatchQueue(label: "com.jadhvank.eclam.watch.tick")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + checkInterval,
                       repeating: checkInterval,
                       leeway: .milliseconds(250))

        let exitSem = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        var exitReason: ExitReason = .normal

        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if WatchSignalTrap.shouldExit {
                exitReason = .userCancel
                exitCode = 4
                timer.cancel()
                exitSem.signal()
                return
            }
            let outcome = self.tick(now: Date())
            switch outcome {
            case .keepGoing:
                return
            case .maxElapsed:
                exitReason = .maxElapsed
                exitCode = 0
                timer.cancel()
                exitSem.signal()
            case .idleTimeout:
                exitReason = .idleTimeout
                exitCode = 0
                timer.cancel()
                exitSem.signal()
            }
        }
        timer.resume()

        // Block this thread until the timer fires its exit condition. SIGINT
        // can't unblock a semaphore directly, so the timer (default 5s) is the
        // worst-case latency from Ctrl-C → release. That's acceptable; the
        // helper's watchdog has 20s grace anyway.
        exitSem.wait()

        // ---------------- Teardown ----------------
        // Always release sleep, even on signal paths.
        if sleepEnabled {
            _ = syncSetSleepDisabled(false)
            sleepEnabled = false
        }
        cleanupSubscriptions()
        connection.invalidate()

        emitFinal(reason: exitReason)
        return exitCode
    }

    private enum TickOutcome {
        case keepGoing
        case maxElapsed
        case idleTimeout
    }

    private enum ExitReason {
        case normal
        case userCancel
        case maxElapsed
        case idleTimeout
    }

    private func tick(now: Date) -> TickOutcome {
        // 1) mtime probe.
        let mtimeMatch = freshestMatch(pattern: trace.globPattern, now: now)
        let mtimeFresh: Bool = {
            guard let (_, age) = mtimeMatch else { return false }
            return age <= grace
        }()

        // 2) hook ping freshness.
        lock.lock()
        let hookFresh: Bool = {
            guard let last = lastHookPing else { return false }
            return now.timeIntervalSince(last) <= grace
        }()
        lock.unlock()

        let active = mtimeFresh || hookFresh
        if active {
            lastActivity = now
        }

        emitTick(now: now, active: active, mtimeMatch: mtimeMatch, hookFresh: hookFresh)

        // 3) --max hard cap.
        if maxMinutes > 0 {
            let elapsed = now.timeIntervalSince(started)
            if elapsed >= maxMinutes * 60.0 {
                return .maxElapsed
            }
        }

        // 4) Extended idle auto-release: grace * 3 since last activity.
        let staleCutoff = grace * 3
        if let last = lastActivity, now.timeIntervalSince(last) >= staleCutoff {
            return .idleTimeout
        }

        return .keepGoing
    }

    // MARK: - Output

    private func emitInitial() {
        if json {
            emitJSON([
                "event": "start",
                "agent": trace.id,
                "label": trace.label,
                "glob": trace.globPattern,
                "grace": grace,
                "checkInterval": checkInterval,
                "maxMinutes": maxMinutes,
            ])
        } else {
            print("eclam watch: engaging sleep block for \(trace.label) (id=\(trace.id), grace=\(Int(grace))s, poll=\(Int(checkInterval))s). Ctrl-C to release.")
        }
    }

    private func emitTick(now: Date,
                          active: Bool,
                          mtimeMatch: (String, TimeInterval)?,
                          hookFresh: Bool) {
        if json {
            var payload: [String: Any] = [
                "event": "tick",
                "t": iso8601(now),
                "active": active,
                "agent": trace.id,
            ]
            if let last = lastActivity {
                payload["lastActivity"] = iso8601(last)
                payload["idleSeconds"] = Int(now.timeIntervalSince(last))
            }
            if let (path, age) = mtimeMatch {
                payload["matchPath"] = path
                payload["matchAge"] = Int(age)
            }
            payload["hookFresh"] = hookFresh
            emitJSON(payload)
        } else {
            // Human mode: only log on state change to avoid spamming the terminal.
            if lastReportedActive != active {
                let stamp = humanTime(now)
                if active {
                    print("[\(stamp)] active — \(trace.label)")
                } else {
                    let idle: String
                    if let last = lastActivity {
                        idle = " (idle \(Int(now.timeIntervalSince(last)))s)"
                    } else {
                        idle = ""
                    }
                    print("[\(stamp)] idle\(idle) — \(trace.label)")
                }
            }
        }
        lastReportedActive = active
    }

    private func emitFinal(reason: ExitReason) {
        let reasonStr: String = {
            switch reason {
            case .normal:       return "normal"
            case .userCancel:   return "user-cancel"
            case .maxElapsed:   return "max-elapsed"
            case .idleTimeout:  return "idle-timeout"
            }
        }()
        if json {
            emitJSON([
                "event": "stop",
                "reason": reasonStr,
                "agent": trace.id,
            ])
        } else {
            print("eclam watch: released sleep block (\(reasonStr)).")
        }
    }

    private func emitJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func humanTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    // MARK: - Hook subscription

    private func subscribeHook(key: String) {
        let sanitized = HelperServiceName.sanitizeActivitySource(key)
        guard !sanitized.isEmpty else { return }
        let name = "\(HelperServiceName.activityNotifyPrefix).\(sanitized)"
        var token: Int32 = 0
        // Pre-materialize the block so libnotify can retain it for the
        // registration's lifetime (mirrors AgentDetector.subscribeHook).
        let block: @convention(block) (Int32) -> Void = { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self.lastHookPing = Date()
            self.lock.unlock()
        }
        let status = name.withCString { cstr -> UInt32 in
            notify_register_dispatch(cstr, &token, DispatchQueue.global(qos: .utility), block)
        }
        if status == WATCH_NOTIFY_STATUS_OK {
            hookToken = token
            hasHookToken = true
        }
        // If subscription failed we still operate on mtime only — no fatal.
    }

    private func cleanupSubscriptions() {
        if hasHookToken {
            _ = notify_cancel(hookToken)
            hasHookToken = false
        }
    }

    // MARK: - Glob mtime probe

    /// Lifted from `AgentDetector.freshestMatch`. Returns the freshest matching
    /// path + its age in seconds, or nil if no glob match.
    private func freshestMatch(pattern: String, now: Date) -> (String, TimeInterval)? {
        var bestPath: String?
        var bestAge: TimeInterval = .infinity
        for path in Glob.expand(pattern) {
            var st = stat()
            if stat(path, &st) == 0 {
                let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                                 + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
                let age = now.timeIntervalSince(mtime)
                if age < bestAge {
                    bestAge = age
                    bestPath = path
                }
            }
        }
        if let p = bestPath { return (p, bestAge) }
        return nil
    }

    // MARK: - Synchronous XPC

    private func syncSetSleepDisabled(_ enabled: Bool) -> Error? {
        let sem = DispatchSemaphore(value: 0)
        // Lock-guarded (shared LockedBox): reply/error handler land on XPC
        // queues; after the 1s timeout this thread reads while a late callback
        // may still write. A plain `var` here was a data race.
        let rpcError = LockedBox<Error?>(nil)
        let proxy = connection.remoteObjectProxyWithErrorHandler { err in
            rpcError.set(err)
            sem.signal()
        } as? ElectronicClamHelperProtocol
        guard let proxy = proxy else {
            return NSError(domain: "com.jadhvank.eclam", code: -1,
                           userInfo: [NSLocalizedDescriptionKey: "no XPC proxy"])
        }
        proxy.setSleepDisabled(enabled) { err in
            rpcError.set(err)
            sem.signal()
        }
        if sem.wait(timeout: .now() + 1.0) == .timedOut {
            return NSError(domain: "com.jadhvank.eclam", code: -2,
                           userInfo: [NSLocalizedDescriptionKey: "XPC timeout after 1s"])
        }
        return rpcError.get()
    }
}
