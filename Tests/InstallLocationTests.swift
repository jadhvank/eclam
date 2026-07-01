// InstallLocationTests.swift — standalone swiftc test program for the pure
// install-location gate (ADR-0038). Compiled together with
// Sources/Shared/InstallLocation.swift as the main file (top-level code is the
// program entry point). No XCTest, no SwiftPM — see scripts/test.sh. Exits 0 on
// success, 1 (with a descriptive message) on the first failed assertion.
//
// (The stdlib-only-ish constraint is on the *target* source; this test file
// freely uses Foundation/Darwin — getxattr/setxattr — to exercise the disk
// path of isQuarantined.)

import Foundation

// MARK: - tiny assert harness

var currentSuite = "?"
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("FAIL [\(currentSuite)]: \(msg)\n".utf8))
    exit(1)
}
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    if got != want { fail("\(what): got \(got), want \(want)") }
}

// MARK: - isTranslocated (pure)

func testIsTranslocated() {
    currentSuite = "isTranslocated"

    expectEqual(InstallLocation.isTranslocated(
        "/private/var/folders/ab/xyz/AppTranslocation/ABCD/d/ElectronicClam.app"),
        true, "translocation path ⇒ true")
    expectEqual(InstallLocation.isTranslocated("/Applications/ElectronicClam.app"),
                false, "/Applications path ⇒ false")
    expectEqual(InstallLocation.isTranslocated("/Users/x/Downloads/ElectronicClam.app"),
                false, "Downloads path ⇒ false")

    print("OK: isTranslocated")
}

// MARK: - isInApplications (pure)

func testIsInApplications() {
    currentSuite = "isInApplications"

    expectEqual(InstallLocation.isInApplications("/Applications/Foo.app"),
                true, "/Applications/Foo.app ⇒ true")
    expectEqual(InstallLocation.isInApplications(NSHomeDirectory() + "/Applications/Foo.app"),
                true, "~/Applications/Foo.app ⇒ true")
    expectEqual(InstallLocation.isInApplications("/Users/x/Downloads/Foo.app"),
                false, "Downloads ⇒ false")

    print("OK: isInApplications")
}

// MARK: - isQuarantined (stats a temp file on disk)

func testIsQuarantined() {
    currentSuite = "isQuarantined"

    let dir = NSTemporaryDirectory()
    let path = (dir as NSString).appendingPathComponent("eclam-iltest-\(getpid()).tmp")
    FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
    defer { try? FileManager.default.removeItem(atPath: path) }

    expectEqual(InstallLocation.isQuarantined(path), false,
                "fresh temp file has no quarantine attr")

    let rc = path.withCString { setxattr($0, "com.apple.quarantine", "test", 4, 0, 0) }
    if rc != 0 { fail("setxattr failed (errno \(errno)) — cannot exercise quarantine path") }

    expectEqual(InstallLocation.isQuarantined(path), true,
                "after setxattr the attr is detected")

    print("OK: isQuarantined")
}

// MARK: - registrationBlock (composition + precedence)

func testRegistrationBlock() {
    currentSuite = "registrationBlock"

    // translocation path ⇒ .translocated (reported regardless of quarantine)
    expectEqual(InstallLocation.registrationBlock(
        bundlePath: "/private/var/folders/ab/AppTranslocation/X/d/ElectronicClam.app"),
        InstallLocation.Block(kind: .translocated),
        "translocation ⇒ .translocated")

    // plain /Applications path (non-existent ⇒ not quarantined) ⇒ nil
    expectEqual(InstallLocation.registrationBlock(
        bundlePath: "/Applications/ElectronicClam.app"),
        nil, "/Applications, no quarantine ⇒ nil (safe)")

    print("OK: registrationBlock")
}

// MARK: - run

@main
enum InstallLocationTestMain {
    static func main() {
        testIsTranslocated()
        testIsInApplications()
        testIsQuarantined()
        testRegistrationBlock()
        print("OK: all InstallLocation suites")
    }
}
