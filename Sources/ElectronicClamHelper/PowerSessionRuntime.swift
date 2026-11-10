import Foundation
import OSLog

/// One queue owns RPCs, watchdog/TTL decisions, disk state and all power writes.
/// This prevents an old expiry callback from undoing a newly accepted owner.
final class PowerSessionRuntime {
    static let shared = PowerSessionRuntime(controller: PowerSessionController(
        now: Date.init, uptime: { ProcessInfo.processInfo.systemUptime },
        write: PowerController.setSleepDisabled, read: PowerController.readSleepDisabled,
        load: HoldJournal.load, save: HoldJournal.save))

    private let queue = DispatchQueue(label: "com.jadhvank.eclam.power-session")
    private let controller: PowerSessionController
    private var timer: DispatchSourceTimer?
    private var onShutdownRestored: (() -> Void)?
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "power-session")

    init(controller: PowerSessionController) { self.controller = controller }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            controller.restoreAtLaunch()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.controller.tick()
                self.reportPendingRestore()
                if !self.controller.restorePending, let done = self.onShutdownRestored {
                    self.onShutdownRestored = nil
                    done()
                }
            }
            self.timer = timer
            timer.resume()
            reportPendingRestore()
        }
    }

    func setAppAwake(_ enabled: Bool) -> Bool {
        queue.sync { let ok = controller.setAppAwake(enabled); reportPendingRestore(); return ok }
    }
    func armHold(seconds: Double) -> Bool { queue.sync { controller.armHold(seconds: seconds) } }
    func cancelHoldAndRestore() -> Bool {
        queue.sync { let ok = controller.cancelHoldAndRestore(); reportPendingRestore(); return ok }
    }
    func heartbeat() { queue.sync { controller.heartbeat() } }
    var state: (disabled: Bool, remaining: Double) {
        queue.sync { (controller.sleepDisabled, controller.remainingSeconds) }
    }
    var lastTripReason: String? { queue.sync { controller.lastTripReason } }

    func shutdown(whenRestored: @escaping () -> Void) {
        queue.async {
            self.onShutdownRestored = whenRestored
            if self.controller.beginShutdown() {
                self.onShutdownRestored = nil
                whenRestored()
            } else {
                self.reportPendingRestore()
            }
        }
    }

    private func reportPendingRestore() {
        if controller.restorePending {
            log.error("sleep restoration pending; retrying power/journal in 5 seconds")
        }
    }
}

private enum HoldJournal {
    static let directory = "/Library/Application Support/com.jadhvank.eclam"
    static let path = directory + "/cli-hold"
    static func load() -> HoldState? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return HoldState.parse(text)
    }
    static func save(_ state: HoldState?) -> Bool {
        do {
            if let state = state {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try state.serialized.write(toFile: path, atomically: true, encoding: .utf8)
            } else if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            return true
        } catch { return false }
    }
}
