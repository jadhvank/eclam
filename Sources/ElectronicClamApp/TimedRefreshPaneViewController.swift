import AppKit

/// Settings 패널 공통 refresh 타이머 수명주기 (TODO P2 — Safety/History 가
/// 같은 타이머 보일러플레이트를 복붙하고 있었다).
///
/// 서브클래스는 `refreshTick()`(반복)과 필요 시 `refreshOnAppear()`(표시 직전
/// 1회 — 기본은 refreshTick 위임)만 구현한다. 타이머는 뷰가 윈도우에 보이는
/// 동안만 돈다 (NSTabView 탭 전환이 viewWillAppear/Disappear 를 발화시키므로
/// 비활성 탭은 비용 0 — 툴팁 hover 를 끊지 않도록 뷰를 재생성하지 않는 것도
/// 이 베이스의 계약).
class TimedRefreshPaneViewController: NSViewController {
    private var refreshTimer: Timer?

    /// 반복 주기. 기본 1초.
    var refreshInterval: TimeInterval { 1.0 }

    /// 타이머 틱마다 호출 — 서브클래스가 구현.
    func refreshTick() {}

    /// 표시 직전 1회. 기본은 `refreshTick()` — 전체 재구성용 별도 refresh 가
    /// 있는 패널(Safety)은 override.
    func refreshOnAppear() { refreshTick() }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshOnAppear()
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshTick()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
