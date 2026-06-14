import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `eclam keep --while <pid>` — daemon-independent caffeinate wrapper.
/// ADR-0007 §C. Does NOT prevent lid-close sleep; that path uses the toggle
/// + helper. We make that explicit on stderr so people don't reach for `keep`
/// expecting lid-close blocking.
enum KeepCommand: CLISubcommand {
    static func run(args: [String]) -> Int32 {
        // Parse `--while <pid>`.
        var pid: Int32?
        var i = 0
        while i < args.count {
            if args[i] == "--while" {
                if i + 1 < args.count, let p = Int32(args[i + 1]), p > 0 {
                    pid = p
                    i += 2
                    continue
                }
                CLIStderr.print("eclam keep: --while requires a positive integer pid.")
                return 1
            }
            i += 1
        }
        guard let pid = pid else {
            CLIStderr.print("usage: eclam keep --while <pid>")
            return 1
        }

        // Validate pid is alive at start. kill(pid, 0) → ESRCH if no such proc.
        if kill(pid, 0) != 0 {
            let saved = errno
            if saved == ESRCH {
                CLIStderr.print("eclam keep: no such process: \(pid)")
                return 1
            }
            // EPERM means process exists but we lack signal permission — fine.
            if saved != EPERM {
                CLIStderr.print("eclam keep: cannot probe pid \(pid): \(String(cString: strerror(saved)))")
                return 1
            }
        }

        CLIStderr.print("eclam keep: idle sleep blocked while pid \(pid) alive (lid-close NOT blocked — use the menu bar app for that).")

        // Spawn `caffeinate -dis -w <pid>` and forward signals.
        let task = Process()
        task.launchPath = "/usr/bin/caffeinate"
        task.arguments = ["-dis", "-w", String(pid)]
        // Inherit fds — caffeinate is silent on success.
        do {
            try task.run()
        } catch {
            CLIStderr.print("eclam keep: failed to spawn caffeinate: \(error.localizedDescription)")
            return 1
        }

        // Signal handling: SIGINT (Ctrl-C) and external SIGTERM both tear the
        // child down, which unblocks `waitUntilExit()` below; we then exit 4.
        // No code runs in signal context — see KeepSignalTrap.
        KeepSignalTrap.install(child: task)

        task.waitUntilExit()

        if KeepSignalTrap.userCancelled {
            return 4
        }
        // Forward caffeinate's exit code (it returns 0 when watched pid exits
        // normally, non-zero on misuse).
        return task.terminationStatus
    }
}

/// Signal plumbing for `keep`.
///
/// The original design installed C `signal()` handlers that called
/// `Process.terminate()` — an ObjC method — straight from *signal context*.
/// That's async-signal-unsafe (POSIX limits handlers to a short allowlist;
/// objc_msgSend / malloc are not on it). A SIGINT landing while the runtime
/// or allocator held a lock could deadlock or corrupt the heap.
///
/// Same fix as SessionCommand: the signal disposition is `SIG_IGN` (nothing
/// at all runs in signal context) and delivery happens via
/// `DispatchSource.makeSignalSource` on a private serial queue, so the child
/// teardown runs in a normal execution context. The main thread stays parked
/// in `waitUntilExit()` and unblocks once the child dies.
private final class KeepSignalState {
    var child: Process?
    var signalSources: [DispatchSourceSignal] = []   // kept alive for process lifetime
    var userCancelled: Bool = false
    let lock = NSLock()
}

private let keepSignalState = KeepSignalState()

private enum KeepSignalTrap {
    /// Serial queue where signal delivery and child teardown run — never in
    /// signal context.
    private static let signalQueue =
        DispatchQueue(label: "com.jadhvank.eclam.keep.signal")

    static var userCancelled: Bool {
        keepSignalState.lock.lock()
        defer { keepSignalState.lock.unlock() }
        return keepSignalState.userCancelled
    }

    static func install(child: Process) {
        keepSignalState.lock.lock()
        keepSignalState.child = child
        keepSignalState.lock.unlock()

        for sig in [SIGINT, SIGTERM] {
            // SIG_IGN first: the default disposition would terminate the
            // process before the dispatch source could deliver. Ignored
            // signals are still observable through kqueue (EVFILT_SIGNAL),
            // which is what dispatch signal sources use.
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig,
                                                      queue: signalQueue)
            src.setEventHandler {
                KeepSignalTrap.fireCancel()
            }
            src.resume()
            keepSignalState.lock.lock()
            keepSignalState.signalSources.append(src)
            keepSignalState.lock.unlock()
        }
    }

    /// Idempotent: the first signal wins, repeats are no-ops. Terminating the
    /// child (SIGTERM, same as before) unblocks the main thread's
    /// `waitUntilExit()`, which then returns exit code 4.
    private static func fireCancel() {
        keepSignalState.lock.lock()
        if keepSignalState.userCancelled {
            keepSignalState.lock.unlock()
            return
        }
        keepSignalState.userCancelled = true
        let child = keepSignalState.child
        keepSignalState.lock.unlock()

        if let child = child, child.isRunning {
            child.terminate()
        }
    }
}
