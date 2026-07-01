<div align="center">

<img src="docs/assets/eclam-icon.png" width="120" alt="Electronic Clam" />

# Electronic Clam

**Agents must keep working — your Mac shouldn't cook trying.**
它感知的是*工作*,而不只是一个在运行的进程。

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Language](https://img.shields.io/badge/Swift-AppKit%20%2B%20IOKit-orange?logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.6.2-yellow)](CHANGELOG.md)

<!-- i18n-langbar -->
[English](README.md) · [한국어](README.ko.md) · **中文** · [日本語](README.ja.md) · [Español](README.es.md)

![Electronic Clam 菜单演示](docs/assets/eclam-menu-demo.gif)

</div>

---

## 亮点

- **合盖也保持唤醒。** 一个开关就能让 Mac 合上盖子后也不睡眠 —— 无需终端命令,也不必每次切换都输入密码。
- **感知工作,而非进程。** 仅当编程代理*正在实际产出*时才保持唤醒;代理一停下,Mac 就能重新睡眠。
- **开箱即用支持 5 个代理** —— Claude Code、Codex、Cursor、opencode、Antigravity —— 还可以自行添加其他代理。
- **会随情况调整的安全防护。** 当电量或温度越过危险线时自动睡眠。
- **感知远程活动。** 当你通过 SSH、屏幕共享或 Tailscale 使用时不会睡眠 —— 远程构建也不会中断。
- **绝不读取你的对话或代码。** 代理检测只查看 transcript 的时间戳,从不读取其内容。

---

## 功能

目标是让你的代理**安全地**、不被打断地持续工作。下面的一切都为此服务。

### 代理感知的保持唤醒

![代理感知检测演示](docs/assets/eclam-demo-agents.gif)

道理很简单:让你的代理不被打断地持续工作。

所以这个开关跟踪的是代理*此刻是否在工作*,而不是进程是否存在。工作期间 Mac 保持唤醒;一旦停下,保持就会释放(**Strict** 模式)。也提供只要进程存活就保持唤醒的 **Lax** 模式。

**默认检测(5 个):** Claude Code · Codex · Cursor · opencode · Antigravity。

**在 Customize 中启用(默认关闭):** Aider · Cline · Roo Code · OpenHands · Hermes · Openclaw。

未列出的代理也能添加 —— 提供一个 glob 模式,或在 `~/.config/eclam/traces.d/*.json` 中放入一个声明文件即可。

默认情况下,代理通过轮询其会话日志来检测(~5 秒,锁屏时 ~30 秒),所以刚启动的代理可能要过几秒才出现。Claude、Codex 和 Hermes 在安装(可选的)hook 后可被即时检测。

### 安全防护

![安全防护演示](docs/assets/eclam-demo-safety.gif)

在合盖(clamshell)模式下把 Mac 放进包里跑重负载,是有发热风险的。Electronic Clam 会盯着温度和电量,情况危险时就让 Mac 睡眠:

- **电量** —— 阈值取决于你的配置:合盖且无外接显示器时为 30%,否则为 10%(可调)。微弱或不稳定的交流供电按电池计。
- **发热** —— 把 macOS 的信号与一个更敏感的内部信号结合,以更快做出反应。
- **最长时长** —— Desktop 模式(接电 + 开盖 + 外接显示器)会完全跳过上限。
- **低电量模式** —— 把两个标准各收紧一档(电量 +10 个百分点,发热一档)。

当拔掉电源、合上盖子放进包里时,它会更谨慎地判断,情况恢复安全后自动解除。你也可以选择在它让 Mac 睡眠时收到通知。

### 远程活动感知

![远程感知演示](docs/assets/eclam-demo-remote.gif)

当你远程使用这台 Mac 时,Electronic Clam 不会让它睡眠。它能检测 SSH、屏幕共享、Tailscale 以及已知的远程控制 App。默认很简单:只要你还连着就保持唤醒。

### Telegram 通知(默认关闭)

连接你自己的 Telegram 机器人,当代理停止或 Mac 进入睡眠时,你会收到一条提醒 —— 附带电量百分比、温度和主机名。

### 其他

- **CLI + 命名会话** —— 直接从终端操作(见 [Usage](#usage))。
- **可选的代理 hook** —— 安装后会在 Claude / Codex / Hermes 的配置中注入一个活动信号 hook,卸载时还原。
- **退出时保证恢复睡眠** —— 三重保障:退出时同步恢复、一个 SIGTERM 处理器,以及 App 崩溃时的 20 秒看门狗。
- **登录时启动(可选)** —— 登录时自动启动 Electronic Clam;默认关闭。
- **更新通知** —— 检查 GitHub 上的新版本,并指引你前往下载;只通知,绝不自行安装。
- **合盖 VPN 锁定防护(可选,默认关闭)** —— 在无外接显示器的电池供电下合盖时,屏幕会*锁定*,而这次锁定会让 FortiClient SSL VPN 断开,需要重新登录才能连回。用一个隐形的虚拟显示器把会话“锚住”,屏幕就不会锁定,隧道也得以保持 —— 没有背光,几乎不耗电,也不需要额外硬件或电源。**仅熄屏** 动作也拆分为 **变暗(Dim)**(屏幕熄灭但不锁定 · VPN 安全 · 默认)与 **睡眠(Sleep)**,并可选择在 VPN 断开时收到通知。
- **更稳健的 helper 设置** —— 从被检疫(quarantine)的下载副本或 macOS 会拦截的临时(translocation)位置运行时,不再注册后台 helper,而是先引导你把 App 移到 Applications。设置会标记重复副本和版本不一致,`eclam repair` 可恢复卡住或不可达的 helper。

## 安装

```bash
brew install --cask jadhvank/tap/eclam
open /Applications/ElectronicClam.app
```

在 **System Settings → General → Login Items & Extensions** 中开启 **Electronic Clam Helper**。

## Usage

**左键点击**菜单栏图标可切换保持唤醒。**右键点击**打开完整菜单。

图标是一个蛤壳,有三种状态:空壳(睡眠中)、实心壳 + 闪电(你正手动保持唤醒)、实心壳 + 远程标记(代理、远程会话或安全防护正在自动保持唤醒)。

### 菜单

| 项目 | 动作 |
|---|---|
| 状态标题 | 一眼看清当前状态(例如 “空闲时睡眠”、“唤醒 — 直到我退出”、“唤醒 — 远程会话”) |
| **保持 Mac 唤醒**(⌘K) | 切换保持唤醒 |
| **监视代理** ▸ | 启用/停用要检测的代理(检测到活动时显示 “ • 活动中”);底部有 **自定义…** |
| **仅熄屏 — 继续工作** | 熄灭显示器但让 Mac 和代理继续运行 |
| **设置…**(⌘,) | 打开设置 |
| **退出**(⌘Q) | 退出(退出前先恢复睡眠) |

### CLI

Homebrew cask 会创建一个 `$HOMEBREW_PREFIX/bin/eclam` 符号链接。

```
eclam on [--for <dur>] [--forever]   # keep awake; default 2h, then the helper auto-releases (no GUI needed, survives reboot)
eclam off
eclam status [--json]
eclam keep --while <pid>
eclam watch <agent> [--grace s] [--check-interval s] [--max min] [--json]
eclam session start <name> [--message <text>] / stop <name> / list [--json]
eclam debug [agents] [--json]
eclam help
```

**退出码:** `0` 成功 · `1` 参数错误 · `2` helper 不可达 · `3` 需要授权 · `4` 用户取消。

## 安全与隐私

- 只读取文件时钟,不读取文件内容。
- 没有遥测、没有追踪、没有分析。
- 强制 XPC 调用方校验。
- Developer ID 签名 + Apple 公证。
- 令牌只留在本地。
- 退出或崩溃时始终恢复睡眠。
- 只有一条权限路径(`SMAppService`)。

详情见[安全与隐私](docs/security.md)。

## 注意事项 / 已知限制

- **没有 hook 时检测可能延迟几秒。** 未安装 hook 的代理通过轮询其会话日志来检测(~5 秒,锁屏时 ~30 秒)。Claude / Codex / Hermes 在你安装其 hook 后即时生效。
- **仅用 CLI 时没有安全防护。**
- **嵌入 VS Code 的代理**(Cline / Roo Code)没有独立进程,因此 Lax 模式检测受限。
- **仅支持 Apple Silicon**,macOS 13+ (Ventura)。

## 技术栈

- **语言 / UI:** Swift + AppKit(`NSStatusItem`、`LSUIElement` 菜单栏 App —— 无 Dock)。
- **电源控制:** IOKit SPI —— 通过 `@_silgen_name` 绑定调用 `IOPMSetSystemPowerSetting("SleepDisabled")`。
- **权限分离:** 一个 `SMAppService` 守护进程,通过 `NSXPCConnection`(mach service)与 App 通信。
- **构建:** 直接 `swiftc`(无 SwiftPM),**无外部依赖**。
- **目标:** arm64,macOS 13+ (Ventura)。

## Build from source

```bash
./scripts/build.sh            # app + helper + hook binaries (Developer ID signed)
open build/ElectronicClam.app
```

- 直接调用 `swiftc`,目标 `arm64-apple-macos13.0`。快速的临时本地构建可设置 `ECLAM_SIGN_ID=-`。
- 包布局:`Contents/MacOS/{ElectronicClam, ElectronicClamHelper, eclam-hook}` + `Contents/Library/LaunchDaemons/com.jadhvank.eclam.helper.plist`。
- 发布版本经 Developer ID 签名并由 Apple 公证(由 `release.sh` staple)。

## 赞助

Electronic Clam 是免费的开源软件。它让你的代理保持唤醒;你的咖啡让开发者保持清醒。☕

[![Ko-fi](https://img.shields.io/badge/Ko--fi-%E2%98%95-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/jadhvank)

## 许可证

[MIT](LICENSE)。

---

<sub>`README.zh-CN.md`、`README.ja.md` 和 `README.es.md` 由本文件通过 `/translate` 命令生成 —— 请勿手动编辑。`README.ko.md` 由人工维护。</sub>
