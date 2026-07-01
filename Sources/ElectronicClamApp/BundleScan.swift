import Foundation

/// ADR-0039 — split-brain(중복본·버전 스큐) 탐지의 데이터 소스 ①.
///
/// 같은 bundle id 의 `.app` 복사본을 Spotlight(`mdfind`) 로 열거한다. 사건의
/// 사용자는 `/Applications`(0.5.0)·`~/Downloads`(0.6.1) 등 3벌을 깔아두고도 어느
/// 도구로도 이를 볼 수 없었다 — `copies()` 가 2벌 이상이면 status/repair 가
/// split-brain 경고를 낸다.
///
/// 읽기 전용·단일 프로세스. Spotlight 비활성/무결과면 `[]` 로 graceful
/// (고정 경로 스캔 대신 mdfind 를 쓰는 이유는 ADR-0039 "대안" 표 참고).
enum BundleScan {
    static let bundleID = "com.jadhvank.eclam"

    struct Copy: Equatable {
        let path: String
        let shortVersion: String?   // 각 복사본 Info.plist 의 CFBundleShortVersionString
        let inApplications: Bool     // InstallLocation.isInApplications(path)
    }

    /// `mdfind "kMDItemCFBundleIdentifier == 'com.jadhvank.eclam'"` 의 각 결과를
    /// `Copy` 한 개로 변환. Spotlight 비활성/무결과면 `[]`.
    /// 단일 프로세스라 5s 타임아웃으로 캡한다(`Subprocess.capture(timeoutSeconds:)`).
    static func copies() -> [Copy] {
        guard let out = Subprocess.capture(
            "/usr/bin/mdfind",
            ["kMDItemCFBundleIdentifier == '\(bundleID)'"],
            timeoutSeconds: 5),
            !out.isEmpty
        else { return [] }

        return out
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { path in
                let plistPath = path + "/Contents/Info.plist"
                let info = NSDictionary(contentsOfFile: plistPath)
                let version = info?["CFBundleShortVersionString"] as? String
                return Copy(path: path,
                            shortVersion: version,
                            inApplications: InstallLocation.isInApplications(path))
            }
    }
}
