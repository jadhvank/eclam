import Foundation

final class StateStore {
    var vpnDisconnectNotifyEnabled = false
    var vpnServiceName = "VPN"
}

final class TelegramNotifier {
    static let shared = TelegramNotifier()
    func notifyVpnDisconnected(serviceName: String) {}
}

final class SlackNotifier {
    static let shared = SlackNotifier()
    func notifyVpnDisconnected(serviceName: String) {}
}

final class ReleaseNotifier {
    static let shared = ReleaseNotifier()
    func notifyInfo(identifier: String, title: String, body: String) async {}
}

func NSL(_ key: String, _ english: String) -> String { english }
func NSLf(_ key: String, _ english: String, _ args: CVarArg...) -> String {
    String(format: english, arguments: args)
}
