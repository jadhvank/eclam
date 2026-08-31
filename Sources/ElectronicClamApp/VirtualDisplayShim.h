// ADR-0037 S1 — 헤드리스 클램쉘 잠금 방지용 가상 디스플레이 "세션 앵커".
//
// 이 헤더는 Swift 가 보는 *깨끗한* 래퍼 인터페이스만 노출한다. 비공개
// CGVirtualDisplay 계열 SPI 선언과 그 인스턴스화는 전부 .m 내부에 격리되어
// 있고, 실제 클래스는 NSClassFromString 으로 런타임에 얻는다 — 링크타임 심볼
// 의존이 없으므로 클래스가 사라진 미래 macOS 에서도 크래시 대신 nil/NO 로
// graceful degrade 한다(불변규약 #6 · ADR-0037 §SPI). build.sh 가 이 헤더를
// `-import-objc-header` 로 앱 swiftc 에 넘긴다.
#import <Foundation/Foundation.h>
#import <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

/// 앵커가 자신을 식별하는 vendor/product ID. `CGDisplayVendorNumber`/
/// `CGDisplayModelNumber` 로 읽어 디스플레이 목록에서 *우리 자신* 과 (이전 세션이
/// 회수하지 못한) 고아 앵커를 걸러내는 데 쓴다.
extern const uint32_t EClamVirtualDisplayIdentity;

/// ADR-0037 §미러링 — "이 디스플레이는 실물 외장인가" 순수 판정. 라이브 CG 조회
/// 없이 스냅샷 값만 받으므로 단위 테스트가 가능하다(`Tests/DisplayTopologyTests.swift`).
///
/// 규칙: 내장 패널이 아니고, 우리 앵커 identity 도 아니며, **활성이거나 미러셋에
/// 들어가 있으면** 실물 외장이다. `isInMirrorSet` 를 함께 보는 것이 핵심 —
/// macOS 는 하드웨어 미러셋의 슬레이브를 `CGGetActiveDisplayList` 에서 빼버려
/// (2026-09-01 실측: 미러 전 active=2 → 미러 후 active=1, online=2), active 만
/// 보면 **미러로 붙인 TV·AirPlay 디스플레이가 통째로 안 보인다.**
bool EClamDisplayIsRealExternal(bool isBuiltin,
                                bool isActive,
                                bool isInMirrorSet,
                                uint32_t vendor,
                                uint32_t model);

/// 보이지 않는 가상 디스플레이를 만들어 메인 디스플레이에 미러로 묶는다.
/// 헤드리스 클램쉘(덮개 닫힘 + 외장 없음)에서 활성 디스플레이가 0개가 되어
/// 발생하는 화면 잠금을 막아 VPN 세션을 유지한다. 백라이트 0 → 전력·발열 ~0.
/// 소유·라이프사이클은 Swift 쪽 `VirtualDisplayController` 가 관리한다.
@interface EClamVirtualDisplay : NSObject

/// 지금 **실물 외장 디스플레이**(미러셋 슬레이브로 붙은 TV·AirPlay 포함)가 하나라도
/// 있는가. `CGGetOnlineDisplayList` 를 순회하며 `EClamDisplayIsRealExternal` 을
/// 적용한다 — 앱 전체에서 이 판정의 **단일 구현**이며, Swift 쪽 `SafetyMonitor`
/// 도 이걸 호출한다(이전에는 `NSScreen.screens.count > 1` 로 따로 판정해 미러링을
/// 못 보고 서로 엇갈렸다).
+ (BOOL)externalDisplayPresent;

/// 가상 디스플레이를 생성하고 메인 디스플레이로 미러한다. 성공 시 YES.
/// SPI 부재·헤드리스 세션(WindowServer 없음)·인터페이스 변경 등 어떤 실패에도
/// 크래시 없이 NO 를 반환한다. 멱등(이미 active 면 YES).
///
/// 실물 외장이 붙어 있거나 main 이 이미 미러셋에 들어가 있으면 **만들지 않고 NO**
/// 를 반환한다(ADR-0037 §미러링) — 미러셋이 활성인 동안 만든 가상 디스플레이는
/// 프로세스가 죽어도 WindowServer 가 회수하지 못하는 고아가 된다(2026-09-01 실측).
- (BOOL)start;

/// 미러를 해제하고 가상 디스플레이를 놓는다(프로세스 종속이라 OS 가 회수).
/// 멱등(이미 비활성이면 no-op).
- (void)stop;

/// 현재 앵커가 살아있는지.
@property (readonly) BOOL active;

@end

NS_ASSUME_NONNULL_END
