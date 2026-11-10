import Foundation
import IOKit.pwr_mgt
@main enum DisplayAssertionStatusTests {
    static func main() {
        let rows: [[String: Any]] = [
            [kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionLevelKey: 1, kIOPMAssertionNameKey: "Electric Clam - dim"],
            [kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionLevelKey: 0, kIOPMAssertionNameKey: "off"],
            [kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionLevelKey: 1, kIOPMAssertionNameKey: "system only"]]
        let entries = DisplayAssertionStatus.parse([NSNumber(value: 42): rows])
        assert(entries == [.init(pid: 42, name: "Electric Clam - dim")])
        assert(entries[0].isElectronicClam)
        assert(DisplayAssertionStatus.Entry(pid: 42, name: "Electronic Clam - dim").isElectronicClam)
        assert(DisplayAssertionStatus.Entry(pid: 42, name: "eclam - display").isElectronicClam)
        assert(!DisplayAssertionStatus.Entry(pid: 1, name: "another app").isElectronicClam)
        print("PASS assertion diagnostics: active display requests only, names and process ownership")
    }
}
