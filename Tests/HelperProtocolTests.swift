// Standalone test program for `HelperServiceName.sanitizeActivitySource`.
// Compiled together with Sources/Shared/HelperProtocol.swift:
//
//   swiftc -o /tmp/eclam_helpertests \
//     Sources/Shared/HelperProtocol.swift Tests/HelperProtocolTests.swift
//   /tmp/eclam_helpertests
//
// No XCTest dependency. Uses a `@main` entry point (top-level code is only
// allowed in a file literally named `main.swift`, which this is not). Exits
// non-zero on the first failed assertion (ADR-0023).

import Foundation

@main
struct HelperProtocolTests {
    static func check(_ cond: Bool, _ message: @autoclosure () -> String) {
        if !cond {
            FileHandle.standardError.write(Data(("FAIL: " + message() + "\n").utf8))
            exit(1)
        }
    }

    static func main() {
        let limit = HelperServiceName.maxActivitySourceLength

        // (a) normal sources pass through unchanged & lowercased.
        check(HelperServiceName.sanitizeActivitySource("claude") == "claude",
              "lowercase ascii source should pass through unchanged")
        check(HelperServiceName.sanitizeActivitySource("Codex") == "codex",
              "mixed-case source should be lowercased")
        check(HelperServiceName.sanitizeActivitySource("session:my-run") == "sessionmy-run",
              "legal chars kept, ':' stripped, '-' preserved")
        check(HelperServiceName.sanitizeActivitySource("agent_1.2-x") == "agent_1.2-x",
              "underscore, digit, dot, dash all allowed")

        // (b) an over-long input is capped to the limit.
        let longRaw = String(repeating: "a", count: limit + 500)
        let cappedOut = HelperServiceName.sanitizeActivitySource(longRaw)
        check(cappedOut.count == limit,
              "over-long input should be capped to \(limit), got \(cappedOut.count)")
        check(cappedOut == String(repeating: "a", count: limit),
              "capped output should be exactly the first \(limit) legal chars")

        // A long input made of mixed legal + illegal chars: only legal chars
        // count toward the cap, and the result never exceeds the limit.
        let mixedLong = String(repeating: "a!", count: limit + 50) // half illegal
        let mixedOut = HelperServiceName.sanitizeActivitySource(mixedLong)
        check(mixedOut.count == limit,
              "mixed long input should still cap at \(limit), got \(mixedOut.count)")

        // At-limit input is untouched; one over is trimmed by exactly one.
        let exact = String(repeating: "z", count: limit)
        check(HelperServiceName.sanitizeActivitySource(exact) == exact,
              "input exactly at the limit should be unchanged")
        let overByOne = String(repeating: "z", count: limit + 1)
        check(HelperServiceName.sanitizeActivitySource(overByOne).count == limit,
              "input one over the limit should be trimmed to the limit")

        // (c) charset filter strips disallowed chars (spaces, slashes, unicode).
        check(HelperServiceName.sanitizeActivitySource("foo bar") == "foobar",
              "spaces should be stripped")
        check(HelperServiceName.sanitizeActivitySource("a/b\\c") == "abc",
              "slashes should be stripped")
        check(HelperServiceName.sanitizeActivitySource("héllo") == "hllo",
              "non-ascii chars should be stripped")
        check(HelperServiceName.sanitizeActivitySource("名前") == "",
              "all-disallowed input should sanitize to empty")
        check(HelperServiceName.sanitizeActivitySource("!@#$%^&*()") == "",
              "punctuation-only input should sanitize to empty")
        check(HelperServiceName.sanitizeActivitySource("CLAUDE\t\n ") == "claude",
              "control/whitespace stripped, rest lowercased")

        // (d) v0.5 P1 — protocol version constant guard. The handshake
        // contract (HelperBridge ↔ HelperService) hangs off this constant;
        // bumping it must be a deliberate act recorded in the same commit
        // (update this expectation alongside the protocol change).
        check(HelperProtocolVersion.current == 1,
              "HelperProtocolVersion.current expected 1, got \(HelperProtocolVersion.current) — bump this guard deliberately with the protocol change")

        print("OK: HelperProtocol sanitize + version guard")
    }
}
