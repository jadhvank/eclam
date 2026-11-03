import AppKit
import CoreGraphics
import Foundation

private var passed = 0
private var failed = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { passed += 1 }
    else { failed += 1; print("FAIL: \(message)") }
}

private let testPanelUUID = "6BE485B7-81DA-4AE0-9E06-68E12F936936"
private let otherUUID = "724AD12C-9C12-44CE-9A38-B0E593C24FE9"
private let capturedAt = Date(timeIntervalSince1970: 1_790_000_000)

private final class FakeBackend: BrightnessBackend {
    var id: CGDirectDisplayID? = 1
    var uuid: String? = testPanelUUID
    var brightness: Float? = 0.7
    var failingWrites = 0
    var applyFailedWrite = false
    var ignoreSuccessfulWrites = false
    var reads: [Float?] = []
    var writes: [(id: CGDirectDisplayID, value: Float)] = []
    var onWrite: (() -> Void)?
    func builtinID() -> CGDirectDisplayID? { id }
    func panelUUID(_ display: CGDirectDisplayID) -> String? { uuid }
    func get(_ display: CGDirectDisplayID) -> Float? {
        if !reads.isEmpty { return reads.removeFirst() }
        return brightness
    }
    func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        onWrite?()
        writes.append((display, value))
        if failingWrites > 0 {
            failingWrites -= 1
            if applyFailedWrite { brightness = value }
            return false
        }
        if !ignoreSuccessfulWrites { brightness = value }
        return true
    }
}

private final class FakeStore: BrightnessSessionStoring {
    enum Failure: Error { case io }
    var snapshot: BrightnessSnapshot?
    var failSave = false
    var failClear = false
    var loadError: Error?
    var saves = 0
    var clears = 0
    func load() throws -> BrightnessSnapshot? {
        if let loadError { throw loadError }
        return snapshot
    }
    func save(_ snapshot: BrightnessSnapshot) throws {
        if failSave { throw Failure.io }
        saves += 1
        self.snapshot = snapshot
    }
    func clear() throws {
        if failClear { throw Failure.io }
        clears += 1; snapshot = nil
    }
}

private final class FakeResources: DimmerResources {
    var held = false
    var acquisitions = 0
    var releases = 0
    func acquire() { if !held { held = true; acquisitions += 1 } }
    func release() { if held { held = false; releases += 1 } }
}

private final class FakeObservationActivity {
    var options: [ProcessInfo.ActivityOptions] = []
    var started = 0
    var ended = 0
    func begin(_ options: ProcessInfo.ActivityOptions) -> NSObjectProtocol {
        self.options.append(options)
        started += 1
        return NSObject()
    }
    func end(_ token: NSObjectProtocol) { ended += 1 }
}

