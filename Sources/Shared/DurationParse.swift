/// ADR-0025 — `eclam on --for <dur>` 의 기간 파서/포매터.
///
/// stdlib-only(no Foundation): `scripts/test.sh` 가 이 파일을 테스트와 함께
/// 단독 컴파일한다 (`Tests/DurationParseTests.swift`).
public enum DurationParse {
    /// "45"(분), "90m", "2h", "1h30m", "1h30"(관용적 — 단위 뒤 꼬리 숫자는 분)
    /// → 초. 대소문자 무관, 공백 허용. 유효하지 않거나 0 이하이면 nil.
    public static func seconds(from raw: String) -> Double? {
        var hours = 0
        var minutes = 0
        var digits = ""
        for ch in raw.lowercased() {
            if ch == " " { continue }
            if ch.isNumber {
                digits.append(ch)
                // 자릿수 폭주 가드 (Int overflow 방지)
                if digits.count > 6 { return nil }
                continue
            }
            guard !digits.isEmpty, let n = Int(digits) else { return nil }
            switch ch {
            case "h": hours += n
            case "m": minutes += n
            default:  return nil
            }
            digits = ""
        }
        if !digits.isEmpty {
            guard let n = Int(digits) else { return nil }
            minutes += n  // 단위 없는 숫자는 분
        }
        let total = hours * 3600 + minutes * 60
        return total > 0 ? Double(total) : nil
    }

    /// 1h 43m / 2h / 45m / 30s 형식의 짧은 표기.
    public static func shortFormat(seconds: Double) -> String {
        let total = Int(seconds < 0 ? 0 : seconds + 0.5)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }
}
