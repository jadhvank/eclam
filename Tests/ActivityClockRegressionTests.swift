import Foundation

@main
enum ActivityClockRegressionTests {
    static func main() {
        let decision = AgentActivity.mtimeDecision(
            mtimeMatch: .init(path: "future.jsonl", age: -86400), freshness: 60,
            isClaude: false, liveClaudeEmpty: true, claudeCwdMatched: false,
            claudeSegment: nil)
        guard !decision.active else {
            print("FAIL: a file dated tomorrow must not keep the Mac awake")
            exit(1)
        }
        for age in [-Double.infinity, Double.infinity, Double.nan, -5.01] {
            precondition(!AgentActivity.isPlausibleAge(age))
        }
        precondition(AgentActivity.isPlausibleAge(-5))
        precondition(AgentActivity.hookDecision(hookPingAge: -86400, hookGrace: 30,
                                               pidFilePresent: false) == nil)
        print("PASS: future transcript rejected")
    }
}
