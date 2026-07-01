<div align="center">

<img src="docs/assets/eclam-icon.png" width="120" alt="Electronic Clam" />

# Electronic Clam

**Agents must keep working — your Mac shouldn't cook trying.**
에이전트는 쉬지 않게, Mac은 타지 않게.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Language](https://img.shields.io/badge/Swift-AppKit%20%2B%20IOKit-orange?logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.6.2-yellow)](CHANGELOG.md)

<!-- i18n-langbar -->
[English](README.md) · **한국어** · [中文](README.zh-CN.md) · [日本語](README.ja.md) · [Español](README.es.md)

![Electronic Clam menu demo](docs/assets/eclam-menu-demo.gif)

</div>

---

## 핵심 기능

- **덮개를 닫아도 깨어있게.** 토글 하나면 덮개를 닫아도 Mac이 잠들지 않습니다 — 터미널 명령도, 토글할 때마다 비밀번호를 넣을 일도 없습니다.
- **프로세스가 아니라 작업을 감지합니다.** 코딩 에이전트가 *실제로 결과를 뽑아내는 동안에만* 깨어있고, 작업이 끝나 에이전트가 멈추면 Mac도 다시 잠들 수 있습니다.
- **기본 5종 에이전트 인식** — Claude Code, Codex, Cursor, opencode, Antigravity. 원하는 에이전트는 직접 추가할 수 있습니다.
- **상황에 맞춰 움직이는 안전 가드.** 배터리나 온도가 위험선을 넘으면 알아서 잠듭니다.
- **원격 작업도 알아챕니다.** SSH·화면 공유·Tailscale로 접속해 있는 동안엔 잠들지 않아서, 원격 빌드도 끊기지 않습니다.
- **대화나 코드는 절대 들여다보지 않습니다.** 에이전트 감지는 transcript 파일의 수정 시간만 확인할 뿐입니다.

---

## 기능

목표는 에이전트가 **안전하게**, 멈추지 않고 일하게 두는 것. 아래 기능은 모두 그걸 위한 장치입니다.

### 에이전트가 일하는 동안 Mac은 깨워두기

![Agent-aware detection demo](docs/assets/eclam-demo-agents.gif)

핵심은 하나입니다 — 에이전트가 멈추지 않고 일하게 두는 것.

그래서 이 토글은 프로세스가 떠 있는지가 아니라, 에이전트가 *지금 일하는지*를 봅니다. 일하는 동안엔 Mac을 깨워두고, 멈추면 바로 풀립니다 (**Strict**). 프로세스가 살아있는 한 계속 깨워두는 **Lax** 모드도 있습니다.

**기본 인식 (5종):** Claude Code · Codex · Cursor · opencode · Antigravity.

**Customize에서 켜기 (기본 꺼짐):** Aider · Cline · Roo Code · OpenHands · Hermes · Openclaw.

여기 없는 에이전트도 직접 넣을 수 있습니다. glob 패턴을 추가하거나, `~/.config/eclam/traces.d/*.json`에 선언 파일 하나만 두면 됩니다.

감지는 기본적으로 세션 로그를 폴링합니다 (~5초, 화면 잠금 시 ~30초). 그래서 방금 띄운 에이전트는 몇 초 늦게 잡힐 수 있습니다. Claude · Codex · Hermes는 hook을 설치하면 이 지연 없이 바로 잡힙니다 (선택).

### 위험할 땐 알아서 잠들기

![Safety guard demo](docs/assets/eclam-demo-safety.gif)

클램쉘 모드로 가방에 넣고 무거운 작업을 돌리면 발열이 위험할 수 있습니다. Electronic Clam은 온도와 배터리를 지켜보다가, 위험해지면 깨우는 걸 멈추고 Mac을 sleep 모드로 보냅니다:

- **배터리** — 상황에 따라 기준이 다릅니다. 외장 화면 없이 덮개를 닫으면 30%, 아니면 10% (조정 가능). AC 연결이 약하거나 불안정하면 배터리로 봅니다.
- **발열** — macOS 신호에 더 민감한 내부 신호를 더해 빨리 반응합니다.
- **최대 지속 시간** — Desktop 모드(AC + 덮개 열림 + 외장 화면)에선 시간 제한을 건너뜁니다.
- **저전력 모드** — 위 두 기준을 한 단계씩 더 빡빡하게 잡습니다 (배터리 +10%p, 발열 한 단계).

AC가 빠지고 덮개까지 닫혀 가방에 들어간 상태라면 더 깐깐하게 판단합니다. 다시 안전해지면 자동으로 풀립니다. 자동으로 sleep 모드로 들어갈 때 알림을 받을 수 있습니다.

### 원격 활동 인지

![Remote awareness demo](docs/assets/eclam-demo-remote.gif)

다른 기기에서 이 Mac에 접속해 쓰는 동안엔 잠들지 않습니다. SSH, 화면 공유, Tailscale, 알려진 원격 제어 앱을 감지합니다. 기본값은 "접속해 있는 한 깨어있기"입니다.

### Telegram 알림 (기본 꺼짐)

직접 만든 Telegram 봇을 연결하면 알림을 받을 수 있습니다. 에이전트가 멈추거나 Mac이 sleep 모드로 들어갈 때, 배터리·온도·호스트 이름을 담아 보냅니다.

### 그 외

- **CLI + 이름 붙인 세션** — 터미널에서 바로 다룰 수 있습니다 ([Usage](#usage)).
- **에이전트 hook 설치 (선택)** — 설치하면 Claude / Codex / Hermes 설정에 hook이 삽입되고, 삭제 시 복원됩니다.
- **종료할 때 sleep 복원 보장** — 3중 안전장치로 막습니다: 정상 종료, 강제 종료(SIGTERM), 그리고 크래시까지 대비한 20초 watchdog.
- **로그인 시 자동 실행 (선택)** — 로그인할 때 Electronic Clam을 자동으로 시작합니다. 기본은 꺼져 있습니다.
- **업데이트 알림** — GitHub에서 새 릴리스를 확인해 다운로드로 안내합니다. 알림만 보낼 뿐, 알아서 설치하지는 않습니다.
- **클램쉘 VPN 잠금 방지 (선택, 기본 꺼짐).** 외장 화면 없이 배터리로 덮개를 닫으면 화면이 *잠기는데*, 이 잠금 때문에 FortiClient SSL VPN이 끊겨 다시 로그인해야 연결됩니다. 보이지 않는 가상 디스플레이로 세션을 붙잡아 두면 화면이 잠기지 않아 터널이 그대로 유지됩니다 — 백라이트가 없어 전력도 거의 안 들고 추가 하드웨어나 전원도 필요 없습니다. **화면만 끄기** 동작도 **어둡게(Dim)**(깜깜하지만 안 잠김 · VPN 안전 · 기본)와 **재우기(Sleep)**로 나뉘며, VPN이 끊기면 알림을 받도록 켤 수 있습니다.
- **더 단단해진 helper 설정** — 검역(quarantine)된 다운로드본이나 macOS가 등록을 막는 임시(translocation) 위치에서는 백그라운드 helper를 등록하지 않고, 앱을 Applications로 옮기라고 먼저 안내합니다. 설정에서 중복 복사본과 버전 불일치를 짚어 주며, `eclam repair`로 멈추거나 응답 없는 helper를 되살립니다.

## 설치

```bash
brew install --cask jadhvank/tap/eclam
open /Applications/ElectronicClam.app
```

**System Settings → General → Login Items & Extensions**에서 **Electronic Clam Helper**를 On 하세요.

## Usage

메뉴 바 아이콘을 **좌클릭**하면 깨어있기가 토글됩니다. **우클릭**하면 전체 메뉴가 열립니다.

아이콘은 조개껍데기 모양이고 상태에 따라 셋으로 바뀝니다 — 빈 껍데기는 자는 중, 채워진 껍데기+번개는 직접 깨워둔 것, 채워진 껍데기+원격 표시는 자동(에이전트·원격·안전 가드)으로 깨워둔 것.

### 메뉴

| 항목 | 동작 |
|---|---|
| 상태 헤더 | 지금 상태를 한눈에 (예: "유휴 시 잠자기", "깨어있음 — 종료할 때까지", "깨어있음 — 원격 세션") |
| **Mac 깨어있게 유지** (⌘K) | 깨어있기 토글 |
| **에이전트 감시** ▸ | 감지할 에이전트 켜고 끄기 (활동 중이면 "• 활동 중") · 맨 아래 **사용자화…** |
| **화면만 끄기 — 작업은 계속** | 화면만 끄고 Mac·에이전트는 계속 돌리기 |
| **설정…** (⌘,) | 설정 열기 |
| **종료** (⌘Q) | 종료 (종료 전 sleep 복원) |

### CLI

Homebrew cask가 `$HOMEBREW_PREFIX/bin/eclam` 심볼릭 링크를 만듭니다.

```
eclam on [--for <dur>] [--forever]   # keep awake; default 2h, then the helper auto-releases (no GUI needed, survives reboot)
eclam off
eclam status [--json]                # also flags a quarantined app, a failed helper, and duplicate copies
eclam repair                         # recover a wedged/unreachable helper
eclam keep --while <pid>
eclam watch <agent> [--grace s] [--check-interval s] [--max min] [--json]
eclam session start <name> [--message <text>] / stop <name> / list [--json]
eclam debug [agents] [--json]
eclam help
```

**Exit code:** `0` 성공 · `1` 잘못된 인자 · `2` helper 도달 불가 · `3` 승인 필요 · `4` 사용자 취소.

## 보안 및 프라이버시

- 파일 내용이 아니라 수정 시각만 읽습니다.
- 추적도 분석도 텔레메트리도 없습니다.
- XPC 호출자를 검증합니다.
- Developer ID 서명 + Apple 노터라이즈.
- 토큰은 로컬에만 저장합니다.
- sleep은 종료·크래시 때 항상 복원합니다.
- 권한은 SMAppService 한 길뿐입니다.

자세한 내용은 [보안 문서](docs/security.md)를 참고하세요.

## 주의사항 / 알려진 제약

- **hook 없으면 감지에 몇 초 지연이 있을 수 있습니다.** hook을 설치하지 않은 에이전트는 세션 로그 폴링으로 잡습니다(~5초, 잠금 시 ~30초). Claude · Codex · Hermes는 hook을 설치하면 즉시 잡힙니다.
- **CLI만 쓰면 안전 가드가 없습니다.**
- **VS Code 안에서 도는 에이전트**(Cline · Roo Code)는 독립 프로세스가 없어 Lax 모드 감지가 제한적입니다.
- **Apple Silicon 전용**, macOS 13+ (Ventura).

## 기술 스택

- **언어 / UI:** Swift + AppKit (`NSStatusItem`, `LSUIElement` 메뉴바 앱 — Dock 없음).
- **전원 제어:** IOKit SPI — `@_silgen_name` 바인딩을 통한 `IOPMSetSystemPowerSetting("SleepDisabled")`.
- **권한 분리:** `NSXPCConnection`(mach service)으로 앱과 통신하는 `SMAppService` 데몬.
- **빌드:** 직접 `swiftc` (SwiftPM 없음), **외부 의존성 없음**.
- **타깃:** arm64, macOS 13+ (Ventura).

## Build from source

```bash
./scripts/build.sh            # app + helper + hook binaries (Developer ID signed)
open build/ElectronicClam.app
```

- 직접 `swiftc` 호출, `arm64-apple-macos13.0` 타깃. 빠른 ad-hoc 로컬 빌드는 `ECLAM_SIGN_ID=-`로 설정하세요.
- 번들 레이아웃: `Contents/MacOS/{ElectronicClam, ElectronicClamHelper, eclam-hook}` + `Contents/Library/LaunchDaemons/com.jadhvank.eclam.helper.plist`.
- 릴리스 빌드는 Developer ID 서명 + 노터라이즈됩니다 (`release.sh`가 staple).

## 릴리스 내역

최근 릴리스 — 전체 내역은 [CHANGELOG.md](CHANGELOG.md):

- **0.6.2** — 클램쉘 VPN 잠금 방지(선택): 외장 화면 없이 배터리로 덮개를 닫아도 화면이 잠기지 않아, 끊기던 FortiClient SSL VPN이 그대로 유지됩니다 — 보이지 않는 가상 디스플레이가 세션을 붙잡아 둡니다. **화면만 끄기**는 이제 **어둡게(Dim, VPN 안전·기본)**와 **재우기(Sleep)** 중에서 고를 수 있고, VPN이 끊기면 알림을 받을 수 있습니다. 여기에 검역·translocation 복사본에서는 등록을 막고, 중복 복사본·버전 불일치를 짚어 주며, `eclam repair`로 복구하는 더 단단한 helper 설정도 더해졌습니다.
- **0.6.1** — 정직한 helper 상태. 죽었는데 등록만 살아있는 helper가 더 이상 거짓 "enabled"로 보고되지 않습니다. `eclam status`가 `unreachable`(exit 2)로 보고하고, 앱이 재실행 시 자가복구하며, 새 `eclam repair` 명령과 메뉴바 경고가 이를 드러냅니다. `eclam status`는 "로그인 시 실행" 상태도 함께 보고합니다.
- **0.6.0** — 로그인 시 실행, 알림형 인앱 업데이트, awake 히스토리, 다국어(English · 한국어 · 中文 · 日本語 · Español), 단일 클릭 토글, 메뉴바 아이콘 테마, 원격 유휴 정책, Telegram 상태 알림, Developer ID 서명 + 노터라이즈.

이전: 에이전트 인지 감지 및 `watch` / `session` CLI (0.5.x), 상태조건 배터리 / 발열 / 타이머 안전 가드 (0.4.x), 원격 활동 인지 및 첫 CLI (0.3.x).

## 후원

Electronic Clam은 무료 오픈 소스입니다. 에이전트는 Electronic Clam이 깨워두고, 개발자는 여러분의 커피가 깨워두고. ☕

[![Ko-fi](https://img.shields.io/badge/Ko--fi-%E2%98%95-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/jadhvank)

## 라이선스

[MIT](LICENSE).
