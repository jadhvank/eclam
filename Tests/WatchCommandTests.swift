import Foundation

protocol CLISubcommand { static func run(args: [String]) -> Int32 }
enum CLIStderr {
    static func print(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
}
enum HelperRegistration { static let plistName = "unused-test-helper.plist" }

/// Exercise the production WatchSession and helper/controller together, with
/// in-process transport and injected power writes. Never contact the live helper.
private final class TestConnection: WatchConnection {
    let service: HelperService
    init(service: HelperService) {
        self.service = service
    }
    func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any {
        service
    }
    func invalidate() { service.connectionInvalidated() }
}

@main enum WatchCommandTests {
    static func main() {
        for option in ["--grace", "--check-interval", "--max"] {
            for value in ["inf", "nan", "1e309", "1e100"] {
                precondition(WatchCommand.run(args: ["omp", option, value]) == 1)
            }
        }
        let power = LockedBox(false)
        let disk = LockedBox<HoldState?>(nil)
        let controller = PowerSessionController(now: Date.init,
            uptime: { ProcessInfo.processInfo.systemUptime },
            write: { power.set($0); return true }, read: { power.get() },
            load: { disk.get() }, save: { disk.set($0); return true })
        let runtime = PowerSessionRuntime(controller: controller)
        runtime.start()
        let trace = AgentTrace(id: "test", label: "Test", globPattern: "/nonexistent-eclam-test/*.jsonl")
        let connection = TestConnection(service: HelperService(isHook: false, power: runtime))
        let heldAfterWatchdog = LockedBox(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 21) {
            heldAfterWatchdog.set(runtime.state.disabled)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let watch = WatchSession(trace: trace, connection: connection, grace: 60,
                                 checkInterval: 120, maxMinutes: 0.4, json: true)
        precondition(watch.run() == 0)
        precondition(heldAfterWatchdog.get(), "watch must still protect after the 20s helper watchdog")
        precondition(ProcessInfo.processInfo.systemUptime - start < 28, "--max must not wait for 120s poll")
        precondition(!runtime.state.disabled)

        // Hook activity must be considered between infrequent filesystem probes.
        let hookTrace = AgentTrace(id: "hook-test", label: "Hook", globPattern: trace.globPattern,
                                   hookKey: "eclam-watch-test-" + UUID().uuidString.lowercased())
        let pulses = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        pulses.schedule(deadline: .now() + 0.1, repeating: 0.1)
        pulses.setEventHandler { ActivityRelay.post(source: hookTrace.hookKey!) }
        pulses.resume()
        let hookStart = ProcessInfo.processInfo.systemUptime
        let hooked = WatchSession(trace: hookTrace,
            connection: TestConnection(service: HelperService(isHook: false, power: runtime)),
            grace: 0.5, checkInterval: 120, maxMinutes: 4.0 / 60, json: true)
        precondition(hooked.run() == 0)
        pulses.cancel()
        precondition(ProcessInfo.processInfo.systemUptime - hookStart >= 4,
                     "live hooks must prevent idle timeout between filesystem probes")
        precondition(!runtime.state.disabled)

        let blockedStart = ProcessInfo.processInfo.systemUptime
        let blocked = WatchSession(trace: trace,
            connection: TestConnection(service: HelperService(isHook: false, power: runtime)),
            grace: 60, checkInterval: 120, maxMinutes: 1.0 / 60, json: true,
            probe: { _, _ in Thread.sleep(forTimeInterval: 5); return nil })
        precondition(blocked.run() == 0)
        precondition(ProcessInfo.processInfo.systemUptime - blockedStart < 3,
                     "blocked filesystem must not delay hard cap or lease release")
        precondition(!runtime.state.disabled)

        let cancelled = TestConnection(service: HelperService(isHook: false, power: runtime))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            precondition(runtime.cancelHoldAndRestore())
        }
        let second = WatchSession(trace: trace, connection: cancelled, grace: 60,
                                  checkInterval: 120, maxMinutes: 0.2, json: true)
        precondition(second.run() == 2, "cancelled lease must stop watch without reacquiring")
        precondition(!runtime.state.disabled)
        print("PASS watch: finite options, renewal beyond watchdog, independent max deadline, safety cancellation")
    }
}
