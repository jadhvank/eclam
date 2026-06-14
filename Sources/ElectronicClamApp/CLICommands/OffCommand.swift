import Foundation

/// `eclam off` — mirror of `on`. ADR-0007 §C.
/// ADR-0025 — CLI TTL hold 가 있으면 먼저 취소한다 (hold 중의 off 쓰기는
/// helper 가 소유권 규칙으로 무시하기 때문).
enum OffCommand: CLISubcommand {
    static func run(args: [String]) -> Int32 {
        return SleepDisabledRPC.cancelHoldThenOff()
    }
}
