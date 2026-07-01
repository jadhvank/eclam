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

- (BOOL)start {
    if (_active) return YES;
    _stopScheduled = NO;         // 새 라이프사이클 — 이전 teardown 예약 흔적 리셋

    Class descCls     = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayCls  = NSClassFromString(@"CGVirtualDisplay");
    Class settingsCls = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeCls     = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descCls || !displayCls || !settingsCls || !modeCls) {
        os_log_error(EClamVDLog(),
            "CGVirtualDisplay SPI absent on this macOS; clamshell lock guard unavailable");
        return NO;
    }

    @try {
        _queue = dispatch_queue_create("com.jadhvank.eclam.vdisplay", DISPATCH_QUEUE_SERIAL);

        // 1) Descriptor — KVC 로 설정(프로퍼티 이름 드리프트에 견고). 1920x1080,
        //    물리 크기는 ~81 DPI(비-retina)가 되도록 600x340mm.
        id descriptor = [[descCls alloc] init];
        [descriptor setValue:@"Electronic Clam Anchor" forKey:@"name"];
        [descriptor setValue:@1920 forKey:@"maxPixelsWide"];
        [descriptor setValue:@1080 forKey:@"maxPixelsHigh"];
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize(600, 340)]
                      forKey:@"sizeInMillimeters"];
        [descriptor setValue:@0      forKey:@"serialNum"];
        [descriptor setValue:@0x6543 forKey:@"productID"];
        [descriptor setValue:@0x6543 forKey:@"vendorID"];
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

/// 활성 디스플레이 목록에 우리 가상(`_displayID`)도, 내장 패널(built-in)도 아닌
/// **실물 외장** 디스플레이가 하나라도 있으면 YES. 재미러 억제·즉시 teardown 판단용.
/// 덮개 닫힌 헤드리스(내장 없음, 가상만 활성)에선 NO — 앵커를 유지한다.
- (BOOL)realExternalDisplayPresent {
    if (_displayID == 0) return NO;
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID d = ids[i];
        if (d == _displayID) continue;       // 우리 가상 앵커
        if (CGDisplayIsBuiltin(d)) continue; // 내장 패널
        return YES;                          // 그 외 활성 = 실물 외장
    }
    return NO;
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
    if ([self realExternalDisplayPresent]) {
        [self scheduleExternalTeardown];
        return;
    }

    CGDirectDisplayID main = CGMainDisplayID();
    if (main == _displayID) return;                          // 단독 활성(덮개 닫힘) — 미러 불가/불필요
    if (CGDisplayMirrorsDisplay(_displayID) == main) return; // 이미 미러 중 — 루프 차단
    CGDisplayConfigRef cfg;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return;
    CGConfigureDisplayMirrorOfDisplay(cfg, _displayID, main);
    CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
}

- (void)teardown {
    // 가상 디스플레이를 놓으면(레퍼런스 해제) OS 가 디스플레이를 회수한다.
    _display = nil;
    _displayID = 0;
    _queue = nil;
}

- (void)dealloc {
    [self stop];
}

@end
