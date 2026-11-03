import Foundation

@main enum VpnWatcherLifecycleTests {
    static func main() {
        func expect(_ ok: Bool, _ message: String) { if !ok { print("FAIL: \(message)"); exit(1) } }
        let store = StateStore()
        store.vpnDisconnectNotifyEnabled = true
        var status = VpnWatcher.VpnStatus.connected
        var ticks: [() -> Void] = [], wakes: [() -> Void] = []
        var started = 0, ended = 0, cancelled = 0, unwatched = 0, notices = 0
        var options: ProcessInfo.ActivityOptions = []
        var deps = VpnWatcher.Dependencies()
        deps.readStatus = { _ in status }
        deps.autodetect = { nil }
        deps.beginActivity = { options = $0; started += 1; return NSObject() }
        deps.endActivity = { _ in ended += 1 }
        deps.schedule = { _, tick in ticks.append(tick); return { cancelled += 1 } }
        deps.observeWake = { wake in wakes.append(wake); return { unwatched += 1 } }
        deps.notify = { _ in notices += 1 }
        let watcher = VpnWatcher(store: store, dependencies: deps)
        watcher.apply(enabled: true)
        watcher.apply(enabled: true) // keep/safety convergence cannot reset baseline
        expect(started == 1, "enable must be idempotent")
        expect(!options.contains(.idleDisplaySleepDisabled), "observer must allow display sleep")
        expect(!options.contains(.idleSystemSleepDisabled), "observer must allow system sleep")
        status = .unknown; ticks.last?()
        status = .disconnected; wakes.last?(); ticks.last?()
        expect(notices == 1, "wake after unknown/sleep must preserve connected baseline and notify once")
        status = .connected; ticks.last?()
        status = .disconnecting; ticks.last?()
        status = .disconnected; ticks.last?()
        expect(notices == 2, "one notification per connected/disconnected episode")
        status = .connected; ticks.last?()
        store.vpnServiceName = "Different VPN"
        status = .disconnected; ticks.last?()
        expect(notices == 2, "service change must establish a new baseline")
        watcher.stop(); watcher.stop()
        status = .connected; ticks[0](); status = .disconnected; wakes[0]()
        expect(notices == 2 && ended == 1 && cancelled == 1 && unwatched == 1, "stop must cancel once and ignore queued callbacks")
        status = .connected; watcher.apply(enabled: true)
        status = .disconnected; ticks[0](); wakes[0]()
        expect(notices == 2, "old generation must not observe after re-enable")
        ticks.last?(); expect(notices == 3, "new generation observes")
        watcher.apply(enabled: false)
        expect(!watcher.isActive && ended == 2, "disable independent of persisted enabled setting")
        print("PASS VPN lifecycle: opt-in, power options, episodes, wake, service changes, stale callbacks, cleanup")
    }
}
