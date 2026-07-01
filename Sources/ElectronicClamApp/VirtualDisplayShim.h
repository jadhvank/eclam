// ADR-0037 S1 — 헤드리스 클램쉘 잠금 방지용 가상 디스플레이 "세션 앵커".
//
// 이 헤더는 Swift 가 보는 *깨끗한* 래퍼 인터페이스만 노출한다. 비공개
// CGVirtualDisplay 계열 SPI 선언과 그 인스턴스화는 전부 .m 내부에 격리되어
// 있고, 실제 클래스는 NSClassFromString 으로 런타임에 얻는다 — 링크타임 심볼
// 의존이 없으므로 클래스가 사라진 미래 macOS 에서도 크래시 대신 nil/NO 로
// graceful degrade 한다(불변규약 #6 · ADR-0037 §SPI). build.sh 가 이 헤더를
// `-import-objc-header` 로 앱 swiftc 에 넘긴다.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 보이지 않는 가상 디스플레이를 만들어 메인 디스플레이에 미러로 묶는다.
/// 헤드리스 클램쉘(덮개 닫힘 + 외장 없음)에서 활성 디스플레이가 0개가 되어
/// 발생하는 화면 잠금을 막아 VPN 세션을 유지한다. 백라이트 0 → 전력·발열 ~0.
/// 소유·라이프사이클은 Swift 쪽 `VirtualDisplayController` 가 관리한다.
@interface EClamVirtualDisplay : NSObject

/// 가상 디스플레이를 생성하고 메인 디스플레이로 미러한다. 성공 시 YES.
/// SPI 부재·헤드리스 세션(WindowServer 없음)·인터페이스 변경 등 어떤 실패에도
/// 크래시 없이 NO 를 반환한다. 멱등(이미 active 면 YES).
- (BOOL)start;

/// 미러를 해제하고 가상 디스플레이를 놓는다(프로세스 종속이라 OS 가 회수).
/// 멱등(이미 비활성이면 no-op).
- (void)stop;

/// 현재 앵커가 살아있는지.
@property (readonly) BOOL active;

@end

NS_ASSUME_NONNULL_END
