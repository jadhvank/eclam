// ADR-0037 S1 — EClamVirtualDisplay 구현. 비공개 CGVirtualDisplay 계열 SPI 로
// 보이지 않는 가상 디스플레이를 만들고(생성만 private), public CoreGraphics
// API 로 메인 디스플레이에 미러한다. 미러·재구성 콜백·디스플레이 ID 조회는 전부
// public(`CGConfigureDisplayMirrorOfDisplay`/`CGDisplayRegisterReconfiguration
// Callback`/`CGMainDisplayID`) 이다 — private 표면은 *디스플레이 생성*에 한정.
#import "VirtualDisplayShim.h"
#import <CoreGraphics/CoreGraphics.h>
#import <os/log.h>

// ── 비공개 SPI 선언 (CoreGraphics/SkyLight, public 헤더 없음) ──────────────────
// 아래 @interface 들은 @implementation 이 없다 — 컴파일러에 셀렉터 시그니처만
// 알려주는 용도다. 실제 객체는 NSClassFromString 으로 얻은 진짜 클래스에서
// alloc/init 하므로 링크타임 클래스 심볼 의존이 생기지 않는다. descriptor/
// settings 프로퍼티는 KVC(`setValue:forKey:`)로만 다루므로 @interface 가
// 필요 없다(NSObject 면 충분). 프로퍼티/셀렉터 이름은 2026-06-30 macOS 26/M5
// 에서 ObjC 런타임 introspection 으로 실측 확인했다.

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property (readonly) CGDirectDisplayID displayID;
@end

// ── 내부 헬퍼 선언 ───────────────────────────────────────────────────────────
@interface EClamVirtualDisplay ()
- (void)reapplyMirror;
@end

static os_log_t EClamVDLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.jadhvank.eclam", "vdisplay"); });
    return log;
}

const uint32_t EClamVirtualDisplayIdentity = 0x6543;

// ADR-0037 §미러링 — 순수 판정(헤더에 규칙 설명). CG 를 부르지 않으므로 테스트에서
// 값만 넣어 검증한다.
bool EClamDisplayIsRealExternal(bool isBuiltin,
                                bool isActive,
                                bool isInMirrorSet,
                                uint32_t vendor,
                                uint32_t model) {
    if (isBuiltin) return false;                      // 내장 패널
    if (vendor == EClamVirtualDisplayIdentity &&
        model  == EClamVirtualDisplayIdentity) {
        return false;                                 // 우리 앵커(또는 고아 앵커)
    }
    // active 만 보면 하드웨어 미러셋 슬레이브(= 미러로 붙인 TV/AirPlay)를 놓친다.
    return isActive || isInMirrorSet;
}

// 토폴로지 변경 시 미러를 재적용한다 — 덮개 열림 재구성에도 미러가 살아남게.
// reapplyMirror 자체가 멱등(이미 메인 미러면 skip, 메인이 가상 자신이면 skip)
// 이라 CGCompleteDisplayConfiguration 이 다시 부르는 이 콜백과 무한루프를 만들지
// 않는다.
static void EClamReconfigCallback(CGDirectDisplayID display,
                                  CGDisplayChangeSummaryFlags flags,
                                  void *userInfo) {
    // "변경 직전" 콜백(kCGDisplayBeginConfigurationFlag)에는 아무것도 하지 않는다.
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    if (userInfo == NULL) return;
    EClamVirtualDisplay *anchor = (__bridge EClamVirtualDisplay *)userInfo;
    [anchor reapplyMirror];
}

@implementation EClamVirtualDisplay {
    id _display;                 // 진짜 CGVirtualDisplay 인스턴스
    CGDirectDisplayID _displayID;
    dispatch_queue_t _queue;
    BOOL _active;
    BOOL _reconfigRegistered;
    BOOL _stopScheduled;         // 실물 외장 감지 → main queue teardown 예약 중복 방지
}

- (BOOL)active { return _active; }

