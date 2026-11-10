import Foundation
import OSLog

let helperLog = Logger(subsystem: "com.jadhvank.eclam", category: "helper")

// SIGTERM handler (ADR-0002 §8 path 2): restore SleepDisabled=false then exit.
// `signal()` requires async-signal-safe work; we delegate to a dispatch source on main.
signal(SIGTERM, SIG_IGN)
let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSource.setEventHandler {
    helperLog.warning("SIGTERM received, restoring SleepDisabled=0")
    PowerSessionRuntime.shared.shutdown { exit(0) }
}
sigSource.resume()

// Restore persisted ownership before accepting requests. Failed restoration
// remains owned by the runtime and is retried every five seconds.
PowerSessionRuntime.shared.start()

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperServiceName.mach)
listener.delegate = delegate
listener.resume()

helperLog.info("ElectronicClamHelper started, listening on \(HelperServiceName.mach, privacy: .public)")
RunLoop.main.run()
