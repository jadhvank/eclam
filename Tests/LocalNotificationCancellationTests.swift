import Foundation
import UserNotifications
func NSL(_ key: String, _ english: String) -> String { english }
func NSLf(_ key: String, _ english: String, _ args: CVarArg...) -> String { String(format: english, arguments: args) }
@main enum LocalNotificationCancellationTests {
    @MainActor static func main() async {
        var authorization: CheckedContinuation<Bool, Never>?
        var posted = 0
        let notifier = ReleaseNotifier(authorize: {
            await withCheckedContinuation { authorization = $0 }
        }, post: { _ in posted += 1 })
        let task = Task { await notifier.notifyInfo(identifier: "vpn", title: "test", body: "test") }
        while authorization == nil { await Task.yield() }
        task.cancel()
        authorization?.resume(returning: true)
        await task.value
        assert(posted == 0, "OFF while authorization is pending must suppress delivery")
        let allowed = ReleaseNotifier(authorize: { true }, post: { _ in posted += 1 })
        await allowed.notifyInfo(identifier: "test", title: "test", body: "test")
        assert(posted == 1)
        print("PASS local notification: cancellation after suspended authorization, allowed delivery")
    }
}
