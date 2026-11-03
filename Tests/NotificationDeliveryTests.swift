import Foundation
import Darwin

// Compile actual notifiers with only their unrelated UI/state dependencies stubbed.
final class StateStore {
    var cpuTempCelsius: Double?
    var gpuTempCelsius: Double?
    var batteryTempCelsius: Double?
    var batteryPercent: Int?
    var isCharging = false
    var activeAgents: Set<String> = []
}
func NSL(_ key: String, _ english: String) -> String { english }
func NSLf(_ key: String, _ english: String, _ args: CVarArg...) -> String {
    String(format: english, arguments: args)
}

private var checks = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}

private final class FakeCancellation: NotificationCancellation {
    var cancelled = false
    let action: () -> Void
    init(action: @escaping () -> Void = {}) { self.action = action }
    func cancel() { cancelled = true }
}

private final class FakeTransport: NotificationTransport {
    struct Sent {
        let request: URLRequest
        let completion: (Data?, URLResponse?, Error?) -> Void
        let cancellation: FakeCancellation
    }
    var sent: [Sent] = []
    func send(_ request: URLRequest,
              completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> NotificationCancellation {
        dispatchPrecondition(condition: .onQueue(.main))
        let cancellation = FakeCancellation()
        sent.append(Sent(request: request, completion: completion, cancellation: cancellation))
        return cancellation
    }
    func complete(_ index: Int, body: String = "{\"ok\":true}", status: Int = 200, error: Error? = nil,
                  background: Bool = false) {
        let sent = self.sent[index]
        let response = HTTPURLResponse(url: sent.request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        if background {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                sent.completion(Data(body.utf8), response, error)
                done.signal()
            }
            done.wait()
        } else {
            sent.completion(Data(body.utf8), response, error)
        }
        drainMain()
    }
}

private final class FakeScheduler {
    var pending: [FakeCancellation] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> NotificationCancellation {
        dispatchPrecondition(condition: .onQueue(.main))
        expect(delay == 5, "retry remains a single five-second delay")
        let pending = FakeCancellation(action: action)
        self.pending.append(pending)
        return pending
    }
}

private func drainMain() {
    var complete = false
    DispatchQueue.main.async { complete = true }
    while !complete { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001)) }
}

private let token = "xoxb-1234567890-testsecret"
private let hook = "https://hooks.slack.com/services/T0123/B0123/secretvalue"
private let telegramToken = "123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAsecret"
private let leakedError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
    userInfo: [NSLocalizedDescriptionKey: "secret https://hooks.slack.com/services/T/B/secretvalue xoxb-testsecret",
               NSURLErrorFailingURLStringErrorKey: "https://api.telegram.org/botsecret/sendMessage"])
private func slackSettings(_ credential: String = token, enabled: Bool = true) -> SlackSettings {
    SlackSettings(enabled: enabled, credential: credential, channel: "C01234567",
                  notifyAwakeStart: true, notifyAwakeEnd: true, notifySafety: true)
}
private func telegramSettings(enabled: Bool = true) -> TelegramSettings {
    TelegramSettings(enabled: enabled, botToken: telegramToken, chatId: "1234",
                     notifyAwakeStart: true, notifyAwakeEnd: true, notifySafety: true)
}

