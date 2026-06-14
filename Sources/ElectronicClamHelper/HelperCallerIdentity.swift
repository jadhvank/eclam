import Foundation
import Security

/// Per-connection caller identity for the XPC listener (ADR-0023 §④, Method A —
/// 2026-06-15 메서드 가드).
///
/// `HelperListenerDelegate.setCodeSigningRequirement` 가 이미 connection 을
/// 우리 Team ID + (앱/CLI `com.jadhvank.eclam` 또는 hook `com.jadhvank.eclam.hook`)
/// 로 핀해 둔다. 그러나 그 system 게이트는 "통과/거부" 만 하지 *어느* identifier
/// 인지는 알려주지 않는다. 최소권한(앱·CLI 만 전원/상태 변경 가능, hook 은
/// `pingActivity` 만)을 위해 여기서 connection 의 audit token 으로 SecCode 를
/// 만들어 hook-only 코드사인 requirement 를 직접 평가한다 —
/// `setCodeSigningRequirement` 가 내부적으로 하는 일을 분기용으로 직접 한 번 더.
///
/// 인터페이스 분리(방법 B)는 하지 않는다: 프로토콜은 그대로, 가드만 추가한다.
enum HelperCallerIdentity {
    /// hook 바이너리의 코드사인 identifier. build.sh `codesign --identifier
    /// com.jadhvank.eclam.hook` 와 일치해야 한다.
    static let hookIdentifier = "com.jadhvank.eclam.hook"

    /// Developer ID Team ID (ADR-0020 §③). build.sh 의 SIGN_ID OU 와 일치.
    static let teamID = "GBQ3DN529X"

    /// hook *만* 매칭하는 코드사인 requirement 문자열.
    ///
    /// listener 의 풀 requirement 와 같은 anchor/Team 절을 쓰되 identifier 를
    /// hook 하나로 좁힌다. listener 의 requirement 를 이미 통과한 connection 에
    /// 대해 이 식이 valid 면 caller 는 hook, 아니면 앱/CLI 다. (앱/CLI 와 hook
    /// 은 서로소 identifier 라 양립 불가.)
    ///
    /// 순수 함수 — Security 호출 없이 테스트 가능(`Tests/HelperCallerIdentityTests.swift`).
    static func hookRequirementString(identifier: String = hookIdentifier,
                                      teamID: String = teamID) -> String {
        return "anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(teamID)\" "
            + "and identifier \"\(identifier)\""
    }

    /// connection 이 hook 이면 `true`. 판정 불가(audit token 없음 / SecCode 생성
    /// 실패 / requirement 컴파일 실패)면 **`false`(앱/CLI 취급, 풀 인터페이스)**
    /// 로 graceful fallback 한다 — 가드의 목적은 hook 을 *적극* 식별해 power 호출을
    /// 막는 것이므로, 식별이 모호하면 listener 의 system requirement 가 이미
    /// 보증한 신뢰 경계(우리 Team 의 앱/CLI/hook) 안에서 보수적으로 통과시킨다.
    /// (hook 이 power 를 호출하지 못하게 막는 것이 목표지, 앱/CLI 를 막는 게 아님.)
    static func isHook(_ connection: NSXPCConnection) -> Bool {
        guard let token = connection.eclamAuditToken else { return false }
        return matchesHookRequirement(auditToken: token)
    }

    /// audit token 으로 SecCode 를 만들어 hook-only requirement 로
    /// `SecCodeCheckValidity` 한다. true ⇔ 이 토큰의 코드가 hook.
    static func matchesHookRequirement(auditToken: audit_token_t) -> Bool {
        // audit_token_t → CFData (그대로 8×uint32 바이트).
        var token = auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) } as CFData

        let attrs: [CFString: Any] = [kSecGuestAttributeAudit: tokenData]
        var code: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(
            nil, attrs as CFDictionary, [], &code)
        guard copyStatus == errSecSuccess, let guestCode = code else {
            return false
        }

        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(
            hookRequirementString() as CFString, [], &requirement)
        guard reqStatus == errSecSuccess, let hookReq = requirement else {
            return false
        }

        let validity = SecCodeCheckValidity(guestCode, [], hookReq)
        return validity == errSecSuccess
    }
}

/// `NSXPCConnection.auditToken` 은 헤더에 없는 SPI 지만 런타임에 존재하는
/// `audit_token_t` 프로퍼티다(caller 식별의 정석 경로 — TN3127 / Quinn DTS).
/// 별도 `@objc` 선언으로 같은 selector 를 *재정의*하면 실제 SPI getter 와
/// 충돌하므로, ObjC KVC(`value(forKey:)`)로 기존 getter 를 그대로 호출해
/// `NSValue` 박싱을 거쳐 읽는다. SPI 부재 시(미래 OS 변경 등) nil 로 떨어진다.
extension NSXPCConnection {
    /// connection peer 의 audit token. SPI 부재 시 nil.
    var eclamAuditToken: audit_token_t? {
        let sel = NSSelectorFromString("auditToken")
        guard responds(to: sel) else { return nil }
        // `auditToken` 은 struct 반환이라 KVC `value(forKey:)` 로 NSValue 박싱을
        // 거쳐 읽는다. Foundation 이 audit_token_t 를 NSValue 로 박싱한다.
        guard let boxed = value(forKey: "auditToken") else { return nil }
        guard let nsValue = boxed as? NSValue else { return nil }
        // 박싱된 struct 가 audit_token_t(= 8×uint32, ObjC enc "{?=[8I]}") 와
        // 같은 레이아웃일 때만 복사. mismatch 면 nil (방어). `getValue(_:size:)`
        // 는 size mismatch 시 예외를 던지므로, ObjC 인코딩의 실제 크기를
        // `NSGetSizeAndAlignment` 로 구해 destination 과 대조한 뒤에만 읽는다.
        var encodedSize = 0
        NSGetSizeAndAlignment(nsValue.objCType, &encodedSize, nil)
        guard encodedSize == MemoryLayout<audit_token_t>.size else { return nil }
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) { raw in
            if let base = raw.baseAddress {
                nsValue.getValue(base, size: encodedSize)
            }
        }
        return token
    }
}
