import Foundation
import IOKit.pwr_mgt

/// Read actual powerd assertions; never infer a held assertion from an option.
/// A missing/failed query remains unknown, rather than being reported as zero.
enum DisplayAssertionStatus {
    struct Entry: Equatable {
        let pid: Int32
        let name: String
        var isElectronicClam: Bool { name.hasPrefix("Electric Clam") || name.hasPrefix("Electronic Clam") || name.hasPrefix("eclam") }
        var json: [String: Any] { ["pid": pid, "name": name] }
    }
    struct Snapshot {
        let entries: [Entry]?
        let systemPreventsDisplaySleep: Bool?
        let error: String?
    }
    static func read(processID: Int32? = nil) -> Snapshot {
        var raw: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&raw)
        guard result == kIOReturnSuccess, let values = raw?.takeRetainedValue() as? [AnyHashable: Any] else {
            return Snapshot(entries: nil, systemPreventsDisplaySleep: nil, error: "IOPMCopyAssertionsByProcess: \(result)")
        }
        var status: Unmanaged<CFDictionary>?
        let statusResult = IOPMCopyAssertionsStatus(&status)
        let statusValues = status?.takeRetainedValue() as? [String: Any]
        let system = statusResult == kIOReturnSuccess
            ? (statusValues?[kIOPMAssertionTypePreventUserIdleDisplaySleep] as? NSNumber).map { $0.intValue > 0 }
            : nil
        return Snapshot(entries: parse(values).filter { processID == nil || $0.pid == processID },
                        systemPreventsDisplaySleep: system,
                        error: statusResult == kIOReturnSuccess ? nil : "IOPMCopyAssertionsStatus: \(statusResult)")
    }
    static func parse(_ values: [AnyHashable: Any]) -> [Entry] {
        var entries: [Entry] = []
        for (key, value) in values {
            guard let pid = key as? NSNumber, let assertions = value as? [[String: Any]] else { continue }
            for assertion in assertions {
                guard assertion[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleDisplaySleep,
                      let level = assertion[kIOPMAssertionLevelKey] as? NSNumber, level.intValue != 0 else { continue }
                entries.append(Entry(pid: pid.int32Value, name: assertion[kIOPMAssertionNameKey] as? String ?? "unnamed"))
            }
        }
        return entries.sorted { ($0.pid, $0.name) < ($1.pid, $1.name) }
    }
}