private final class FakeJob: DimmerCancellation {
    let action: () -> Void
    var cancelled = false
    init(_ action: @escaping () -> Void) { self.action = action }
    func cancel() { cancelled = true }
}
private final class FakeScheduler: DimmerScheduling {
    var jobs: [FakeJob] = []
    var polls: [FakeJob] = []
    var waits: [TimeInterval] = []
    var repeatingInterval: TimeInterval = 0.5
    func after(_ interval: TimeInterval, _ action: @escaping () -> Void) -> DimmerCancellation {
        check(interval == 0.2, "restore retries stay at 0.2 seconds")
        let job = FakeJob(action); jobs.append(job); return job
    }
    func repeating(_ interval: TimeInterval, _ action: @escaping () -> Void) -> DimmerCancellation {
        check(interval == repeatingInterval, "each poll uses its expected interval")
        let job = FakeJob(action); polls.append(job); return job
    }
    func wait(_ interval: TimeInterval) { waits.append(interval) }
    func drain() {
        var count = 0
        while !jobs.isEmpty && count < 30 {
            count += 1
            let job = jobs.removeFirst()
            if !job.cancelled { job.action() }
        }
        check(count < 30, "retry sequence is bounded")
    }
    func tick() { for job in polls where !job.cancelled { job.action() } }
}
private final class Fixture {
    let backend = FakeBackend()
    let store = FakeStore()
    let resources = FakeResources()
    let scheduler = FakeScheduler()
    let autoScheduler = FakeScheduler()
    let autoActivity = FakeObservationActivity()
    let notifications = NotificationCenter()
    let workspaceNotifications = NotificationCenter()
    var time: TimeInterval = 100
    var idle: TimeInterval = 0.02
    var date = capturedAt
    var lid: LidState = .open
    var autoConditions = AutoDimCoordinator.Conditions(keep: true, displayHeld: true, keepDisplayOption: false)
    var autoThreshold: TimeInterval? = 60
    var thresholdReads = 0
    lazy var dimmer = BlankDisplayDimmer(
        backend: backend, sessionStore: store, resources: resources, scheduler: scheduler,
        uptime: { [unowned self] in self.time }, idleSeconds: { [unowned self] in self.idle },
        now: { [unowned self] in self.date }, lidState: { [unowned self] in self.lid },
        observeSystemEvents: true, notificationCenter: notifications,
        workspaceNotificationCenter: workspaceNotifications)
    lazy var automatic = AutoDimCoordinator(dimmer: dimmer,
        conditions: { [unowned self] in self.autoConditions },
        threshold: { [unowned self] in self.thresholdReads += 1; return self.autoThreshold },
        scheduler: autoScheduler, uptime: { [unowned self] in self.time },
        idleSeconds: { [unowned self] in self.idle }, lidState: { [unowned self] in self.lid },
        beginActivity: { [activity = autoActivity] in activity.begin($0) },
        endActivity: { [activity = autoActivity] in activity.end($0) })
    func startAutomatic() {
        autoScheduler.repeatingInterval = 1
        dimmer.recoverInterruptedSession()
        automatic.update()
    }
    func advance(_ seconds: TimeInterval) {
        time += seconds
        idle += seconds
        scheduler.tick()
        autoScheduler.tick()
    }
    func snapshot(age: TimeInterval = 0, uuid: String = testPanelUUID) -> BrightnessSnapshot {
        BrightnessSnapshot(displayUUID: uuid, original: 0.7, lastApplied: 0,
                           capturedAt: date.addingTimeInterval(-age))
    }
    func newInput() { time += 0.5; idle = 0.01; scheduler.tick() }
}