/// 실물 외장 존재 판정의 **단일 구현**(Swift `SafetyMonitor`·`VirtualDisplayController`
/// 도 이걸 호출한다). `CGGetActiveDisplayList` 가 아니라 `CGGetOnlineDisplayList` 를
/// 쓰는 것이 요점 — 미러셋 슬레이브는 online 에는 남지만 active 에서는 빠진다.
/// 덮개 닫힌 헤드리스(내장 없음, 앵커만)에선 NO 라 앵커를 유지한다.
+ (BOOL)externalDisplayPresent {
    CGDirectDisplayID ids[32];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, ids, &count) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID d = ids[i];
        if (EClamDisplayIsRealExternal(CGDisplayIsBuiltin(d) != 0,
                                       CGDisplayIsActive(d) != 0,
                                       CGDisplayIsInMirrorSet(d) != 0,
                                       CGDisplayVendorNumber(d),
                                       CGDisplayModelNumber(d))) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)start {
    if (_active) return YES;
    _stopScheduled = NO;         // 새 라이프사이클 — 이전 teardown 예약 흔적 리셋

    // ADR-0037 §미러링 — 실물 외장(미러로 붙은 TV·AirPlay 포함)이 있으면 앵커는
    // 애초에 필요 없다(활성 디스플레이가 0이 안 됨). 정책 계층(VirtualDisplayController)
    // 이 이미 같은 판정으로 걸러 주지만, store 스냅샷과 실제 토폴로지 사이의 race
    // 를 막는 마지막 방어선으로 여기서도 본다.
    if ([EClamVirtualDisplay externalDisplayPresent]) {
        os_log(EClamVDLog(),
            "clamshell lock guard: external display present — not creating an anchor");
        return NO;
    }

    // 같은 절 — main 이 이미 미러셋에 들어가 있으면(우리가 만들지 않은 미러셋:
    // 사용자가 건 화면 미러링, 또는 회수 못 한 고아 앵커) 가상 디스플레이를 만들지
    // 않는다. 미러셋이 활성인 동안 만든 CGVirtualDisplay 는 프로세스가 살아있는
    // 내내 online 목록에 뜨지도 않다가, 프로세스가 죽은 *뒤에* 나타나 WindowServer
    // 가 회수하지 못하는 고아가 된다(2026-09-01 실측 — 로그아웃/재부팅으로만 소거).
    if (CGDisplayIsInMirrorSet(CGMainDisplayID())) {
        os_log(EClamVDLog(),
            "clamshell lock guard: main display is already in a mirror set — "
            "not creating an anchor (would orphan the virtual display)");
        return NO;
    }

    Class descCls     = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayCls  = NSClassFromString(@"CGVirtualDisplay");
    Class settingsCls = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeCls     = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descCls || !displayCls || !settingsCls || !modeCls) {
        os_log_error(EClamVDLog(),
            "CGVirtualDisplay SPI absent on this macOS; clamshell lock guard unavailable");
        return NO;
    }

    // ADR-0037 RC2(best-effort) — 이전 세션이 앵커를 회수하지 못한 채 죽었으면(#2)
    // 우리 고정 identity(vendor/product 0x6543)를 가진 stale 가상 디스플레이가 아직
    // 활성일 수 있다. 하지만 우리가 소유하지 않은 `CGVirtualDisplay` 는 free 할 수
    // 없고(release 만이 유일한 lever, 참조가 없다) `CGGetActiveDisplayList` 는 이름을
    // 주지 않으므로, 파괴는 시도하지 않고 경고만 남긴다. vendor/product 는 public
    // `CGDisplayVendorNumber`/`CGDisplayModelNumber` 로 읽는다.
    {
        CGDirectDisplayID ids[32];
        uint32_t count = 0;
        if (CGGetOnlineDisplayList(32, ids, &count) == kCGErrorSuccess) {
            for (uint32_t i = 0; i < count; i++) {
                if (CGDisplayVendorNumber(ids[i]) == EClamVirtualDisplayIdentity &&
                    CGDisplayModelNumber(ids[i])  == EClamVirtualDisplayIdentity) {
                    os_log(EClamVDLog(),
                        "stale eclam virtual display from a prior session detected "
                        "(id=%u); cannot reclaim a foreign display — avoid running two instances",
                        ids[i]);
                    break;
                }
            }
        }
    }

    @try {
        _queue = dispatch_queue_create("com.jadhvank.eclam.vdisplay", DISPATCH_QUEUE_SERIAL);

        // 1) Descriptor — KVC 로 설정(프로퍼티 이름 드리프트에 견고). 1920x1080,
        //    물리 크기는 ~81 DPI(비-retina)가 되도록 600x340mm.
        id descriptor = [[descCls alloc] init];
        [descriptor setValue:@"Electronic Clam Virtual Display" forKey:@"name"];
        [descriptor setValue:@1920 forKey:@"maxPixelsWide"];
        [descriptor setValue:@1080 forKey:@"maxPixelsHigh"];
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize(600, 340)]
                      forKey:@"sizeInMillimeters"];
        [descriptor setValue:@0      forKey:@"serialNum"];
        [descriptor setValue:@(EClamVirtualDisplayIdentity) forKey:@"productID"];
        [descriptor setValue:@(EClamVirtualDisplayIdentity) forKey:@"vendorID"];
        [descriptor setValue:_queue  forKey:@"queue"];
        // terminationHandler 는 옵셔널 — 타입 인코딩(@?)이 까다로워 별도 try 로
        // 격리한다. 실패해도 디스플레이 생성 자체는 막지 않는다.
        @try {
            void (^termination)(void) = ^{ /* OS 가 디스플레이 회수 시 호출 */ };
            [descriptor setValue:termination forKey:@"terminationHandler"];
        } @catch (NSException *e) {
            os_log(EClamVDLog(), "terminationHandler unset (optional): %{public}s",
                   e.reason.UTF8String ?: "");
        }

        // 2) 가상 디스플레이 생성. 헤드리스/WindowServer 부재 시 nil 가능.
        if (![displayCls instancesRespondToSelector:@selector(initWithDescriptor:)]) {
            os_log_error(EClamVDLog(), "CGVirtualDisplay -initWithDescriptor: missing");
            [self teardown];
            return NO;
        }
        CGVirtualDisplay *display = [[displayCls alloc] initWithDescriptor:descriptor];
        if (!display) {
            os_log_error(EClamVDLog(),
                "initWithDescriptor: returned nil (headless / no WindowServer session?)");
            [self teardown];
            return NO;
        }

        // 3) Mode + Settings — 1920x1080@60, hiDPI off.
        if (![modeCls instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]) {
            os_log_error(EClamVDLog(), "CGVirtualDisplayMode -initWithWidth:height:refreshRate: missing");
            [self teardown];
            return NO;
        }
        CGVirtualDisplayMode *mode = [[modeCls alloc] initWithWidth:1920 height:1080 refreshRate:60.0];
        id settings = [[settingsCls alloc] init];
        [settings setValue:@[mode] forKey:@"modes"];
        [settings setValue:@0       forKey:@"hiDPI"];

        if (![display respondsToSelector:@selector(applySettings:)]) {
            os_log_error(EClamVDLog(), "CGVirtualDisplay -applySettings: missing");
            [self teardown];
            return NO;
        }
        if (![display applySettings:settings]) {
            os_log_error(EClamVDLog(), "CGVirtualDisplay applySettings: returned NO");
            [self teardown];
            return NO;
        }

        CGDirectDisplayID vid = 0;
        if ([display respondsToSelector:@selector(displayID)]) vid = display.displayID;
        if (vid == 0) {
            os_log_error(EClamVDLog(), "virtual display has id 0; aborting mirror");
            [self teardown];
            return NO;
        }

        _display   = display;
        _displayID = vid;

        // 4) public CoreGraphics 미러 + 재구성 콜백 등록.
        [self reapplyMirror];
        CGDisplayRegisterReconfigurationCallback(EClamReconfigCallback, (__bridge void *)self);
        _reconfigRegistered = YES;
        _active = YES;
        os_log(EClamVDLog(), "clamshell lock guard: virtual display anchor active (id=%u)", vid);
        return YES;
    } @catch (NSException *ex) {
        // KVC 키 부재 등 인터페이스가 실측과 달라졌을 때 — 크래시 대신 NO.
        os_log_error(EClamVDLog(),
            "CGVirtualDisplay interface differs from expected (%{public}s); guard disabled",
            ex.reason.UTF8String ?: "?");
        [self teardown];
        return NO;
    }
}

