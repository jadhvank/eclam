import Foundation
import ServiceManagement

/// `eclam on [--for <dur>] [--forever]` — ADR-0025 CLI TTL hold.
///
/// 기본 2시간(사용자 결정 2026-06-11): helper 가 자체 타이머로 만료 시
/// 복원하므로 GUI heartbeat 없이도 유효하다. 이전의 단순 `setSleepDisabled`
/// 는 GUI 미실행 시 watchdog(20s)이 곧 되돌려 사실상 무의미했다.
/// `--forever` 는 배터리/발열 가드(앱 내 SafetyMonitor)가 없는 상태가 될 수
/// 있어 경고와 함께만 허용한다.
enum OnCommand: CLISubcommand {
    /// ADR-0025 기본 hold — 2h.
    static let defaultHoldSeconds: Double = 2 * 3600

    static func run(args: [String]) -> Int32 {
        var seconds = defaultHoldSeconds
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--forever":
                seconds = -1
            case "--for":
                guard i + 1 < args.count,
                      let s = DurationParse.seconds(from: args[i + 1]) else {
                    CLIStderr.print("eclam on: --for needs a duration like 30m, 2h, 1h30m")
                    return 1
                }
                seconds = s
                i += 1
            default:
                CLIStderr.print("eclam on: unknown argument '\(args[i])' (try --for <dur> or --forever)")
                return 1
            }
            i += 1
        }

        let rc = SleepDisabledRPC.hold(seconds: seconds)
        guard rc == 0 else { return rc }
        if seconds < 0 {
            print("eclam: on — no expiry.")
            CLIStderr.print("warning: battery/thermal guards live in the app; "
                + "with no GUI running, nothing will put a hot or draining Mac back to sleep.")
        } else {
            print("eclam: on — auto-release in \(DurationParse.shortFormat(seconds: seconds)) "
                + "(--for <dur> / --forever to change)")
        }
        return 0
    }
}

/// Shared synchronous RPC used by `on` / `off`. Lives outside `HelperBridge`
/// because that type dispatches completions to `.main`, and the CLI does not
/// run a runloop.
enum SleepDisabledRPC {
    /// 공통 보일러플레이트: 승인 게이트 → privileged XPC 연결 → 동기 1-call.
    /// `op` 는 proxy 에 RPC 를 걸고 완료 콜백을 정확히 1회 부른다.
    /// 반환: 0 성공 / 2 unreachable·helper error / 3 미승인·미등록.
    private static func call(
        _ op: (ElectronicClamHelperProtocol, @escaping (Error?) -> Void) -> Void
    ) -> Int32 {
        // 1) Approval gate — without it, XPC connect would just stall.
        let service = SMAppService.daemon(plistName: HelperRegistration.plistName)
        switch service.status {
        case .enabled:
            break
        case .requiresApproval:
            CLIStderr.print("eclam: helper requires approval. Open System Settings > General > Login Items & Extensions and enable Electronic Clam.")
            return 3
        case .notFound:
            CLIStderr.print("eclam: helper not registered (.notFound). Launch ElectronicClam.app once to register the daemon.")
            return 3
        case .notRegistered:
            CLIStderr.print("eclam: helper not registered. Launch ElectronicClam.app once to register the daemon.")
            return 3
        @unknown default:
            CLIStderr.print("eclam: helper in an unknown registration state.")
            return 3
        }

        // 2) Synchronous XPC with a bounded wait.
        let conn = NSXPCConnection(machServiceName: HelperServiceName.mach, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: ElectronicClamHelperProtocol.self)
        conn.resume()
        defer { conn.invalidate() }

        let sem = DispatchSemaphore(value: 0)
        // Lock-guarded (shared LockedBox): both the reply and the error
        // handler land on XPC queues; after the 3s timeout this thread reads
        // while a late callback may still write. A plain `var` was a data race.
        let rpcError = LockedBox<Error?>(nil)

        let proxy = conn.remoteObjectProxyWithErrorHandler { err in
            rpcError.set(err)
            sem.signal()
        } as? ElectronicClamHelperProtocol

        guard let proxy = proxy else {
            CLIStderr.print("eclam: helper unreachable (no XPC proxy).")
            return 2
        }

        op(proxy) { err in
            rpcError.set(err)
            sem.signal()
        }

        // launchd cold-starts the daemon on the first connect, which can take
        // up to a couple of seconds on a freshly-booted machine; 3s is a safe
        // bound that still surfaces real hangs.
        if sem.wait(timeout: .now() + 3.0) == .timedOut {
            CLIStderr.print("eclam: helper unreachable (XPC timeout after 3s).")
            return 2
        }
        if let err = rpcError.get() {
            CLIStderr.print("eclam: helper error: \(err.localizedDescription)")
            return 2
        }
        return 0
    }

    static func set(_ enabled: Bool) -> Int32 {
        let rc = call { proxy, done in proxy.setSleepDisabled(enabled, reply: done) }
        if rc == 0 { print("eclam: \(enabled ? "on" : "off")") }
        return rc
    }

    /// ADR-0025 — TTL hold. `seconds < 0` ⇒ forever.
    static func hold(seconds: Double) -> Int32 {
        call { proxy, done in proxy.holdSleepDisabled(forSeconds: seconds, reply: done) }
    }

    /// ADR-0025 — `eclam off`: hold 활성 중의 off 쓰기는 helper 가 무시하므로
    /// cancelHold 를 먼저 보낸 뒤 off 를 쓴다 (연결 2회 — 단순함 우선).
    static func cancelHoldThenOff() -> Int32 {
        let rc = call { proxy, done in proxy.cancelHold(reply: done) }
        guard rc == 0 else { return rc }
        return set(false)
    }
}
