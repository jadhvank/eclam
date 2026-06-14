import Foundation
import OSLog

/// Toggles the system `SleepDisabled` power setting directly via IOKit
/// (ADR-0001), replacing the M0 `pmset` shell-out. Runs as root in the daemon.
///
/// Why `SleepDisabled` and not a power assertion: it is the only mechanism that
/// prevents *lid-closed* (clamshell) sleep — public IOPM assertions do not
/// (ADR-0001 §컨텍스트; re-confirmed empirically 2026-06-09: assertions are
/// per-pid and auto-clear on process death, `SleepDisabled` is an ownerless
/// system-wide setting that does not). Because it is a persistent setting (the
/// same value `pmset -b disablesleep` writes), NOT an auto-clearing assertion,
/// the restore-on-exit (ADR-0002) + watchdog (ADR-0004 §5) machinery stays
/// mandatory regardless of how we write it.
///
/// `IOPMSetSystemPowerSetting` / `IOPMCopySystemPowerSettings` are stable
/// libIOKit SPI absent from the Swift IOKit umbrella module, so we bind the
/// symbols by hand (same pattern as `ActivityRelay.notify_post`). The helper
/// links `-framework IOKit` (scripts/build.sh).
enum PowerController {
    private static let log = Logger(subsystem: "com.jadhvank.eclam", category: "power")
    private static let sleepDisabledKey = "SleepDisabled" as CFString

    /// Sets the system `SleepDisabled` setting. Returns true on `kIOReturnSuccess`.
    @discardableResult
    static func setSleepDisabled(_ on: Bool) -> Bool {
        let kr = IOPMSetSystemPowerSetting(sleepDisabledKey, on ? kCFBooleanTrue : kCFBooleanFalse)
        guard kr == 0 else {  // kIOReturnSuccess == 0
            log.error("IOPMSetSystemPowerSetting(SleepDisabled=\(on, privacy: .public)) failed: kr=0x\(String(UInt32(bitPattern: kr), radix: 16), privacy: .public)")
            return false
        }
        return true
    }

    /// Reads the current system `SleepDisabled` setting. Returns false if the
    /// settings dictionary or the key is unavailable.
    static func readSleepDisabled() -> Bool {
        guard let settings = IOPMCopySystemPowerSettings()?.takeRetainedValue() as? [String: Any] else {
            log.error("IOPMCopySystemPowerSettings returned nil")
            return false
        }
        return (settings["SleepDisabled"] as? NSNumber)?.boolValue ?? false
    }
}

// MARK: - IOKit SleepDisabled SPI (absent from the Swift IOKit umbrella module)
//   CFDictionaryRef IOPMCopySystemPowerSettings(void);              // +1, caller owns
//   IOReturn        IOPMSetSystemPowerSetting(CFStringRef, CFTypeRef);

@_silgen_name("IOPMSetSystemPowerSetting")
private func IOPMSetSystemPowerSetting(_ key: CFString, _ value: CFTypeRef) -> Int32

@_silgen_name("IOPMCopySystemPowerSettings")
private func IOPMCopySystemPowerSettings() -> Unmanaged<CFDictionary>?
