import Foundation
import IOKit.pwr_mgt
import OSLog

/// Owns only the user's opt-in display assertion. Explicit display sleep does
/// not need a suspend/resume timer: an idle-sleep assertion does not relight a
/// display that has already been put to sleep. Dim changes brightness only.
final class DisplayAwakeHolder {
    private let acquire: () -> IOPMAssertionID?
    private let release: (IOPMAssertionID) -> Void
    private var assertionID: IOPMAssertionID?
    var isHolding: Bool { assertionID != nil }

    init(acquire: @escaping () -> IOPMAssertionID? = DisplayAwakeHolder.acquireSystemAssertion,
         release: @escaping (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }) {
        self.acquire = acquire
        self.release = release
    }

    deinit { apply(keepAwake: false) }

    func apply(keepAwake: Bool) {
        if keepAwake {
            if assertionID == nil { assertionID = acquire() }
        } else if let id = assertionID {
            assertionID = nil
            release(id)
        }
    }

    private static func acquireSystemAssertion() -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Electric Clam - keep display awake" as CFString, &id)
        guard result == kIOReturnSuccess else {
            Logger(subsystem: "com.jadhvank.eclam", category: "displayawake")
                .error("Display assertion acquisition failed: \(result, privacy: .public)")
            return nil
        }
        return id
    }
}
