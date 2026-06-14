import Foundation

/// ADR-0025 — CLI hold 영속 파일(`cli-hold`)의 직렬화/역직렬화 순수 계층.
///
/// `HoldManager`(helper)가 디스크에 쓰고 시작 시 다시 읽는 포맷을 한 곳에 모은다.
/// 파일 I/O·IOKit·타이머에서 분리된 stdlib-only 라 swiftc 단독 컴파일·테스트가
/// 가능하다(scripts/test.sh). 포맷은 단일 토큰:
///   - `"forever"`              ⇒ 만료 없는 hold
///   - `<unix epoch double>`    ⇒ 해당 시각에 만료
///
/// P3① — `serialize` 는 force-unwrap 없이 forever/finite 를 분기한다. finite 인데
/// 만료 시각이 없는(논리상 도달 불가) 경우에도 크래시 대신 `nil` 폴백으로 안전하게
/// 처리해, 리팩터·오용 시에도 지뢰가 되지 않는다.
enum HoldState: Equatable {
    /// 만료 없는 hold (`eclam on --forever`).
    case forever
    /// 주어진 unix epoch(초)에 만료되는 유한 hold.
    case until(epoch: Double)

    /// 영속 파일에 쓸 단일 토큰 문자열.
    var serialized: String {
        switch self {
        case .forever:
            return "forever"
        case .until(let epoch):
            return String(epoch)
        }
    }

    /// 파일 내용 → `HoldState`. 알 수 없는/빈 토큰은 `nil`.
    /// 호출자(restoreAtLaunch)가 남은 시간 계산·만료 정리를 담당한다.
    static func parse(_ raw: String) -> HoldState? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "forever" { return .forever }
        if let epoch = Double(trimmed) { return .until(epoch: epoch) }
        return nil
    }

    /// 현재 상태(forever 플래그 + 선택적 만료 시각)를 영속 토큰으로 직렬화한다.
    /// P3① — `holdUntil` 을 force-unwrap 하지 않는다. forever 가 아니면서 만료
    /// 시각이 없는 경우(arm() 의 불변식상 도달 불가)에는 `now` 로 폴백한다.
    static func serialize(forever: Bool, holdUntil: Date?, now: Date = Date()) -> String {
        if forever { return HoldState.forever.serialized }
        let epoch = (holdUntil ?? now).timeIntervalSince1970
        return HoldState.until(epoch: epoch).serialized
    }
}
