// LaunchctlInspectTests.swift — standalone swiftc test program for the pure
// `LaunchctlInspect.parse(_:)` parser (ADR-0039 split-brain detection). No
// XCTest, no SwiftPM — see scripts/test.sh. Compiled together with
// LaunchctlInspect.swift + Subprocess.swift (Subprocess only so the source file
// resolves; this test exercises *only* parse()). Mirrors PolicyTests.swift's
// assert/print/exit(1) style. Exits 0 on success, 1 on the first failed assert.

import Foundation

// MARK: - tiny assert harness (mirrors PolicyTests.swift)

var currentSuite = "?"
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("FAIL [\(currentSuite)]: \(msg)\n".utf8))
    exit(1)
}
func check(_ cond: Bool, _ msg: @autoclosure () -> String) {
    if !cond { fail(msg()) }
}
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    if got != want { fail("\(what): got \(got), want \(want)") }
}

// MARK: - the real incident fixture (spawn failed / EX_CONFIG)
//
// Shape of a real `launchctl print system/com.jadhvank.eclam.helper` for the
// BTM record problem: exit 78, version 0.6.1, job state spawn failed. Spacing
// is deliberately uneven to exercise lenient trimming.

func testSpawnFailedFixture() {
    currentSuite = "parse(spawn failed)"

    let fixture = """
    com.jadhvank.eclam.helper = {
        active count = 0
        path = /System/Library/LaunchDaemons/com.jadhvank.eclam.helper.plist
        type = LaunchDaemon
        state = not running
        runs = 24
        last exit code =  78: EX_CONFIG
        parent bundle version = 0.6.1
        program = /Applications/ElectronicClam.app/Contents/Library/.../helper
        job state    =   spawn failed
    }
    """

    let info = LaunchctlInspect.parse(fixture)
    check(info.jobState?.contains("spawn failed") ?? false,
          "jobState should contain 'spawn failed', got \(String(describing: info.jobState))")
    expectEqual(info.lastExitCode, 78, "lastExitCode parsed from '78: EX_CONFIG'")
    expectEqual(info.parentBundleVersion, "0.6.1", "parentBundleVersion")
    expectEqual(info.spawnFailed, true, "spawnFailed derived true")

    print("OK: parse(spawn failed) fixture")
}

// MARK: - healthy fixture (running / exit 0)

func testHealthyFixture() {
    currentSuite = "parse(healthy)"

    let fixture = """
    com.jadhvank.eclam.helper = {
        active count = 1
        runs = 1
        last exit code = 0
        parent bundle version = 0.6.1
        job state = running
    }
    """

    let info = LaunchctlInspect.parse(fixture)
    expectEqual(info.jobState, "running", "jobState running")
    expectEqual(info.lastExitCode, 0, "lastExitCode 0")
    expectEqual(info.parentBundleVersion, "0.6.1", "parentBundleVersion")
    expectEqual(info.spawnFailed, false, "spawnFailed false when running + exit 0")

    print("OK: parse(healthy) fixture")
}

// MARK: - edge cases (none of the keys present, spawn failed via exit 78 only)

func testEdgeCases() {
    currentSuite = "parse(edge)"

    // no recognized keys ⇒ all nil, spawnFailed false
    let empty = LaunchctlInspect.parse("some output\nwith no = lines? actually = unrelated\n")
    expectEqual(empty.jobState, nil, "no job state ⇒ nil")
    expectEqual(empty.parentBundleVersion, nil, "no version ⇒ nil")
    expectEqual(empty.spawnFailed, false, "no signals ⇒ spawnFailed false")

    // spawnFailed also tripped by exit 78 alone (job state says running — exit wins)
    let exitOnly = LaunchctlInspect.parse("last exit code = 78\njob state = running\n")
    expectEqual(exitOnly.lastExitCode, 78, "exit 78 parsed")
    expectEqual(exitOnly.spawnFailed, true, "exit 78 alone ⇒ spawnFailed true")

    // value containing extra '=' is split on the FIRST '=' only
    let withEquals = LaunchctlInspect.parse("path = /a=b/c\nparent bundle version = 1.2.3=x\n")
    expectEqual(withEquals.parentBundleVersion, "1.2.3=x", "split on first '=' only")

    print("OK: parse(edge) cases")
}

// MARK: - run (@main: file isn't main.swift, compiled with other files)

@main
enum LaunchctlInspectTestMain {
    static func main() {
        testSpawnFailedFixture()
        testHealthyFixture()
        testEdgeCases()
        print("OK: all LaunchctlInspect suites")
    }
}
