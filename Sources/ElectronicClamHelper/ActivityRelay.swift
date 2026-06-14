import Darwin
import Foundation
import OSLog

// `<notify.h>` is not exposed via the Darwin umbrella module on the swiftc
// command line. We declare the symbols we need by hand. Stable libSystem ABI.
@_silgen_name("notify_post")
private func notify_post(_ name: UnsafePointer<CChar>) -> UInt32

private let NOTIFY_STATUS_OK: UInt32 = 0

/// Daemon-side fan-out for `pingActivity`. We post a Darwin notification per
/// sanitized source so the app process can subscribe without keeping an XPC
/// connection open just to receive pings (ADR-0006 §G).
enum ActivityRelay {
    private static let log = Logger(subsystem: "com.jadhvank.eclam", category: "activity")

    static func post(source: String) {
        let name = "\(HelperServiceName.activityNotifyPrefix).\(source)"
        let status = name.withCString { cstr -> UInt32 in
            notify_post(cstr)
        }
        if status != NOTIFY_STATUS_OK {
            log.error("notify_post(\(name, privacy: .public)) status=\(status, privacy: .public)")
        }
    }
}
