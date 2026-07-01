import CoreGraphics
import Foundation
import OSLog

/// ADR-0037 S2 — 내장 디스플레이 밝기 제어 (DisplayServices private framework).
///
/// `pmset displaysleepnow`("재우기")는 즉시-잠금 Mac에서 화면을 *잠가* FortiClient
/// 같은 VPN을 끊는다. #8 "어둡게(dim)" 모드는 잠그는 대신 내장 패널 밝기를 바닥까지
/// 내리고 `PreventUserIdleDisplaySleep` assertion 으로 화면을 *깨어있되 깜깜*하게
/// 유지한다 — 잠금 이벤트가 없어 VPN이 살아남는다(ADR-0037 §#8 공존).
///
/// 메커니즘: `/System/.../DisplayServices.framework` 를 dlopen 하고
/// `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness` 를 dlsym 한다.
/// private framework 라 미래 macOS 에서 사라질 수 있으므로 심볼이 없으면 조용히
/// no-op (불변규약 #6: 새 SPI 도입 근거는 ADR — 본 ADR-0037 가 그 근거). dlopen 이라
/// 링크가 없어 `build.sh` 변경도 불필요하다.
///
/// **내장 디스플레이 전용.** 외장은 DisplayServices 비대상(DDC best-effort)이라 S2
/// 범위 밖이고, dim 모드에서 외장은 밝기 대신 no-sleep assertion 에만 의존한다
/// (어두워지진 않아도 안 잠김).
enum DisplayBrightness {
    private static let log = Logger(subsystem: "com.jadhvank.eclam", category: "brightness")

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// dlopen 핸들 + 심볼은 1회 resolve 해 캐시. 실패하면 (nil, nil) 로 고정돼
    /// 이후 호출이 전부 no-op 가 된다. 핸들은 프로세스 수명 동안 유지(dlclose 안 함)
    /// — 심볼 포인터를 계속 쓴다.
    private static let symbols: (get: GetFn?, set: SetFn?) = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW) else {
            log.error("DisplayServices dlopen failed — dim brightness unavailable (no-op)")
            return (nil, nil)
        }
        let get = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        let set = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
        if get == nil || set == nil {
            log.error("DisplayServices symbols missing — dim brightness unavailable (no-op)")
        }
        return (get, set)
    }()

    /// 밝기 제어 가능 여부(두 심볼 모두 resolve 됐을 때만).
    static var isAvailable: Bool { symbols.get != nil && symbols.set != nil }

    /// 내장 디스플레이 밝기 읽기 (0.0…1.0). 실패 시 nil.
    static func get(_ display: CGDirectDisplayID) -> Float? {
        guard let fn = symbols.get else { return nil }
        var value: Float = 0
        let err = fn(display, &value)
        guard err == 0 else {
            log.error("DisplayServicesGetBrightness err=\(err, privacy: .public)")
            return nil
        }
        return value
    }

    /// 내장 디스플레이 밝기 쓰기 (0.0…1.0 으로 clamp). 성공 시 true.
    @discardableResult
    static func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let fn = symbols.set else { return false }
        let err = fn(display, max(0, min(1, value)))
        if err != 0 {
            log.error("DisplayServicesSetBrightness err=\(err, privacy: .public)")
        }
        return err == 0
    }

    /// 활성 디스플레이 중 내장 패널의 `CGDirectDisplayID`. 없으면 nil
    /// (헤드리스 클램쉘처럼 내장이 빠진 경우 — 그땐 가상 디스플레이가 잠금을 막는다).
    /// 판별은 public `CGDisplayIsBuiltin`(SafetyMonitor 와 동일 기준).
    static func builtinDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}