@main
private enum NotificationDeliveryTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try storage(directory)
        try settingsSaveFailure(directory)
        redirectPolicy()
        slack(directory)
        telegram(directory)
        print("Notification delivery/storage tests: \(checks) passed (fake transport; no network)")
    }

    static func storage(_ directory: URL) throws {
        let file = directory.appendingPathComponent("secret.json")
        let data = Data("private credential".utf8)
        let previousMask = umask(0)
        defer { umask(previousMask) }
        try SecureNotificationSettings.write(data, to: file)
        expect(try! Data(contentsOf: file) == data, "first secure save round-trips")
        expect((try! FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue == 0o600,
               "first save is 0600 even with umask 000")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try SecureNotificationSettings.write(Data("replacement".utf8), to: file)
        expect((try! FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue == 0o600,
               "atomic replacement publishes a 0600 inode")
        expect(try! Data(contentsOf: file) == Data("replacement".utf8), "replacement data round-trips")
        expect(try! FileManager.default.contentsOfDirectory(atPath: directory.path) == ["secret.json"],
               "secure save leaves no temporary credential file")
        do {
            try SecureNotificationSettings.write(data, to: directory)
            fatalError("rename over a directory must fail")
        } catch {}
        expect(!(try! FileManager.default.contentsOfDirectory(atPath: directory.path)).contains(where: { $0.hasPrefix(".notification-") }),
               "failed save removes temporary credential file")
    }

    static func settingsSaveFailure(_ directory: URL) throws {
        let fm = FileManager.default
        let parent = directory.appendingPathComponent("slack-save-secret")
        let backup = directory.appendingPathComponent("slack-save-backup")
        let file = parent.appendingPathComponent("slack.json")
        let transport = FakeTransport()
        let notifier = SlackNotifier(settingsURL: file, transport: transport)
        expect(notifier.update(settings: slackSettings()), "Slack initial save reports success")
        expect((try! JSONDecoder().decode(SlackSettings.self, from: Data(contentsOf: file))).enabled,
               "Slack fixture initially persists ON")
        try fm.moveItem(at: parent, to: backup)
        try Data("blocks directory creation".utf8).write(to: parent)
        expect(!notifier.update(settings: slackSettings(enabled: false)), "failed Slack save reports failure")
        expect(!notifier.settings.enabled, "failed Slack save still disables this session")
        expect(notifier.settingsSaveError?.contains("restart") == true,
               "Slack exposes the durable-save/restart warning")
        expect(!notifier.settingsSaveError!.contains("secret") && !notifier.settingsSaveError!.contains(directory.path),
               "Slack save diagnostics contain no credential or filesystem path")
        expect(!notifier.update(settings: slackSettings(enabled: false)), "unchanged Slack settings retry and still report blocked save")
        notifier.notifyVpnDisconnected(serviceName: "save failed")
        expect(transport.sent.isEmpty, "failed OFF save cannot send an automatic Slack message")
        expect((try! JSONDecoder().decode(SlackSettings.self,
            from: Data(contentsOf: backup.appendingPathComponent("slack.json")))).enabled,
               "failed write has not changed previous durable Slack setting")
        try fm.removeItem(at: parent)
        try fm.moveItem(at: backup, to: parent)
        expect(notifier.update(settings: slackSettings(enabled: false)), "unchanged Slack OFF retries successfully after recovery")
        expect(notifier.settingsSaveError == nil, "successful Slack retry clears persistent warning")
        let reloaded = SlackNotifier(settingsURL: file, transport: FakeTransport())
        expect(!reloaded.settings.enabled, "saved Slack OFF survives reload")
        notifier.stop()
        reloaded.stop()

        let telegramParent = directory.appendingPathComponent("telegram-save-secret")
        let telegramBackup = directory.appendingPathComponent("telegram-save-backup")
        let telegramFile = telegramParent.appendingPathComponent("telegram.json")
        let telegramTransport = FakeTransport()
        let telegram = TelegramNotifier(settingsURL: telegramFile, transport: telegramTransport)
        expect(telegram.update(settings: telegramSettings()), "Telegram initial save reports success")
        expect((try! JSONDecoder().decode(TelegramSettings.self, from: Data(contentsOf: telegramFile))).enabled,
               "Telegram fixture initially persists ON")
        try fm.moveItem(at: telegramParent, to: telegramBackup)
        try Data("blocks directory creation".utf8).write(to: telegramParent)
        expect(!telegram.update(settings: telegramSettings(enabled: false)), "failed Telegram save reports failure")
        expect(!telegram.settings.enabled, "failed Telegram save still disables this session")
        expect(telegram.settingsSaveError?.contains("restart") == true,
               "Telegram exposes the durable-save/restart warning")
        expect(!telegram.settingsSaveError!.contains("secret") && !telegram.settingsSaveError!.contains(directory.path),
               "Telegram save diagnostics contain no credential or filesystem path")
        expect(!telegram.update(settings: telegramSettings(enabled: false)), "unchanged Telegram settings retry and report blocked save")
        telegram.notifyVpnDisconnected(serviceName: "save failed")
        expect(telegramTransport.sent.isEmpty, "failed OFF save cannot send an automatic Telegram message")
        expect((try! JSONDecoder().decode(TelegramSettings.self,
            from: Data(contentsOf: telegramBackup.appendingPathComponent("telegram.json")))).enabled,
               "failed write has not changed previous durable Telegram setting")
        try fm.removeItem(at: telegramParent)
        try fm.moveItem(at: telegramBackup, to: telegramParent)
        expect(telegram.update(settings: telegramSettings(enabled: false)), "unchanged Telegram OFF retries successfully after recovery")
        expect(telegram.settingsSaveError == nil, "successful Telegram retry clears persistent warning")
        let telegramReloaded = TelegramNotifier(settingsURL: telegramFile, transport: FakeTransport())
        expect(!telegramReloaded.settings.enabled, "saved Telegram OFF survives reload")
        telegram.stop()
        telegramReloaded.stop()
    }

    static func redirectPolicy() {
        let configuration = URLSessionNotificationTransport.configuration()
        expect(configuration.urlCredentialStorage == nil, "session does not use shared credential storage")
        expect(configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies,
               "session does not retain cookies")
        expect(configuration.urlCache?.diskCapacity ?? 0 == 0, "session has no persistent disk cache")
        let delegate = NotificationRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // The task is never resumed; exercise the real delegate directly, without network traffic.
        let task = session.dataTask(with: URL(string: hook)!)
        let response = HTTPURLResponse(url: URL(string: hook)!, statusCode: 302,
                                       httpVersion: nil, headerFields: nil)!
        for target in ["https://attacker.example/collect", "https://hooks.slack.com/services/T/B/other"] {
            var called = false
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: URL(string: target)!)) { request in
                called = true
                expect(request == nil, "all redirects are refused")
            }
            expect(called, "redirect delegate completes")
        }
    }

    static func slack(_ directory: URL) {
        let transport = FakeTransport(), scheduler = FakeScheduler()
        let notifier = SlackNotifier(settingsURL: directory.appendingPathComponent("slack.json"),
                                     transport: transport, schedule: scheduler.schedule)
        notifier.notifyVpnDisconnected(serviceName: "test")
        expect(transport.sent.isEmpty, "Slack defaults off")
        notifier.update(settings: slackSettings())
        var results: [String?] = []
        notifier.sendTest { error in
            dispatchPrecondition(condition: .onQueue(.main))
            results.append(error)
        }
        transport.complete(0, error: leakedError, background: true)
        expect(results.isEmpty && scheduler.pending.count == 1, "transport failure schedules one retry")
        scheduler.pending[0].action()
        expect(transport.sent.count == 2 && transport.sent[0].request == transport.sent[1].request,
               "retry preserves original token, destination, headers and message body")
        transport.complete(1, error: leakedError)
        expect(results.count == 1 && !(results[0] ?? "").contains("secret"), "Slack transport diagnostics exclude secrets")
        expect(scheduler.pending.count == 1, "second transport failure does not retry again")

        notifier.sendTest { results.append($0) }
        transport.complete(2, error: leakedError)
        let staleRetry = scheduler.pending[1]
        var changed = slackSettings()
        changed.channel = "C99999999"
        notifier.update(settings: changed)
        expect(staleRetry.cancelled && results.count == 2 && results[1] != nil,
               "destination change cancels retry and releases UI callback exactly once")
        staleRetry.action() // Simulate cancellation racing an already queued timer.
        expect(transport.sent.count == 3, "cancelled retry cannot read or send to a new destination")

        notifier.sendTest { results.append($0) }
        var disabled = changed
        disabled.enabled = false
        notifier.update(settings: disabled)
        notifier.update(settings: changed)
        expect(transport.sent[3].cancellation.cancelled, "master OFF cancels active request")
        let resultCount = results.count
        transport.complete(3)
        expect(results.count == resultCount, "OFF then ON does not resurrect old success completion")

        notifier.update(settings: slackSettings(hook))
        notifier.sendTest { results.append($0) }
        let request = transport.sent[4].request
        expect(request.url?.absoluteString == hook && request.value(forHTTPHeaderField: "Authorization") == nil,
               "webhook uses validated fixed URL and no bearer header")
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        expect(body["channel"] == nil, "webhook does not override its configured destination")
        transport.complete(4, body: "private secretvalue https://hooks.slack.com/services/T/B/secret")
        expect(!(results.last! ?? "").contains("secret"), "untrusted webhook errors cannot leak credentials")
        expect(SlackSupport.parsePostResult(Data("{\"ok\":false,\"error\":\"xoxb-secret\"}".utf8)).error == "unknown error",
               "Web API parser never returns an arbitrary error string")

        var lookupSettings = slackSettings()
        lookupSettings.channel = "general"
        notifier.update(settings: lookupSettings)
        var lookupResults: [(String?, String?)] = []
        notifier.lookupChannelId { lookupResults.append(($0, $1)) }
        expect(transport.sent[5].request.url?.host == "slack.com", "lookup uses fixed Slack API host")
        notifier.update(settings: slackSettings())
        expect(transport.sent[5].cancellation.cancelled && lookupResults.count == 1 && lookupResults[0].0 == nil,
               "settings change cancels pending lookup")
        transport.complete(5, body: "{\"ok\":true,\"channels\":[{\"id\":\"C99999999\",\"name\":\"general\"}]}")
        expect(lookupResults.count == 1, "stale lookup cannot overwrite new channel")

        notifier.update(settings: lookupSettings)
        notifier.lookupChannelId { lookupResults.append(($0, $1)) }
        transport.complete(6, body: "{\"ok\":true,\"channels\":[],\"response_metadata\":{\"next_cursor\":\"page2\"}}", background: true)
        expect(transport.sent.count == 8, "lookup pagination continues on main queue")
        notifier.stop()
        expect(transport.sent[7].cancellation.cancelled, "stop cancels paginated lookup")
        notifier.sendTest { results.append($0) }
        notifier.lookupChannelId { lookupResults.append(($0, $1)) }
        notifier.notifyVpnDisconnected(serviceName: "after stop")
        expect(transport.sent.count == 8, "terminal stop rejects new test, lookup and automatic sends")
        expect(results.last! != nil && lookupResults.last!.1 != nil, "stopped UI requests complete with cancellation")

        let testTransport = FakeTransport()
        let testNotifier = SlackNotifier(settingsURL: directory.appendingPathComponent("slack-off.json"), transport: testTransport)
        testNotifier.update(settings: slackSettings(enabled: false))
        testNotifier.notifyVpnDisconnected(serviceName: "off")
        expect(testTransport.sent.isEmpty, "master OFF gates automatic Slack events")
        var testSucceeded = false
        testNotifier.sendTest {
            dispatchPrecondition(condition: .onQueue(.main))
            testSucceeded = $0 == nil
        }
        expect(testTransport.sent.count == 1, "explicit test remains available before opt-in")
        testTransport.complete(0, background: true)
        expect(testSucceeded, "successful Slack response reaches completion on main")
        var automatic = slackSettings()
        automatic.notifySafety = false
        automatic.notifyAwakeStart = false
        automatic.notifyAwakeEnd = false
        testNotifier.update(settings: automatic)
        testNotifier.notifyVpnDisconnected(serviceName: "enabled")
        expect(testTransport.sent.count == 2, "VPN safety net uses only master opt-in gate")
        testNotifier.stop()
    }

    static func telegram(_ directory: URL) {
        let transport = FakeTransport(), scheduler = FakeScheduler()
        let notifier = TelegramNotifier(settingsURL: directory.appendingPathComponent("telegram.json"),
                                        transport: transport, schedule: scheduler.schedule)
        notifier.notifyVpnDisconnected(serviceName: "test")
        expect(transport.sent.isEmpty, "Telegram defaults off")
        notifier.update(settings: telegramSettings())
        var results: [String?] = []
        notifier.sendTest { results.append($0) }
        transport.complete(0, error: leakedError, background: true)
        scheduler.pending[0].action()
        expect(transport.sent[0].request == transport.sent[1].request, "Telegram retry preserves token, chat ID and payload")
        transport.complete(1, error: leakedError)
        expect(results.count == 1 && !(results[0] ?? "").contains("secret"), "Telegram transport errors exclude token URL")
        let lastSend = notifier.lastSendAt
        notifier.sendTest { results.append($0) }
        transport.complete(2, error: leakedError)
        notifier.update(settings: telegramSettings(enabled: false))
        notifier.update(settings: telegramSettings())
        scheduler.pending[1].action()
        expect(scheduler.pending[1].cancelled && transport.sent.count == 3, "Telegram OFF then ON cancels pending retry")
        expect(notifier.lastSendAt == lastSend, "cancelled sends do not overwrite last delivery result")
        notifier.sendTest { results.append($0) }
        notifier.update(settings: telegramSettings(enabled: false))
        notifier.update(settings: telegramSettings())
        let count = results.count
        transport.complete(3)
        expect(results.count == count && notifier.lastSendAt == lastSend, "stale Telegram success has no completion/state effects")
        notifier.sendTest { results.append($0) }
        transport.complete(4, body: "{\"ok\":false,\"description\":\"https://api.telegram.org/botsecret/sendMessage\"}")
        expect(!(results.last! ?? "").contains("secret"), "Telegram response descriptions are allowlisted")
        notifier.sendTest { results.append($0) }
        transport.complete(5, status: 302)
        expect(results.last! != nil, "redirect response is never accepted as successful delivery")

        var lookups: [(String?, String?)] = []
        notifier.detectChatId { lookups.append(($0, $1)) }
        var changed = telegramSettings()
        changed.botToken = "99999:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        notifier.update(settings: changed)
        expect(transport.sent[6].cancellation.cancelled && lookups.count == 1 && lookups[0].0 == nil,
               "Telegram token changes cancel getUpdates")
        transport.complete(6, body: "{\"ok\":true,\"result\":[{\"message\":{\"chat\":{\"id\":999}}}]}")
        expect(lookups.count == 1, "old detection cannot overwrite current chat ID")
        notifier.sendTest { results.append($0) }
        transport.complete(7, error: leakedError)
        let pending = scheduler.pending.last!
        notifier.stop()
        pending.action()
        notifier.sendTest { results.append($0) }
        notifier.detectChatId { lookups.append(($0, $1)) }
        notifier.notifyVpnDisconnected(serviceName: "after stop")
        expect(pending.cancelled && transport.sent.count == 8, "Telegram stop cancels retries and rejects all new requests")

        let successTransport = FakeTransport()
        let successNotifier = TelegramNotifier(settingsURL: directory.appendingPathComponent("telegram-off.json"),
                                               transport: successTransport)
        successNotifier.update(settings: telegramSettings(enabled: false))
        successNotifier.notifyVpnDisconnected(serviceName: "off")
        expect(successTransport.sent.isEmpty, "master OFF gates automatic Telegram events")
        var succeeded = false
        successNotifier.sendTest {
            dispatchPrecondition(condition: .onQueue(.main))
            succeeded = $0 == nil
        }
        expect(successTransport.sent.count == 1, "explicit Telegram test remains available before opt-in")
        successTransport.complete(0, background: true)
        expect(succeeded && successNotifier.lastSendAt != nil && successNotifier.lastSendResult == nil,
               "successful Telegram response updates result on main")
        successNotifier.stop()
    }
}