- (void)stop {
    if (_reconfigRegistered) {
        CGDisplayRemoveReconfigurationCallback(EClamReconfigCallback, (__bridge void *)self);
        _reconfigRegistered = NO;
    }
    if (_displayID != 0) {
        CGDisplayConfigRef cfg;
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            CGConfigureDisplayMirrorOfDisplay(cfg, _displayID, kCGNullDirectDisplay);
            CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
        }
    }
    [self teardown];
    _active = NO;
    _stopScheduled = NO;         // 라이프사이클 종료 — 다음 start→외장연결 사이클 대비
}

/// 실물 외장이 붙으면 앵커를 즉시 비켜준다. 재구성 콜백 안에서 `stop()`(=CG 재구성)을
/// 동기로 부르면 콜백→unmirror→콜백 재진입 위험이 있어 main queue 로 태워 `AppDelegate`
/// 의 500ms converge 디바운스를 우회해 ~즉시 내린다. reconfig 이벤트가 몰려도 한 번만
/// 예약(`_stopScheduled` 가드) — `stop()` 이 콜백을 먼저 해제하므로 unmirror 재구성이
/// 콜백을 다시 부르지 않는다(무한루프 없음).
- (void)scheduleExternalTeardown {
    if (_stopScheduled) return;
    _stopScheduled = YES;
    os_log(EClamVDLog(),
        "clamshell lock guard: real external display attached — yielding anchor immediately (no re-mirror)");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stop];
    });
}

