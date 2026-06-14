<div align="center">

<img src="docs/assets/eclam-icon.png" width="120" alt="Electronic Clam" />

# Electronic Clam

**Agents must keep working — your Mac shouldn't cook trying.**
ただ動いているプロセスではなく、*作業*そのものを検知します。

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Language](https://img.shields.io/badge/Swift-AppKit%20%2B%20IOKit-orange?logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.5.0-yellow)](CHANGELOG.md)

<!-- i18n-langbar -->
[English](README.md) · [한국어](README.ko.md) · [中文](README.zh-CN.md) · **日本語** · [Español](README.es.md)

![Electronic Clam メニューのデモ](docs/assets/eclam-menu-demo.gif)

</div>

---

## ハイライト

- **フタを閉じても起きたまま。** トグル一つで、フタを閉じても Mac がスリープしません — ターミナルコマンドも、トグルのたびのパスワードも要りません。
- **プロセスではなく作業を検知。** コーディングエージェントが*実際に出力を出している間だけ*起きていて、エージェントが止まれば Mac はまたスリープできます。
- **標準で 5 つのエージェントに対応** — Claude Code、Codex、Cursor、opencode、Antigravity — さらに好きなエージェントを自分で追加できます。
- **状況に合わせて動く安全ガード。** バッテリーや温度が危険ラインを越えると自動でスリープします。
- **リモート作業も察知。** SSH・画面共有・Tailscale で使っている間はスリープせず、リモートビルドも止めません。
- **会話やコードは決して読みません。** エージェント検知は transcript のタイムスタンプだけを見て、中身は読みません。

---

## 機能

目標は、エージェントを**安全に**、止めずに働かせ続けること。以下の機能はすべてそのためにあります。

### エージェントが働く間だけ起こしておく

![エージェント検知のデモ](docs/assets/eclam-demo-agents.gif)

シンプルです — エージェントを止めずに働かせ続けること。

だからこのトグルは、プロセスが存在するかではなく、エージェントが*いま働いているか*を見ます。働いている間は Mac を起こしておき、止まれば保持を解除します(**Strict** モード)。プロセスが生きている限り起こしておくだけの **Lax** モードもあります。

**標準で検知(5 つ):** Claude Code · Codex · Cursor · opencode · Antigravity。

**Customize で有効化(デフォルトはオフ):** Aider · Cline · Roo Code · OpenHands · Hermes · Openclaw。

ここに載っていないエージェントも追加できます — glob パターンを指定するか、`~/.config/eclam/traces.d/*.json` に宣言ファイルを 1 つ置くだけです。

デフォルトでは、エージェントはセッションログのポーリングで検知します(~5 秒、画面ロック中は ~30 秒)。そのため起動直後のエージェントは現れるまで数秒かかることがあります。Claude・Codex・Hermes は(任意の)hook を入れれば即座に検知できます。

### 安全ガード

![安全ガードのデモ](docs/assets/eclam-demo-safety.gif)

クラムシェルモードでバッグに入れたまま重いワークロードを走らせるのは発熱リスクです。Electronic Clam は温度とバッテリーを見ていて、危険になったら Mac をスリープさせます:

- **バッテリー** — しきい値は構成によって変わります:フタを閉じて外部ディスプレイなしなら 30%、それ以外は 10%(調整可)。弱い/不安定な AC 接続はバッテリー扱いです。
- **発熱** — macOS の信号に、より敏感な内部信号を組み合わせて素早く反応します。
- **最大継続時間** — Desktop モード(AC + フタ開き + 外部ディスプレイ)では上限を完全にスキップします。
- **低電力モード** — 両方の基準を 1 段ずつ厳しくします(バッテリー +10 ポイント、発熱 1 段)。

AC を抜いてフタを閉じてバッグに入れた状態では、より慎重に判断し、安全に戻れば自動で解除します。Mac をスリープさせるときに通知を受け取ることもできます。

### リモート活動の検知

![リモート検知のデモ](docs/assets/eclam-demo-remote.gif)

Electronic Clam はリモートで Mac を使っている間はスリープさせません。SSH・画面共有・Tailscale・既知のリモート操作 App を検知します。デフォルトはシンプルで、つながっている間は起きたままです。

### Telegram 通知(デフォルトはオフ)

自分の Telegram ボットをつなぐと、エージェントが止まったり Mac がスリープに入ったりしたときに通知が届きます — バッテリー %、温度、ホスト名つきで。

### その他

- **CLI + 名前付きセッション** — ターミナルから直接操作できます([Usage](#usage) 参照)。
- **任意のエージェント hook** — 入れると Claude / Codex / Hermes の設定に活動シグナルの hook を挿入し、外すと元に戻します。
- **終了時のスリープ復元を保証** — 三重の安全策:終了時の同期復元、SIGTERM ハンドラ、そして App がクラッシュした場合の 20 秒ウォッチドッグ。

## インストール

```bash
brew install --cask jadhvank/tap/eclam
open /Applications/ElectronicClam.app
```

**System Settings → General → Login Items & Extensions** で **Electronic Clam Helper** をオンにしてください。

## Usage

メニューバーのアイコンを**左クリック**すると保持のオン/オフが切り替わります。**右クリック**で全メニューが開きます。

アイコンは貝殻の形で、状態によって 3 つに変わります:輪郭だけの貝殻(スリープ中)、塗りつぶし + 稲妻(自分で起こしている)、塗りつぶし + リモート印(エージェント・リモートセッション・安全ガードが自動で起こしている)。

### メニュー

| 項目 | 動作 |
|---|---|
| ステータスヘッダー | 現在の状態がひと目で(例:「アイドル時にスリープ」「起動中 — 終了するまで」「起動中 — リモートセッション」) |
| **Macをスリープさせない**(⌘K) | 保持の切り替え |
| **エージェントを監視** ▸ | 検知するエージェントのオン/オフ(動作中は「 • 動作中」表示);一番下に **カスタマイズ…** |
| **画面だけオフ — 作業は継続** | 画面を消しても Mac とエージェントは動かし続ける |
| **設定…**(⌘,) | 設定を開く |
| **終了**(⌘Q) | 終了(終了前にスリープを復元) |

### CLI

Homebrew cask が `$HOMEBREW_PREFIX/bin/eclam` シンボリックリンクを作成します。

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

**終了コード:** `0` 成功 · `1` 引数エラー · `2` helper 到達不可 · `3` 承認が必要 · `4` ユーザーがキャンセル。

## セキュリティとプライバシー

- ファイルの中身ではなく、時刻(タイムスタンプ)だけを読みます。
- テレメトリも、追跡も、分析もありません。
- XPC 呼び出し元を検証します。
- Developer ID 署名 + Apple 公証。
- トークンはローカルにのみ保存します。
- 終了・クラッシュ時も必ずスリープを復元します。
- 権限経路は一つだけ(`SMAppService`)。

詳しくは[セキュリティとプライバシー](docs/security.md)を参照してください。

## 注意 / 既知の制限

- **hook がないと検知が数秒遅れることがあります。** hook を入れていないエージェントはセッションログのポーリングで検知します(~5 秒、ロック中は ~30 秒)。Claude / Codex / Hermes は hook を入れれば即座です。
- **CLI だけでは安全ガードがありません。**
- **VS Code 組み込みのエージェント**(Cline / Roo Code)は独立したプロセスがないため、Lax モードの検知は限定的です。
- **Apple Silicon 専用**、macOS 13+ (Ventura)。

## 技術スタック

- **言語 / UI:** Swift + AppKit(`NSStatusItem`、`LSUIElement` のメニューバー App — Dock なし)。
- **電源制御:** IOKit SPI — `@_silgen_name` バインディング経由の `IOPMSetSystemPowerSetting("SleepDisabled")`。
- **権限分離:** `NSXPCConnection`(mach service)で App と通信する `SMAppService` デーモン。
- **ビルド:** 直接 `swiftc`(SwiftPM なし)、**外部依存なし**。
- **ターゲット:** arm64、macOS 13+ (Ventura)。

## Build from source

```bash
./scripts/build.sh            # app + helper + hook binaries (Developer ID signed)
open build/ElectronicClam.app
```

- 直接 `swiftc` を呼び出し、ターゲットは `arm64-apple-macos13.0`。素早いアドホックなローカルビルドには `ECLAM_SIGN_ID=-` を設定します。
- バンドル構成:`Contents/MacOS/{ElectronicClam, ElectronicClamHelper, eclam-hook}` + `Contents/Library/LaunchDaemons/com.jadhvank.eclam.helper.plist`。
- リリースビルドは Developer ID 署名 + Apple 公証されます(`release.sh` が staple)。

## 支援

Electronic Clam は無料のオープンソースです。エージェントを起こしておくのは Electronic Clam、開発者を起こしておくのはあなたのコーヒー。☕

[![Ko-fi](https://img.shields.io/badge/Ko--fi-%E2%98%95-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/jadhvank)

## ライセンス

[MIT](LICENSE)。

---

<sub>`README.zh-CN.md`、`README.ja.md`、`README.es.md` は本ファイルから `/translate` コマンドで生成されます — 手動で編集しないでください。`README.ko.md` は手動でメンテナンスします。</sub>
