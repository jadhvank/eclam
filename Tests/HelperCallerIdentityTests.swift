// Standalone test program for the pure parts of `HelperCallerIdentity`
// (ADR-0023 §④ 방법 A — XPC caller 메서드 가드).
//
// Compiled together with Sources/ElectronicClamHelper/HelperCallerIdentity.swift:
//
//   swiftc -framework Foundation -framework Security \
//     -o /tmp/eclam_calleridtests \
//     Sources/ElectronicClamHelper/HelperCallerIdentity.swift \
//     Tests/HelperCallerIdentityTests.swift
//   /tmp/eclam_calleridtests
//
// Only the *pure* requirement-string builder is exercised here. The audit-token
// → SecCode → SecCodeCheckValidity path needs a live signed XPC peer and a GUI
// session, so it is verified manually (see the session summary). No XCTest;
// `@main` entry point, exits non-zero on first failed assertion.

import Foundation
import Security

@main
struct HelperCallerIdentityTests {
    static func check(_ cond: Bool, _ message: @autoclosure () -> String) {
        if !cond {
            FileHandle.standardError.write(Data(("FAIL: " + message() + "\n").utf8))
            exit(1)
        }
    }

    static func main() {
        // (a) hook-only requirement pins anchor + Team ID + the single hook id.
        let req = HelperCallerIdentity.hookRequirementString()
        check(req.contains("anchor apple generic"),
              "requirement must keep the Apple anchor")
        check(req.contains("certificate leaf[subject.OU] = \"GBQ3DN529X\""),
              "requirement must pin the Developer ID Team OU")
        check(req.contains("identifier \"com.jadhvank.eclam.hook\""),
              "requirement must pin the hook code-sign identifier")

        // (b) it must NOT match the app/CLI identifier — that disjointness is
        // what lets `isHook == false` mean app/CLI (the system listener
        // requirement already guaranteed the caller is one of the two).
        check(!req.contains("identifier \"com.jadhvank.eclam\" "),
              "hook requirement must not also admit the app/CLI identifier")
        check(!req.contains(" or identifier"),
              "hook requirement must be a single-identifier pin (no 'or' clause)")

        // (c) the requirement string is a valid code-signing requirement —
        // SecRequirementCreateWithString compiles it without error. This catches
        // syntax drift (e.g. a stray quote) at test time rather than at runtime
        // on a live connection.
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(req as CFString, [], &requirement)
        check(status == errSecSuccess && requirement != nil,
              "hook requirement string must compile via SecRequirementCreateWithString (status \(status))")

        // (d) parameterised builder substitutes custom id/team (keeps the
        // pure function honest if call sites ever pass overrides).
        let custom = HelperCallerIdentity.hookRequirementString(
            identifier: "com.example.hook", teamID: "ABCDE12345")
        check(custom.contains("identifier \"com.example.hook\""),
              "custom identifier should be substituted")
        check(custom.contains("\"ABCDE12345\""),
              "custom team id should be substituted")

        // (e) the constants match the build.sh codesign --identifier / SIGN_ID OU.
        check(HelperCallerIdentity.hookIdentifier == "com.jadhvank.eclam.hook",
              "hookIdentifier must match build.sh `codesign --identifier com.jadhvank.eclam.hook`")
        check(HelperCallerIdentity.teamID == "GBQ3DN529X",
              "teamID must match the Developer ID Team (build.sh SIGN_ID OU)")

        print("OK: HelperCallerIdentity requirement-string builder")
    }
}