/// 미러 적용/재적용 — 멱등. 메인이 가상 자신이면(덮개 닫혀 내장이 빠진 단독
/// 상태) 미러하지 않고, 이미 메인을 미러 중이면 재구성 콜백 무한루프를 막으려
/// 조기 반환한다.
- (void)reapplyMirror {
    if (_displayID == 0) return;

    // ADR-0037 refinement — 실물 외장이 붙는 순간엔 **절대 재미러하지 않는다.**
    // 재미러(`CGConfigureDisplayMirrorOfDisplay`)는 새 main 기준으로 토폴로지를
    // 재구성하는데, 이게 macOS 가 저장해 둔 {내장, 외장} 정렬을 뭉갠다. 실물
    // 외장이 있으면 앵커는 애초에 필요 없으므로(활성 디스플레이 0 이 안 됨 → 잠금
    // 안 남) 싸우지 말고 즉시 비켜준다. 그러면 macOS 가 저장된 정렬을 스스로 복원.
    if ([EClamVirtualDisplay externalDisplayPresent]) {
        [self scheduleExternalTeardown];
        return;
    }

    CGDirectDisplayID main = CGMainDisplayID();
    if (main == _displayID) return;                          // 단독 활성(덮개 닫힘) — 미러 불가/불필요
    if (CGDisplayMirrorsDisplay(_displayID) == main) return; // 이미 미러 중 — 루프 차단

    // ADR-0037 §미러링 — main 이 미러셋에 들어가 있는데 그 미러가 *우리 것이 아니면*
    // (바로 위 검사에서 걸러졌다) 사용자가 건 화면 미러링이다. 재미러로 그 미러셋과
    // 싸우지 않는다 — 협상 중인 미러 세션을 깨뜨린다. 앵커는 미러 없이(확장으로)
    // 남지만 세션 앵커 역할(활성 디스플레이 ≥ 1)은 그대로이고, 위 외장 판정이
    // 곧 teardown 을 예약한다.
    if (CGDisplayIsInMirrorSet(main)) {
        os_log(EClamVDLog(),
            "clamshell lock guard: main is in a foreign mirror set — not re-mirroring");
        return;
    }

    CGDisplayConfigRef cfg;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return;
    CGConfigureDisplayMirrorOfDisplay(cfg, _displayID, main);
    CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
}

- (void)teardown {
    // 가상 디스플레이를 놓으면(레퍼런스 해제) OS 가 디스플레이를 회수한다. 단
    // 회수는 *즉시*가 아니라 descriptor 의 `queue`(= _queue) 위에 async 로 예약될
    // 뿐이다. 그래서 `_display = nil` 직후 `_queue = nil` 로 큐를 곧장 버리면 아직
    // 큐에 얹힌 destroy 작업이 orphan 되고, graceful 종료 경로는 WindowServer 가
    // 회수를 끝내기 전에 프로세스를 빠져나가 미러가 quit 후에도 살아남는다(#2).
    // 따라서 큐를 버리기 전에 `dispatch_sync` 배리어로 destroy 작업을 drain 한다.
    //
    // 데드락 안전성: `dispatch_sync(_queue, …)` 는 teardown 이 이미 `_queue` 위에서
    // 실행 중일 때만 데드락한다. teardown 호출 경로 전부(`stop`—main/임의 스레드,
    // `dealloc`, 그리고 `stop` 경유; 재구성 콜백은 CG 콜백 스레드에서 돌다
    // `scheduleExternalTeardown` 가 main queue 로 hop 한 뒤 `stop` 호출)를 추적한
    // 결과 `_queue` 위에 얹힌 블록 안에서 teardown/stop 을 부르는 경로는 없다.
    CGDirectDisplayID gone = _displayID;       // 로깅용 캡처
    _display = nil;                            // _queue 위에 async destroy 예약
    if (_queue) { dispatch_sync(_queue, ^{}); }// 배리어: destroy 작업이 drain 되게
    _displayID = 0;
    _queue = nil;
    os_log(EClamVDLog(), "clamshell lock guard: virtual display anchor torn down (id=%u)", gone);
}

- (void)dealloc {
    [self stop];
}

@end
