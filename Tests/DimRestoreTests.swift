/// DimRestoreTests.swift — dim 밝기 *복원* 결정 로직 검증 (ADR-0037 S2, bug #4).
///
/// 검증 대상(순수-ish 하게 주입 가능한 부분만):
///   1) 복원은 dim-진입 때 캡처한 id 가 아니라, 복원 시점에 재-resolve 한 built-in id 를
///      타깃으로 쓴다(RC2). 클램쉘 재개폐로 id 가 바뀌어도 stale id 로 쓰지 않는다.
///   2) 백엔드가 write 실패(false)를 보고하면 bounded 재시도하고, 성공하면 멈춘다.
///   3) 재해석 결과가 잠깐 nil 이어도(패널 미복귀) 재시도로 흡수하고, 그 사이 id 가
///      나타나면 그 id 로 복원한다.
///   4) 헤드리스 진입(저장 밝기 없음) 시 밝기를 지어내 쓰지 않는다(RC3).
///
/// 실행 (scripts/test.sh): DisplayBrightness.swift + BlankDisplayDimmer.swift 와 함께
/// 단독 컴파일. BlankDisplayDimmer 는 AppKit/IOKit 를 쓰므로 -framework AppKit -framework
/// IOKit 링크가 필요하지만, 헤드리스로 문제없이 동작한다(NSWorkspace 옵저버·assertion·
/// beginActivity 는 GUI 불필요). 재시도는 DispatchQueue.main.asyncAfter 라 run loop 를
/// 잠깐 돌려 소진시킨다.

import CoreGraphics
import Foundation

var passCount = 0
var failCount = 0

func assert(_ cond: Bool, _ msg: String) {
    if cond {
        print("  ✓ \(msg)")
        passCount += 1
    } else {
        print("  ✗ FAIL: \(msg)")
        failCount += 1
    }
}

/// 주입용 가짜 밝기 백엔드 — built-in id 를 테스트가 갈아끼우고(재구성 시뮬레이션),
/// set 호출을 기록하며, 지정 횟수만큼 write 를 실패시켜 재시도 경로를 검증한다.
final class FakeBrightnessBackend: BrightnessBackend {
    /// 현재 resolve 되는 built-in id. nil = 내장 미복귀. 테스트가 자유롭게 바꾼다.
    var currentID: CGDirectDisplayID?
    /// 미리 심어둔 밝기(get 결과).
    var storedBrightness: Float?
    /// 앞으로 남은 강제 실패 횟수(set 이 호출될 때마다 하나씩 소진하며 false 반환).
    var failuresRemaining: Int = 0
    /// builtinID() 가 nil 을 반환할 남은 횟수(그 뒤엔 currentID 를 반환).
    var nilIDRemaining: Int = 0
    /// 이 id 로의 set 은 항상 실패시킨다(특정 대상만 거부하는 상황 시뮬레이션). nil = 없음.
    var failOn: CGDirectDisplayID?

    /// 기록: (display, value) set 호출 순서대로.
    private(set) var setCalls: [(display: CGDirectDisplayID, value: Float)] = []
    /// 기록: builtinID() 호출 횟수.
    private(set) var builtinIDCalls = 0

    init(currentID: CGDirectDisplayID?, storedBrightness: Float?) {
        self.currentID = currentID
        self.storedBrightness = storedBrightness
    }

    func builtinID() -> CGDirectDisplayID? {
        builtinIDCalls += 1
        if nilIDRemaining > 0 {
            nilIDRemaining -= 1
            return nil
        }
        return currentID
    }

    func get(_ display: CGDirectDisplayID) -> Float? { storedBrightness }

    @discardableResult
    func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        setCalls.append((display, value))
        if display == failOn { return false }        // 지정 대상은 항상 거부.
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            return false
        }
        return true
    }
}

