import Foundation
import IOKit

/// Existing ADR-0021 IORegistry read, shared with SafetyMonitor. This does not
/// infer hinge position from display enumeration or introduce another private API.
enum LidStateReader {
    static func read() -> LidState {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return .unavailable }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return .unavailable
        }
        if let closed = raw as? Bool { return closed ? .closed : .open }
        if let number = raw as? NSNumber { return number.boolValue ? .closed : .open }
        return .unavailable
    }
}
