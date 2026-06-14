import Foundation
import OSLog

/// Accepts XPC connections from the GUI app AND from `eclam` CLI / `eclam-hook`
/// processes running as the same user. The original ADR-0002 §6 "one connection
/// only" rule rejected the CLI whenever the menubar app was running, breaking
/// `eclam on` / `off`, so we now accept all of them — multiple concurrent
/// connections (app + CLI + hook) are expected and normal.
///
/// SECURITY (ADR-0023): callers are validated by a code-signing requirement
/// (`setCodeSigningRequirement`), enabled now that ADR-0020 §③ (Developer ID +
/// notarization) gives a stable, cdhash-free Designated Requirement. The
/// requirement pins callers to our Team ID plus the app/CLI and hook code-sign
/// identifiers, so the published Mach service `com.jadhvank.eclam.helper` no
/// longer accepts an arbitrary same-user process — only our own signed app, the
/// `eclam` CLI (same Mach-O as the app), and `eclam-hook` may connect. The
/// system invalidates any connection whose peer fails the requirement.
///
/// The SMAppService approval gate is a *run* gate (may this daemon launch?),
/// not a *caller* gate (who may connect?); the requirement above is the caller
/// gate. Closing it removes the prior low-to-medium vector where a rogue
/// same-user process could flip `SleepDisabled` or spoof activity.
///
/// Ad-hoc dev builds compile with -DECLAM_DEV_ADHOC (build.sh, when
/// ECLAM_SIGN_ID=-) and SKIP this check: ad-hoc has no Team ID and a cdhash
/// that churns every build, so the requirement would reject the legitimate
/// CLI/hook — the exact reason ADR-0023 deferred this until a stable identity.
///
/// We still track the active set so we can log invalidations.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "xpc")
    private var active = Set<ObjectIdentifier>()
    private let lock = NSLock()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection new: NSXPCConnection) -> Bool {
        // hook 은 `pingActivity` 만 호출해야 한다 (최소권한, ADR-0023 §④ 방법 A).
        // 연결을 풀 인터페이스로 export 하되 전원/상태 변경 메서드는
        // `HelperService(isHook:)` 가 caller 별로 거부한다. dev-adhoc 빌드는
        // 안정적 코드사인 정체성이 없어 hook 식별이 불가하므로 isHook=false
        // (풀 인터페이스 허용) 로 graceful fallback — 가드가 dev CLI/hook 를
        // 깨면 안 된다.
        var isHook = false
        #if !ECLAM_DEV_ADHOC
        // Pin callers to our Developer ID team + the app/CLI and hook code-sign
        // identities; the system invalidates any peer that fails this (ADR-0023).
        new.setCodeSigningRequirement(
            "anchor apple generic "
            + "and certificate leaf[subject.OU] = \"GBQ3DN529X\" "
            + "and (identifier \"com.jadhvank.eclam\" or identifier \"com.jadhvank.eclam.hook\")")
        // system requirement 를 이미 통과할 connection 중 hook 만 좁혀 식별해
        // 전원/상태 가드 대상으로 표시한다 (audit token → SecCode →
        // hook-only requirement 평가, HelperCallerIdentity).
        isHook = HelperCallerIdentity.isHook(new)
        if isHook {
            log.info("xpc caller identified as hook — power/state methods will be denied")
        }
        #endif
        new.exportedInterface = NSXPCInterface(with: ElectronicClamHelperProtocol.self)
        new.exportedObject = HelperService(isHook: isHook)
        let id = ObjectIdentifier(new)
        new.invalidationHandler = { [weak self] in
            self?.lock.lock()
            self?.active.remove(id)
            let n = self?.active.count ?? 0
            self?.lock.unlock()
            self?.log.info("xpc connection invalidated (\(n, privacy: .public) remaining)")
        }
        new.interruptionHandler = { [weak self] in
            self?.log.warning("xpc connection interrupted")
        }
        lock.lock()
        active.insert(id)
        let count = active.count
        lock.unlock()
        new.resume()
        log.info("xpc connection accepted (\(count, privacy: .public) active)")
        return true
    }
}