/// 재시도(asyncAfter)가 소진될 때까지 main run loop 를 잠깐 돌린다.
func drainMainQueue(seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@main
enum DimRestoreTestMain {
    // dim-진입 때의 id 와 복원 때의 id.
    static let dimID: CGDirectDisplayID = 1
    static let newID: CGDirectDisplayID = 42

    static func main() {
        print("── RC2: 복원은 캡처한 id 가 아니라 재-resolve 한 built-in 을 타깃으로 쓴다")
        do {
            let fake = FakeBrightnessBackend(currentID: dimID, storedBrightness: 0.8)
            let dimmer = BlankDisplayDimmer(backend: fake)
            dimmer.dim()   // 진입 시 dimID(=1) 로 floor(0.0) write.
            assert(fake.setCalls.last?.display == dimID, "dim 진입 write 는 캡처 id(1)")
            assert(fake.setCalls.last?.value == 0.0, "dim 진입은 floor 0.0")

            // 클램쉘 재개폐 시뮬레이션: 내장 id 가 42 로 재-enumeration 됨.
            fake.currentID = newID
            let setsBefore = fake.setCalls.count
            dimmer.restore()
            drainMainQueue(seconds: 0.1)

            let restoreSets = Array(fake.setCalls.dropFirst(setsBefore))
            assert(restoreSets.contains { $0.display == newID && $0.value == 0.8 },
                   "복원 write 는 재-resolve 한 id(42) + 저장 밝기(0.8)")
            assert(!restoreSets.contains { $0.display == dimID },
                   "복원 write 가 stale 캡처 id(1) 로 가지 않는다")
        }

        print("── RC2: write 실패 시 bounded 재시도, 성공하면 멈춘다")
        do {
            let fake = FakeBrightnessBackend(currentID: newID, storedBrightness: 0.5)
            let dimmer = BlankDisplayDimmer(backend: fake)
            dimmer.dim()
            let setsBefore = fake.setCalls.count
            // 복원 write 를 2번 실패시키고 3번째에 성공하게 한다.
            fake.failuresRemaining = 2
            dimmer.restore()
            drainMainQueue(seconds: 1.0)   // 재시도 간격 0.2s × 몇 회 소진.

            let restoreSets = Array(fake.setCalls.dropFirst(setsBefore))
            assert(restoreSets.count == 3, "실패2 + 성공1 = 정확히 3회 write 시도 (got \(restoreSets.count))")
            assert(restoreSets.allSatisfy { $0.display == newID && $0.value == 0.5 },
                   "모든 재시도가 재-resolve 한 id(42) + 저장 밝기(0.5)")
        }

        print("── RC2: 재시도는 매 시도마다 재-resolve 한다 (도중에 나타난 id 로 복원)")
        do {
            // dim 진입 시 dimID 로 잡되(폴백=dimID, 저장=0.6), 복원 순간 built-in 이
            // nil→nil→newID 로 나타나게 한다. 폴백 dimID 로의 write 는 전부 실패시키고
            // newID 로의 write 만 성공하면 "매 시도 재-resolve + 새 id 로 성공"이 증명된다.
            let fake = FakeBrightnessBackend(currentID: dimID, storedBrightness: 0.6)
            let dimmer = BlankDisplayDimmer(backend: fake)
            dimmer.dim()                    // 캡처 id = dimID, 저장 = 0.6.
            let setsBefore = fake.setCalls.count
            fake.nilIDRemaining = 2         // 처음 두 시도는 built-in nil → 폴백 dimID 사용.
            fake.currentID = newID          // nil 소진 뒤에는 newID 로 재-resolve.
            fake.failOn = dimID             // 폴백 dimID(=1) write 는 실패, newID(=42) 만 성공.
            dimmer.restore()
            drainMainQueue(seconds: 1.2)

            let restoreSets = Array(fake.setCalls.dropFirst(setsBefore))
            assert(restoreSets.contains { $0.display == dimID },
                   "nil 창 동안엔 폴백 캡처 id(1) 로 시도했다(그리고 실패)")
            assert(restoreSets.last?.display == newID && restoreSets.last?.value == 0.6,
                   "재-resolve 로 나타난 id(42) 로 최종 성공 복원")
        }

        print("── RC3: 헤드리스 진입(저장 밝기 없음) — 밝기를 지어내 쓰지 않는다")
        do {
            // 진입 시 내장 없음(nil) → savedBrightness/dimmedDisplay 모두 nil.
            let fake = FakeBrightnessBackend(currentID: nil, storedBrightness: nil)
            let dimmer = BlankDisplayDimmer(backend: fake)
            dimmer.dim()
            let setsBefore = fake.setCalls.count
            // 복원 시점엔 내장이 돌아왔지만(42) 되돌릴 기준값이 없다.
            fake.currentID = newID
            dimmer.restore()
            drainMainQueue(seconds: 0.3)

            let restoreSets = Array(fake.setCalls.dropFirst(setsBefore))
            assert(restoreSets.isEmpty, "저장 밝기 없으면 어떤 밝기도 write 하지 않는다 (got \(restoreSets.count))")
        }

        print("── 멱등: restore() 를 두 번 불러도 재시도 루프가 중첩되지 않는다")
        do {
            let fake = FakeBrightnessBackend(currentID: newID, storedBrightness: 0.7)
            let dimmer = BlankDisplayDimmer(backend: fake)
            dimmer.dim()
            let setsBefore = fake.setCalls.count
            fake.failuresRemaining = 1   // 1번 실패 후 성공 예정.
            dimmer.restore()
            dimmer.restore()   // 두 번째는 isDimmed=false 라 즉시 no-op 이어야 함.
            drainMainQueue(seconds: 1.0)

            let restoreSets = Array(fake.setCalls.dropFirst(setsBefore))
            // 단일 루프였다면 실패1+성공1 = 2회. 루프가 중첩됐다면 더 많이 찍힌다.
            assert(restoreSets.count == 2, "복원 write 는 단일 루프로 2회만 (got \(restoreSets.count))")
        }

        print("")
        print("DimRestore tests: \(passCount) passed, \(failCount) failed")
        exit(failCount == 0 ? 0 : 1)
    }
}
