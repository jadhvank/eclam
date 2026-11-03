import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import OSLog

protocol DimmerCancellation { func cancel() }
protocol DimmerScheduling {
    func after(_ interval: TimeInterval, _ action: @escaping () -> Void) -> DimmerCancellation
    func repeating(_ interval: TimeInterval, _ action: @escaping () -> Void) -> DimmerCancellation
    /// Used only by bounded termination cleanup, never by regular restore requests.
    func wait(_ interval: TimeInterval)
}

private final class DimmerScheduledAction: DimmerCancellation {
    private let cancellation: () -> Void
    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    func cancel() { cancellation() }
}

struct MainDimmerScheduler: DimmerScheduling {
    func after(_ interval: TimeInterval, _ action: @escaping () -> Void) -> DimmerCancellation {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
        return DimmerScheduledAction { work.cancel() }
    }
    func repeating(_ interval: TimeInterval, _ action: @escaping () -> Void) -> DimmerCancellation {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return DimmerScheduledAction { timer.invalidate() }
    }
    func wait(_ interval: TimeInterval) { Thread.sleep(forTimeInterval: interval) }
}

/// Kept injectable together: no test should acquire a real display assertion or activity.
protocol DimmerResources {
    func acquire()
    func release()
}

final class SystemDimmerResources: DimmerResources {
    private var assertion: IOPMAssertionID = 0
    private var activity: NSObjectProtocol?
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "dim")

    func acquire() {
        guard activity == nil else { return }
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Electronic Clam - dim" as CFString, &identifier)
        if result == kIOReturnSuccess { assertion = identifier }
        else { log.error("dim display assertion failed: \(result, privacy: .public)") }
        // The IOKit assertion above owns display-sleep prevention. This activity
        // prevents App Nap throttling of return polling without another power hold.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Electronic Clam - dim return polling")
    }

    func release() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
    }

    deinit { release() }
}