@main
enum DimRestoreTests {
    static func main() {
        // Every test injects power resources, scheduler, clocks and notification
        // centers. No test calls real brightness/power/lid APIs or creates an app.
        do {
            let f = Fixture(); f.dimmer.dim()
            f.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            check(f.dimmer.isDimmed && f.backend.brightness == 0, "own anchor reconfiguration must not undo new Dim")
            f.backend.id = nil
            f.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            f.backend.id = 42
            f.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            check(f.dimmer.state == .idle && f.backend.brightness == 0.7, "panel disappearance/reappearance restores Dim")
        }
        for reason: BlankDisplayDimmer.RestoreReason in [.input, .lidOpened, .systemWake, .screensWake,
                                                        .displayReconfiguration, .keep, .safety, .off,
                                                        .quit, .helperUnavailable] {
            let f = Fixture()
            f.backend.onWrite = { [unowned f] in
                check(f.store.snapshot != nil, "journal exists before any brightness write")
            }
            f.dimmer.dim()
            check(f.backend.brightness == 0 && f.resources.held, "dim lowers and holds")
            f.dimmer.requestRestore(reason: reason)
            check(f.backend.brightness == 0.7 && f.dimmer.state == .idle, "\(reason) restores original 0.7")
            check(!f.resources.held && f.store.snapshot == nil, "\(reason) releases resources and clears journal")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.dimmer.dim()
            check(f.store.saves == 1 && f.backend.writes.count == 1, "repeated Dim preserves first snapshot")
            f.backend.id = 42
            f.dimmer.restore()
            check(f.backend.writes.last?.id == 42 && f.backend.brightness == 0.7,
                  "same physical panel is restored using re-enumerated ID")
        }
        do {
            let f = Fixture(); f.backend.brightness = nil; f.dimmer.dim()
            check(f.backend.writes.isEmpty && f.store.saves == 0 && !f.resources.held,
                  "failed original read never writes or holds")
        }
        for invalid in [Float.nan, Float.infinity, -0.1, 1.1] {
            let f = Fixture(); f.backend.brightness = invalid; f.dimmer.dim()
            check(f.backend.writes.isEmpty, "invalid original brightness never writes")
        }
        do {
            let f = Fixture(); f.store.failSave = true; f.dimmer.dim()
            check(f.backend.writes.isEmpty && !f.resources.held, "failed persistence prevents lowering")
        }
        do {
            let f = Fixture(); f.backend.id = nil; f.dimmer.dim()
            check(f.dimmer.state == .dimmed(nil) && f.resources.held, "headless Dim explicitly holds without snapshot")
            f.backend.id = 42; f.dimmer.restore()
            check(f.backend.writes.isEmpty && f.dimmer.state == .idle, "headless return never invents brightness")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.backend.uuid = otherUUID; f.dimmer.restore()
            check(f.backend.writes.count == 1 && f.dimmer.state == .idle, "different physical panel is never written")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.backend.failingWrites = 5
            f.dimmer.requestRestore(reason: .safety)
            check(!f.resources.held, "safety release drops all owned power immediately while pending")
            f.dimmer.requestRestore(reason: .systemWake)
            f.scheduler.drain()
            check(f.backend.writes.count == 6 && f.store.snapshot?.original == 0.7,
                  "five failed writes exhaust retries without dropping original")
            check(f.dimmer.state == .restorePending(f.snapshot()), "exhausted restore stays pending")
            f.backend.id = 42
            f.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            check(f.backend.brightness == 0.7 && f.backend.writes.last?.id == 42, "rediscovery restores pending original")
            check(f.resources.acquisitions == 1, "restore retries never reacquire power")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.backend.id = nil; f.dimmer.restore(); f.scheduler.drain()
            check(f.backend.writes.count == 1 && f.store.snapshot != nil, "missing panel never uses stale ID")
            let saves = f.store.saves
            f.dimmer.dim(); f.scheduler.drain()
            check(f.store.saves == saves && f.store.snapshot?.original == 0.7,
                  "re-Dim while pending does not capture the floor")
            f.backend.id = 42; f.newInput()
            check(f.backend.brightness == 0.7 && f.dimmer.state == .idle, "new input retries exhausted pending restore")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.backend.brightness = 0.3
            f.dimmer.restore()
            check(f.backend.brightness == 0.3 && f.backend.writes.count == 1 && f.store.snapshot == nil,
                  "external brightness 0.3 wins over old original")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.backend.brightness = 0.7; f.dimmer.restore()
            check(f.backend.writes.count == 1, "already-original readback completes without write")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.backend.ignoreSuccessfulWrites = true; f.dimmer.restore(); f.scheduler.drain()
            check(f.store.snapshot != nil && f.backend.brightness == 0, "successful write result alone cannot clear journal")
        }
        do {
            let f = Fixture(); f.backend.failingWrites = 1; f.dimmer.dim()
            check(f.dimmer.state == .idle && f.store.snapshot == nil && !f.resources.held,
                  "failed initial write with unchanged readback clears snapshot")
        }
        do {
            let f = Fixture(); f.backend.failingWrites = 1; f.backend.applyFailedWrite = true; f.dimmer.dim()
            check(f.backend.brightness == 0.7 && f.dimmer.state == .idle,
                  "failed initial write that actually applied floor is restored")
        }
        do {
            let f = Fixture(); f.backend.failingWrites = 1
            f.backend.reads = [0.7, nil, nil, nil, nil, nil]
            f.dimmer.dim(); f.scheduler.drain()
            check(f.store.snapshot?.original == 0.7 && !f.resources.held,
                  "uncertain failed initial write retains recovery without holding power")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.backend.failingWrites = 1; f.dimmer.restore()
            let stale = f.scheduler.jobs[0]
            f.dimmer.prepareForTermination()
            stale.action()
            check(f.backend.brightness == 0.7 && f.backend.writes.count == 3,
                  "termination invalidates already-queued retry generation")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.backend.failingWrites = 1; f.dimmer.restore()
            let stale = f.scheduler.jobs[0]
            f.scheduler.drain(); f.dimmer.dim(); stale.action()
            check(f.dimmer.isDimmed && f.backend.brightness == 0 && f.store.snapshot?.original == 0.7,
                  "old callback cannot modify a newly dimmed episode")
            f.dimmer.restore()
        }
        for notification in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let f = Fixture(); f.dimmer.dim()
            f.workspaceNotifications.post(name: notification, object: nil)
            check(f.backend.brightness == 0.7, "workspace notification restores 0.7")
        }
        do {
            let f = Fixture(); f.dimmer.dim()
            f.time += 0.5; f.idle += 0.5; f.scheduler.tick()
            check(f.dimmer.isDimmed, "only initiating menu click is ignored")
            f.newInput()
            check(f.backend.brightness == 0.7, "new input within two seconds restores without arming delay")
        }
        do {
            let f = Fixture(); f.lid = .closed; f.dimmer.dim(); f.lid = .open; f.scheduler.tick()
            check(f.backend.brightness == 0.7, "closed-to-open lid polling restores 0.7")
            f.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil); f.newInput()
            check(f.backend.writes.count == 2 && f.store.clears == 1, "duplicate lid/wake/input clears snapshot once")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.backend.id = nil; f.dimmer.prepareForTermination()
            check(f.scheduler.waits.count == 4 && f.scheduler.waits.reduce(0, +) <= 0.81,
                  "termination has at most four waits totalling 0.8 seconds")
            check(!f.resources.held && f.store.snapshot?.original == 0.7, "termination releases power while retaining journal")
            f.dimmer.prepareForTermination()
            check(f.scheduler.waits.count == 4, "duplicate termination is idempotent")
        }
        do {
            let f = Fixture(); f.store.snapshot = f.snapshot(); f.backend.brightness = 0
            f.dimmer.recoverInterruptedSession()
            check(f.backend.brightness == 0.7 && f.store.snapshot == nil && !f.resources.held,
                  "launch restores a fresh same-panel journal without acquiring power")
        }
        for invalidCase in 0..<4 {
            let f = Fixture()
            f.store.snapshot = f.snapshot(age: invalidCase == 0 ? 86_401 : invalidCase == 1 ? -1 : 0,
                                          uuid: invalidCase == 2 ? otherUUID : testPanelUUID)
            f.backend.brightness = invalidCase == 3 ? 0.3 : 0
            f.dimmer.recoverInterruptedSession()
            check(f.backend.writes.isEmpty && f.store.snapshot == nil && f.dimmer.state == .idle,
                  "expired/future/other-panel/externally-changed recovery is discarded")
        }
        do {
            let f = Fixture(); f.store.snapshot = f.snapshot(); f.backend.brightness = nil
            f.dimmer.recoverInterruptedSession(); f.scheduler.drain(); f.dimmer.dim(); f.scheduler.drain()
            check(f.store.saves == 0 && f.backend.writes.isEmpty && f.store.snapshot != nil,
                  "unreadable launch panel remains pending and blocks new Dim capture")
            f.backend.brightness = 0; f.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
            check(f.backend.brightness == 0.7, "pending launch recovery succeeds after readable wake")
        }
        do {
            let f = Fixture(); f.store.loadError = BrightnessSessionStore.StoreError.invalidJournal
            f.dimmer.recoverInterruptedSession()
            check(f.backend.writes.isEmpty && f.store.clears == 1, "invalid recovery encoding is discarded without writes")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.backend.brightness = 0.3; f.store.failClear = true
            f.dimmer.restore(); f.scheduler.drain()
            check(f.store.snapshot != nil && !f.resources.held, "failed journal cleanup remains pending without power")
            f.backend.brightness = 0; f.store.failClear = false; f.dimmer.restore()
            check(f.backend.writes.count == 1 && f.dimmer.state == .idle && f.store.snapshot == nil,
                  "cleanup retry cannot reclaim brightness after external ownership was respected")
        }
        do {
            let f = Fixture(); f.store.loadError = FakeStore.Failure.io; f.dimmer.dim()
            check(f.backend.writes.isEmpty && !f.resources.held, "unreadable journal cannot be overwritten by a new Dim")
        }
        // Automatic policy integration: all inputs and resources are still fake.
        do {
            let f = Fixture(); f.startAutomatic(); f.automatic.update(); f.advance(1)
            check(f.autoActivity.started == 1 && f.autoActivity.ended == 0,
                  "pre-dim automatic observation acquires App Nap protection only once")
            let options = f.autoActivity.options[0]
            check(options == .userInitiatedAllowingIdleSystemSleep
                  && !options.contains(.idleSystemSleepDisabled) && !options.contains(.idleDisplaySleepDisabled),
                  "automatic observation activity has no display/system sleep-prevention bits")
            f.autoConditions.displayHeld = false; f.advance(1)
            check(f.autoActivity.started == 1 && f.autoActivity.ended == 0,
                  "late-holder observation remains protected without creating another activity")
            let stale = f.autoScheduler.polls[0]
            f.autoConditions.keepDisplayOption = true; f.automatic.update(); stale.action()
            check(f.autoActivity.started == 1 && f.autoActivity.ended == 1,
                  "caffeine ON ends observation once and stale callback cannot reacquire")
            f.autoConditions.keepDisplayOption = false; f.automatic.update()
            check(f.autoActivity.started == 2 && f.autoActivity.ended == 1,
                  "new observation lifetime acquires a fresh activity")
            f.autoConditions.keep = false; f.automatic.update(); f.automatic.update()
            check(f.autoActivity.started == 2 && f.autoActivity.ended == 2,
                  "keep/safety release ends observation exactly once")
            f.autoConditions.keep = true; f.automatic.update()
            let lastStale = f.autoScheduler.polls.last!
            f.automatic.stop(); f.automatic.stop(); lastStale.action()
            f.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
            check(f.autoActivity.started == 3 && f.autoActivity.ended == 3,
                  "stop releases activity once and late callbacks cannot restart it")
        }
        do {
            var f: Fixture? = Fixture()
            weak var observedCoordinator: AutoDimCoordinator?
            let activity = f!.autoActivity
            let scheduler = f!.autoScheduler
            f!.startAutomatic(); observedCoordinator = f!.automatic
            check(activity.started == 1, "deinit fixture starts an observation activity")
            f = nil
            check(observedCoordinator == nil && activity.ended == 1 && scheduler.polls.allSatisfy { $0.cancelled },
                  "coordinator deinit releases observation activity and cancels timer")
            scheduler.polls.forEach { $0.action() }
            check(activity.started == 1 && activity.ended == 1,
                  "deallocated observation cannot be revived by stale timer callbacks")
        }
        for notification in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let f = Fixture(); f.idle = 900; f.startAutomatic(); f.advance(59)
            check(f.dimmer.state == .idle, "pre-dim wake fixture is still idle")
            f.workspaceNotifications.post(name: notification, object: nil)
            f.advance(1)
            check(!f.dimmer.isDimmed && f.backend.writes.isEmpty,
                  "wake while already idle must reset near-expired automatic grace")
            f.advance(58)
            check(!f.dimmer.isDimmed, "idle wake grants the complete threshold without OS input reset")
            f.advance(1)
            check(f.dimmer.isDimmed, "idle wake does not prevent a later full idle period")
        }
        do {
            let f = Fixture(); f.idle = 900; f.startAutomatic(); f.advance(59)
            // A close/open between policy ticks is not visible in the sampled lid
            // state. The topology event still gives the return a full grace.
            f.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            f.advance(1)
            check(!f.dimmer.isDimmed, "idle display reconfiguration resets near-expired grace")
            f.advance(58)
            check(!f.dimmer.isDimmed, "fast lid return via topology event gets full grace")
            f.advance(1)
            check(f.dimmer.isDimmed, "topology return permits dim after a new full idle period")
            f.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            check(f.dimmer.isDimmed && f.backend.writes.count == 1 && f.resources.held,
                  "own-anchor reconfiguration only updates grace and does not restore active automatic dim")
        }
        for intermediateUnknown in [false, true] {
            let f = Fixture(); f.idle = 900; f.lid = .closed; f.startAutomatic(); f.advance(59)
            if intermediateUnknown { f.lid = .unavailable; f.automatic.update() }
            f.lid = .open; f.advance(1)
            check(!f.dimmer.isDimmed && f.backend.writes.isEmpty,
                  "idle closed-to-open lid sample resets grace before automatic start")
            f.advance(59)
            check(!f.dimmer.isDimmed, "idle lid return gets full grace even across unknown lid samples")
            f.advance(1)
            check(f.dimmer.isDimmed, "idle lid return permits dim after new grace")
        }
        do {
            let f = Fixture(); f.autoConditions.displayHeld = false; f.startAutomatic(); f.advance(600)
            check(!f.dimmer.isDimmed && f.store.saves == 0, "missing holder never starts automatic dim")
            f.autoConditions.displayHeld = true; f.advance(1); f.advance(59)
            check(!f.dimmer.isDimmed, "late holder appearance is observed without convergence and grants grace")
            f.advance(1)
            check(f.dimmer.isDimmed, "late holder can start automatic dim after its grace")
            f.autoConditions.displayHeld = false; f.advance(1)
            check(!f.dimmer.isDimmed && !f.resources.held, "holder loss is observed without convergence")
            f.autoConditions.displayHeld = true; f.advance(1); f.advance(60)
            check(f.dimmer.isDimmed, "holder reappearance after topology change is still observed")
        }
        do {
            let f = Fixture(); f.idle = 900; f.startAutomatic()
            f.advance(59)
            check(!f.dimmer.isDimmed, "eligibility grants a full grace despite old OS idle")
            f.advance(1)
            check(f.dimmer.origin == .automatic && f.dimmer.isDimmed && f.backend.brightness == 0,
                  "idle threshold starts automatic dim through the same brightness owner")
            check(f.resources.acquisitions == 1 && f.store.saves == 1, "automatic dim acquires/captures once")
            let before = f.thresholdReads; f.advance(1)
            check(f.thresholdReads > before, "active poll rereads current power policy")
            f.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
            check(f.backend.brightness == 0.7 && f.dimmer.state == .idle, "wake restores automatic dim")
            f.advance(59)
            check(!f.dimmer.isDimmed, "wake without input must not immediately dim again")
            f.advance(1)
            check(f.dimmer.isDimmed, "wake grace eventually permits new idle dim")
            f.newInput(); f.automatic.update()
            check(!f.dimmer.isDimmed && f.backend.brightness == 0.7, "new input restores automatic dim immediately")
            f.advance(59)
            check(!f.dimmer.isDimmed, "fresh input gets its own complete idle period")
            f.advance(1)
            check(f.dimmer.isDimmed, "new input period can later dim again")
        }
        do {
            let f = Fixture(); f.idle = 900; f.lid = .closed; f.startAutomatic(); f.advance(60)
            f.lid = .open; f.scheduler.tick(); f.automatic.update()
            check(f.dimmer.state == .idle && f.backend.brightness == 0.7, "lid-only return restores automatic dim")
            f.advance(59)
            check(!f.dimmer.isDimmed, "lid-only return grants grace without OS input reset")
            f.advance(1)
            check(f.dimmer.isDimmed, "lid-open does not disable subsequent eligible dim")
        }
        do {
            let f = Fixture(); f.startAutomatic(); f.advance(60)
            f.autoConditions.keepDisplayOption = true; f.automatic.update()
            check(f.dimmer.state == .idle && f.backend.brightness == 0.7 && !f.resources.held,
                  "caffeine ON restores automatic dim and releases its resources")
            f.advance(600)
            check(!f.dimmer.isDimmed, "caffeine ON blocks automatic reentry")
            f.autoConditions.keepDisplayOption = false; f.automatic.update(); f.advance(59)
            check(!f.dimmer.isDimmed, "caffeine OFF starts fresh grace")
            f.advance(1)
            check(f.dimmer.isDimmed, "caffeine OFF permits automatic dim after grace")
        }
        do {
            let f = Fixture(); f.startAutomatic(); f.advance(60)
            let saved = f.store.snapshot
            f.dimmer.dim()
            check(f.dimmer.origin == .manual && f.store.snapshot == saved && f.store.saves == 1,
                  "manual takeover retains automatic episode's original snapshot")
            f.autoConditions.keepDisplayOption = true; f.automatic.update()
            check(f.dimmer.isDimmed && f.resources.held, "caffeine toggle does not cancel manual takeover")
            f.dimmer.restore()
            check(f.backend.brightness == 0.7, "manual takeover restores the true original brightness")
        }
        do {
            let f = Fixture(); f.dimmer.dim(); f.startAutomatic(); f.advance(600)
            check(f.dimmer.origin == .manual && f.store.saves == 1, "automatic dim never recaptures an active manual dim")
            f.dimmer.restore(); f.automatic.update(); f.advance(59)
            check(!f.dimmer.isDimmed, "manual episode completion also grants automatic grace")
        }
        for lostKeep in [false, true] {
            let f = Fixture(); f.startAutomatic(); f.advance(60)
            f.backend.failingWrites = 100
            if lostKeep { f.autoConditions.keep = false }
            else { f.autoConditions.displayHeld = false }
            f.automatic.update()
            check(!f.resources.held && !f.dimmer.isDimmed && f.store.snapshot != nil,
                  "keep/holder loss releases dim power even when restoration is pending")
            check(f.scheduler.waits.isEmpty, "safety/condition release does not wait for brightness restoration")
            f.advance(600); f.scheduler.drain()
            check(f.store.saves == 1 && !f.resources.held, "dim's own assertion cannot keep automatic policy alive")
            f.backend.failingWrites = 0; f.dimmer.requestRestore(reason: .systemWake)
            f.autoConditions.keep = true; f.autoConditions.displayHeld = true; f.automatic.update()
            f.advance(59)
            check(!f.dimmer.isDimmed, "returning keep/holder requires fresh grace")
            f.advance(1)
            check(f.dimmer.isDimmed && f.store.saves == 2, "recovered conditions permit a new episode after grace")
        }
        do {
            let f = Fixture(); f.startAutomatic(); f.advance(60)
            f.backend.brightness = 0.4; f.scheduler.tick(); f.automatic.update()
            check(f.dimmer.state == .idle && f.backend.brightness == 0.4 && f.backend.writes.count == 1,
                  "external brightness change without input ends automatic ownership without overwriting it")
            f.advance(59)
            check(f.backend.brightness == 0.4 && f.backend.writes.count == 1,
                  "old OS idle cannot immediately overwrite external brightness")
            f.advance(1); f.dimmer.restore()
            check(f.backend.brightness == 0.4, "later automatic episode preserves the new user's brightness")
        }
        do {
            let f = Fixture(); f.startAutomatic(); f.advance(60)
            f.backend.id = nil; f.automatic.update(); f.scheduler.drain(); f.advance(600)
            check(f.store.saves == 1 && !f.resources.held && f.dimmer.state.snapshot != nil,
                  "absent built-in keeps recovery pending and cannot start an assertion-only automatic dim")
            f.backend.id = 42
            f.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            f.automatic.update(); f.advance(59)
            check(!f.dimmer.isDimmed && f.backend.brightness == 0.7, "panel reappearance gets grace after successful pending restore")
        }
        for unavailable in 0..<4 {
            let f = Fixture()
            if unavailable == 0 { f.backend.id = nil }
            if unavailable == 1 { f.backend.uuid = nil }
            if unavailable == 2 { f.backend.brightness = nil }
            if unavailable == 3 { f.backend.uuid = "not-a-physical-panel-uuid" }
            f.startAutomatic(); f.advance(600)
            check(f.store.saves == 0 && f.backend.writes.isEmpty && !f.resources.held,
                  "absent or unknown physical built-in never starts automatic dim")
        }
        for limit: TimeInterval? in [nil, AutoDimPolicy.thresholdSeconds(minutes: 0), .nan, .infinity] {
            let f = Fixture(); f.autoThreshold = limit; f.startAutomatic(); f.advance(600)
            check(!f.dimmer.isDimmed && f.store.saves == 0, "Never/failed/invalid power policy does not dim")
        }
        do {
            let f = Fixture(); f.startAutomatic(); f.advance(60)
            f.autoThreshold = nil; f.automatic.update()
            check(!f.dimmer.isDimmed && f.backend.brightness == 0.7, "power-policy read failure restores automatic dim")
            f.autoThreshold = 120; f.automatic.update(); f.advance(119)
            check(!f.dimmer.isDimmed, "new power-source threshold replaces old value with full grace")
            f.advance(1)
            check(f.dimmer.isDimmed, "updated threshold controls subsequent automatic dim")
        }
        do {
            let f = Fixture(); f.store.snapshot = f.snapshot(); f.backend.brightness = nil
            f.startAutomatic(); f.advance(600); f.scheduler.drain()
            check(f.store.saves == 0 && !f.resources.held, "launch recovery must finish before automatic dim")
            f.backend.brightness = 0
            f.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
            f.automatic.update(); f.advance(59)
            check(!f.dimmer.isDimmed && f.backend.brightness == 0.7, "recovery completion grants a new grace")
        }
        do {
            let f = Fixture(); f.startAutomatic()
            let stale = f.autoScheduler.polls[0]
            f.automatic.stop(); f.dimmer.prepareForTermination(); f.time += 600; f.idle += 600
            f.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
            f.workspaceNotifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            f.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            f.lid = .closed; stale.action(); f.lid = .open
            stale.action(); f.automatic.update(); f.dimmer.dim(origin: .automatic)
            check(f.backend.writes.isEmpty && f.store.saves == 0 && !f.resources.held,
                  "stale policy/lid/notification callbacks cannot dim after termination")
            check(f.dimmer.onEpisodeFinished == nil && f.dimmer.onReturnGraceRequested == nil,
                  "stopping automatic policy detaches both dimmer hooks")
        }
        print("DimRestore tests: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