/// Owns one brightness episode on the main queue. A pending snapshot outlives
/// display-sleep prevention and survives process exit in the recovery journal.
final class BlankDisplayDimmer {
    enum RestoreReason: String {
        case input, lidOpened, systemWake, screensWake, displayReconfiguration
        case keep, safety, off, quit, helperUnavailable, dimFailed, recovery
    }

    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "dim")
    private let backend: BrightnessBackend
    private let sessionStore: BrightnessSessionStoring
    private let resources: DimmerResources
    private let scheduler: DimmerScheduling
    private let uptime: () -> TimeInterval
    private let idleSeconds: () -> TimeInterval
    private let now: () -> Date
    private let lidState: () -> LidState
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var poll: DimmerCancellation?
    private var retry: DimmerCancellation?
    private var trigger: DimReturnTrigger?
    private var generation: UInt = 0
    private var restoring = false
    private var recoveryChecked = false
    private var journalUnavailable = false
    private var terminating = false
    private var panelWasUnavailable = false
    // Once brightness was restored or externally changed, cleanup retries must
    // never regain ownership merely because the old floor is observed again.
    private var brightnessResolved = false
    private let retryLimit = 5
    private let retryDelay: TimeInterval = 0.2

    private(set) var state: BrightnessSessionState = .idle
    var isDimmed: Bool {
        if case .dimmed = state { return true }
        return false
    }

    init(backend: BrightnessBackend = DisplayServicesBrightnessBackend(),
         sessionStore: BrightnessSessionStoring = BrightnessSessionStore(),
         resources: DimmerResources = SystemDimmerResources(),
         scheduler: DimmerScheduling = MainDimmerScheduler(),
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         idleSeconds: @escaping () -> TimeInterval = {
             CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                    eventType: CGEventType(rawValue: ~0)!)
         },
         now: @escaping () -> Date = { Date() },
         lidState: @escaping () -> LidState = { LidStateReader.read() },
         observeSystemEvents: Bool = true,
         notificationCenter: NotificationCenter = .default,
         workspaceNotificationCenter: NotificationCenter? = nil) {
        self.backend = backend
        self.sessionStore = sessionStore
        self.resources = resources
        self.scheduler = scheduler
        self.uptime = uptime
        self.idleSeconds = idleSeconds
        self.now = now
        self.lidState = lidState
        if observeSystemEvents {
            let workspaceCenter = workspaceNotificationCenter ?? NSWorkspace.shared.notificationCenter
            observe(workspaceCenter, NSWorkspace.didWakeNotification, reason: .systemWake)
            observe(workspaceCenter, NSWorkspace.screensDidWakeNotification, reason: .screensWake)
            observe(notificationCenter, NSApplication.didChangeScreenParametersNotification,
                    reason: .displayReconfiguration)
        }
    }

    deinit {
        poll?.cancel()
        retry?.cancel()
        resources.release()
        for (center, observer) in observers { center.removeObserver(observer) }
        // AppDelegate calls prepareForTermination before teardown. An unexpected
        // deallocation deliberately leaves the journal available for next launch.
    }

    /// Launch recovery never invents a brightness value or captures the dim floor.
    /// Also called lazily before dim(), so a caller cannot overwrite an old episode.
    func recoverInterruptedSession() {
        guard !recoveryChecked, !terminating else { return }
        recoveryChecked = true
        do {
            guard let snapshot = try sessionStore.load() else { return }
            guard snapshot.isValid(at: now()) else {
                try sessionStore.clear()
                return
            }
            state = .restorePending(snapshot)
            startPolling()
            requestRestore(reason: .recovery)
        } catch BrightnessSessionStore.StoreError.invalidJournal {
            do { try sessionStore.clear() }
            catch { journalUnavailable = true }
        } catch {
            // If recovery data could not be read safely, do not overwrite it by
            // beginning a new Dim episode in this process.
            journalUnavailable = true
            log.error("brightness journal unavailable; Dim disabled for this launch")
        }
    }

    func dim(floor: Float = 0) {
        guard !terminating else { return }
        recoverInterruptedSession()
        guard !journalUnavailable else { return }
        guard state == .idle else {
            if case .restorePending = state { requestRestore(reason: .off) }
            return
        }
        guard BrightnessSnapshot.isValidBrightness(floor) else { return }
        generation &+= 1
        // Sample the initiating menu input before disk or display calls add delay.
        trigger = DimReturnTrigger(uptime: uptime(), idleSeconds: idleSeconds(), lidState: lidState())
        if let display = backend.builtinID() {
            panelWasUnavailable = false
            guard let uuid = backend.panelUUID(display), UUID(uuidString: uuid) != nil,
                  let original = backend.get(display), BrightnessSnapshot.isValidBrightness(original) else {
                trigger = nil
                return
            }
            let snapshot = BrightnessSnapshot(displayUUID: uuid, original: original,
                                              lastApplied: min(original, floor), capturedAt: now())
            do { try sessionStore.save(snapshot) }
            catch {
                trigger = nil
                log.error("brightness journal write failed; refusing to lower brightness")
                return
            }
            state = .dimmed(snapshot)
            if !backend.set(display, snapshot.lastApplied) {
                // A failed API result can still have changed the panel. The same
                // read-back restore policy distinguishes unchanged, changed and unknown.
                startPolling()
                requestRestore(reason: .dimFailed)
                return
            }
        } else {
            // Explicit headless Dim retains the existing assertion-only contract.
            state = .dimmed(nil)
            panelWasUnavailable = true
        }
        resources.acquire()
        startPolling()
    }

    /// All return/release paths converge here. Duplicate events share one bounded
    /// retry sequence; exhausted attempts retain the snapshot for the next event.
    func requestRestore(reason: RestoreReason) {
        guard state != .idle, !terminating else { return }
        resources.release()
        guard let snapshot = state.snapshot else {
            _ = finish()
            return
        }
        state = .restorePending(snapshot)
        guard !restoring else { return }
        generation &+= 1
        restoring = true
        log.info("brightness restore requested: \(reason.rawValue, privacy: .public)")
        attemptRestore(remaining: retryLimit, generation: generation)
    }

    /// Compatibility for existing explicit release callers.
    func restore() { requestRestore(reason: .off) }

    /// No asynchronous work is required to finish shutdown. At most five attempts
    /// and four 0.2s waits; unresolved recovery data remains on disk for next launch.
    func prepareForTermination() {
        guard !terminating else { return }
        terminating = true
        resources.release()
        poll?.cancel()
        poll = nil
        retry?.cancel()
        retry = nil
        generation &+= 1
        restoring = false
        guard let snapshot = state.snapshot else {
            state = .idle
            return
        }
        state = .restorePending(snapshot)
        for attempt in 0..<retryLimit {
            if restoreOnce(snapshot) { return }
            if attempt + 1 < retryLimit { scheduler.wait(retryDelay) }
        }
        log.error("brightness restore remains pending at termination")
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, reason: RestoreReason) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if reason == .displayReconfiguration { self.displayReconfigured() }
            else { self.requestRestore(reason: reason) }
        }
        observers.append((center, observer))
    }

    private func displayReconfigured() {
        switch state {
        case .idle: return
        case .restorePending:
            requestRestore(reason: .displayReconfiguration)
        case .dimmed(let snapshot):
            guard let display = backend.builtinID() else {
                panelWasUnavailable = true
                return
            }
            let changedPanel = snapshot.map { saved in
                backend.panelUUID(display).map { !saved.matchesPanel($0) } ?? false
            } ?? false
            // Creating our own anchor also posts this notification. It is not a
            // user return. Retry only after actual panel reappearance/change.
            if panelWasUnavailable || changedPanel {
                panelWasUnavailable = false
                requestRestore(reason: .displayReconfiguration)
            }
        }
    }

    private func startPolling() {
        if trigger == nil {
            trigger = DimReturnTrigger(uptime: uptime(), idleSeconds: idleSeconds(), lidState: lidState())
        }
        guard poll == nil else { return }
        poll = scheduler.repeating(0.5) { [weak self] in self?.pollForReturn() }
    }

    private func pollForReturn() {
        guard state != .idle, !terminating else { return }
        let sample = trigger?.sample(uptime: uptime(), idleSeconds: idleSeconds(), lidState: lidState())
        if sample?.lidOpened == true { requestRestore(reason: .lidOpened) }
        else if sample?.newInput == true { requestRestore(reason: .input) }
    }

    private func attemptRestore(remaining: Int, generation expectedGeneration: UInt) {
        guard expectedGeneration == generation, case .restorePending(let snapshot) = state else { return }
        retry = nil
        if restoreOnce(snapshot) { return }
        guard remaining > 1 else {
            restoring = false
            log.error("brightness restore retries exhausted; preserving recovery snapshot")
            return
        }
        retry = scheduler.after(retryDelay) { [weak self] in
            self?.attemptRestore(remaining: remaining - 1, generation: expectedGeneration)
        }
    }

    /// Returns true only after a completed/discarded episode. Resolve both the ID
    /// and physical UUID each time; never fall back to a stale display ID.
    private func restoreOnce(_ snapshot: BrightnessSnapshot) -> Bool {
        if brightnessResolved { return finish() }
        guard let display = backend.builtinID(), let uuid = backend.panelUUID(display) else { return false }
        guard snapshot.matchesPanel(uuid) else {
            return finish()
        }
        guard let current = backend.get(display), BrightnessSnapshot.isValidBrightness(current) else { return false }
        if snapshot.matches(current, snapshot.original) {
            return finish()
        }
        guard snapshot.matches(current, snapshot.lastApplied) else {
            // Brightness keys, manual settings and macOS automatic brightness all
            // count as external ownership. Respect their current value.
            return finish()
        }
        backend.set(display, snapshot.original)
        guard let verified = backend.get(display), BrightnessSnapshot.isValidBrightness(verified) else { return false }
        if snapshot.matches(verified, snapshot.original) || !snapshot.matches(verified, snapshot.lastApplied) {
            return finish()
        }
        return false
    }

    @discardableResult
    private func finish() -> Bool {
        resources.release()
        if state.snapshot != nil {
            brightnessResolved = true
            do { try sessionStore.clear() }
            catch {
                log.error("resolved brightness journal could not be deleted; keeping cleanup pending")
                return false
            }
        }
        generation &+= 1
        retry?.cancel()
        retry = nil
        restoring = false
        poll?.cancel()
        poll = nil
        trigger = nil
        brightnessResolved = false
        state = .idle
        return true
    }
}
