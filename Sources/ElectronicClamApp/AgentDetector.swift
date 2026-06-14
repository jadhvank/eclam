import Darwin
import Dispatch
import Foundation
import OSLog

// `<notify.h>` is not exposed via the Darwin umbrella module on the swiftc
// command line. We declare the two symbols we need by hand. Stable libSystem ABI.
@_silgen_name("notify_register_dispatch")
private func notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ outToken: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @convention(block) (Int32) -> Void
) -> UInt32

@_silgen_name("notify_cancel")
private func notify_cancel(_ token: Int32) -> UInt32

private let NOTIFY_STATUS_OK: UInt32 = 0

/// Where `eclam-hook` drops PID files when Darwin notify is blocked.
/// ADR-0006 §L. Filename = `<source>-<pid>`, mtime = last hook fire.
/// v0.3.2 — moved out of `/tmp` (which is symlinked to `/private/tmp` and shared
/// across uids) into the per-user `NSTemporaryDirectory()` so sticky-bit /
/// other-user-readable concerns disappear. Hook stub uses the same directory.
let kPIDFileDir: String = {
    let base = NSTemporaryDirectory()
    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
    return trimmed + "/eclam_working_pids"
}()

/// v0.3.2 — process-alive cache for the Lax-mode rule in `StateStore.shouldKeepAwake`.
/// `ps -axo comm` is scanned at most once per 5s; the cached result is consulted
/// synchronously from the convergence engine. Expected comm names come from
/// `AgentTrace.comm` (single source of truth — the previous hand-maintained
/// id→comm table here drifted: cursor-cli / opencode-sessions were missing, so
/// Lax mode could never wake those default agents). Entries whose `comm` is
/// nil (VS Code extensions: Cline, Roo) cannot contribute to Lax mode.
enum LaxProcessAlive {
    private static let lock = NSLock()
    private static var cachedAt: Date = .distantPast
    private static var cachedComms: Set<String> = []
    private static var refreshInFlight = false
    private static let cacheTTL: TimeInterval = 5
    /// `ps -axo comm` 폴링을 converge 동기 경로에서 떼는 전용 직렬 큐. converge
    /// 는 `shouldKeepAwake` 안에서 동기로 이걸 부르는데, 여기서 ps 가 블록되면
    /// 메인 런루프가 멎어 heartbeat 가 굶고 watchdog 오발(작업 중 맥 재움)로
    /// 번진다 — 2026-06-11 시스템 포화 사고의 결합 경로. 그래서 동기 호출은 캐시
    /// 만 읽고(논블로킹), 실제 ps 는 이 큐에서 비동기로 돌려 캐시를 채운다.
    private static let scanQueue = DispatchQueue(label: "com.jadhvank.eclam.lax.ps")

    /// Returns true iff at least one of the given (already watched-filtered)
    /// traces declares a `comm` that is currently present in the **cached**
    /// `ps -axo comm` snapshot. 논블로킹: 캐시가 stale 하면 백그라운드 갱신을
    /// 트리거하면서 마지막 캐시값으로 판정한다. 첫 호출 직후나 갱신 전에는 빈
    /// 캐시라 false 가 될 수 있으나, AgentDetector 의 5s 폴링이 주기적으로
    /// converge 를 재유발(`store.update(activeAgents:)`)하므로 다음 틱에 반영된다
    /// — 기존 short-circuit(이 분기에 도달할 때만 호출)·5s cadence 보존.
    /// Safe to call from any thread.
    static func anyAlive(traces: [AgentTrace]) -> Bool {
        let watchedComms = Set(traces.compactMap(\.comm))
        if watchedComms.isEmpty { return false }

        let live = liveComms()
        return !live.isDisjoint(with: watchedComms)
    }

    /// 마지막으로 스캔된 `comm` basename 집합(논블로킹). 캐시가 `cacheTTL` 보다
    /// 오래됐고 비행 중 갱신이 없으면 백그라운드 ps 갱신을 한 번 트리거한다.
    static func liveComms(now: Date = Date()) -> Set<String> {
        lock.lock()
        let snapshot = cachedComms
        let stale = now.timeIntervalSince(cachedAt) >= cacheTTL
        let shouldRefresh = stale && !refreshInFlight
        if shouldRefresh { refreshInFlight = true }
        lock.unlock()

        if shouldRefresh {
            scanQueue.async {
                let fresh = scan()
                lock.lock()
                cachedComms = fresh
                cachedAt = Date()
                refreshInFlight = false
                lock.unlock()
            }
        }
        return snapshot
    }

    private static func scan() -> Set<String> {
        // converge 동기 경로를 막지 않도록 백그라운드 큐에서만 실행되지만,
        // hung ps 회수를 위해 타임아웃 변형 사용(단일 프로세스 — SIGKILL 충분).
        guard let s = Subprocess.capture("/bin/ps", ["-axo", "comm"],
                                         timeoutSeconds: 4) else { return [] }
        var out: Set<String> = []
        for raw in s.split(separator: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "COMM" { continue }
            // `comm` may be a path; we want the basename.
            let basename = (trimmed as NSString).lastPathComponent
            out.insert(basename)
            // Claude Code's native installer relaunches itself by full path
            // (`…/.local/share/claude/versions/<semver>`), so the basename is a
            // bare version number. Surface it under its canonical name too.
            if trimmed.contains("/claude/versions/") { out.insert("claude") }
        }
        return out
    }
}

/// Unified mtime-poller + hook-relay aggregator (ADR-0006 §G, §J–§L).
///
/// One `AgentDetector` per app launch. Driven by a 5-second `Timer` on the
/// main run loop. Inputs are `AgentTrace`s. Output is a `Set<String>` of
/// active trace ids, delivered to `onChange` on the main thread.
///
/// Activity rule (per ADR-0006 §A/§C):
///   active(trace) ⇐  hookPingedWithin(30s)         (Darwin notify)
///                 ∨  pidFileFreshFor(source, 30s)  (PID-file IPC fallback, §L)
///                 ∨  globMatchMtime(within freshness)
///                    AND (Claude → live cwd pairing, §J)
///
/// Detection latency: 5s polling Timer + sub-100ms `FileChangeWatcher` per
/// trace dir (§K). Both ORed.
final class AgentDetector {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "agent")
    private let pollInterval: TimeInterval = 5
    /// proposal §7 — 화면 잠금 중 폴링 다운시프트. 잠금 중엔 새 에이전트
    /// 시작 감지가 최대 30s 늦어질 뿐(이미 잡힌 활동의 유지엔 영향 미미)이라
    /// ps/lsof/glob 비용을 6분의 1로 줄인다. SafetyMonitor 의 1 Hz 가드는
    /// 영향 없음 (별도 타이머).
    private let pollIntervalLocked: TimeInterval = 30
    private var screenLocked = false
    private var screenLockObservers: [NSObjectProtocol] = []
    private let hookGrace: TimeInterval = 30
    private let pidFileGrace: TimeInterval = 30
    private let pidFileTTL: TimeInterval = 60

    private var traces: [AgentTrace] = []
    private var timer: Timer?

    /// hookKey → last ping date. Updated by Darwin notify subscription.
    private var lastHookPing: [String: Date] = [:]
    /// notify token per source, so we can `notify_cancel` on stop.
    private var hookTokens: [String: Int32] = [:]

    /// One `FileChangeWatcher` per watched directory. Key = directory path.
    private var watchers: [String: FileChangeWatcher] = [:]

    /// v0.3.2 — `eclam session start/stop` heartbeat scanner. Set is
    /// merged into the active aggregation as `session:<name>` ids.
    private let sessionWatcher = SessionWatcher()

    /// Claude workspace pairing (§J) — sanitized cwds of live `claude` procs,
    /// cached for `pollInterval` seconds. 캐시 읽기·기록은 메인 스레드 전용
    /// (tick/revalidate/debugSnapshot 모두 메인). 실제 `ps`/`lsof` 실행은 아래
    /// `procQueue` 백그라운드에서 돌고, 결과만 메인으로 마샬해 캐시에 쓴다.
    private var liveClaudeWorkspacesCache: Set<String> = []
    private var liveClaudeWorkspacesCachedAt: Date = .distantPast
    private var liveClaudeWorkspacesFallbackWarned = false
    /// 백그라운드 갱신이 비행 중인지 — 폴 틱이 여러 번 겹쳐도 ps/lsof 를 한 번만
    /// 돌린다. 메인 전용 플래그.
    private var liveClaudeRefreshInFlight = false

    /// `ps -axo comm`/`pid,comm` + `lsof` 폴링을 메인 스레드에서 떼는 전용 직렬
    /// 큐. 시스템 포화·느린 lsof·hung 마운트로 이 명령들이 블록돼도 메인 런루프
    /// 가 계속 돌아 heartbeat 가 굶지 않고 watchdog 오발을 막는다. (단일 프로세스
    /// 명령이라 타임아웃 변형의 SIGKILL 회수로 충분.)
    private let procQueue = DispatchQueue(label: "com.jadhvank.eclam.agent.proc")

    /// Most recent active set; published on every poll tick (debounced — no-op
    /// if unchanged).
    private(set) var active: Set<String> = []

    /// Fired on the main queue whenever the active set changes.
    var onChange: ((Set<String>) -> Void)?

    /// v0.3.2 — checked by `AppDelegate.startSubsystemsIfNewlyEnabled` to
    /// avoid restarting a detector that's already polling.
    var timerIsRunning: Bool { timer != nil }

    // MARK: - Lifecycle

    /// Updates the traces being watched. Idempotent. Re-subscribes hook channels
    /// only for new hookKeys (existing tokens are preserved). Reconciles the
    /// `FileChangeWatcher` set against the new directory list.
    func setTraces(_ next: [AgentTrace]) {
        // De-dupe by id; later entries win.
        var seen: [String: AgentTrace] = [:]
        for t in next { seen[t.id] = t }
        let collapsed = Array(seen.values)
        self.traces = collapsed

        // Subscribe to any hookKey we don't already track.
        let wantedHookKeys = Set(collapsed.compactMap(\.hookKey))
        for key in wantedHookKeys where hookTokens[key] == nil {
            subscribeHook(key: key)
        }
        // Drop subscriptions no longer needed.
        for (key, token) in hookTokens where !wantedHookKeys.contains(key) {
            _ = notify_cancel(token)
            hookTokens.removeValue(forKey: key)
            lastHookPing.removeValue(forKey: key)
        }

        reconcileWatchers()
        tick()  // immediate recompute
    }

    func start() {
        guard timer == nil else { return }
        installTimer()
        log.info("AgentDetector started (poll=\(self.pollInterval, privacy: .public)s)")
        installScreenLockObservers()
        sessionWatcher.start()
        reconcileWatchers()
        tick()
    }

    /// 현재 잠금 상태에 맞는 간격으로 폴링 타이머를 (재)설치.
    private func installTimer() {
        timer?.invalidate()
        let interval = screenLocked ? pollIntervalLocked : pollInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so menu interaction doesn't pause the poll.
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    /// proposal §7 — 잠금/해제 분산 알림으로 폴링 간격 전환. 해제 시엔 즉시
    /// 1회 tick 해서 잠금 동안 쌓인 변화를 바로 반영.
    private func installScreenLockObservers() {
        guard screenLockObservers.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        let locked = dnc.addObserver(forName: .init("com.apple.screenIsLocked"),
                                     object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.screenLocked else { return }
            self.screenLocked = true
            if self.timer != nil { self.installTimer() }
            self.log.info("screen locked — agent poll downshifted to \(self.pollIntervalLocked, privacy: .public)s")
        }
        let unlocked = dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                       object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.screenLocked else { return }
            self.screenLocked = false
            if self.timer != nil {
                self.installTimer()
                self.tick()
            }
            self.log.info("screen unlocked — agent poll restored to \(self.pollInterval, privacy: .public)s")
        }
        screenLockObservers = [locked, unlocked]
    }

    func stop() {
        for obs in screenLockObservers {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        screenLockObservers = []
        timer?.invalidate()
        timer = nil
        for (_, token) in hookTokens { _ = notify_cancel(token) }
        hookTokens.removeAll()
        lastHookPing.removeAll()
        for (_, w) in watchers { w.stop() }
        watchers.removeAll()
        sessionWatcher.stop()
        log.info("AgentDetector stopped")
    }

    /// Single-shot debug entry point (ADR-0006 §M). Runs one tick synchronously
    /// and returns a structured snapshot; does NOT start the polling timer or
    /// any watchers, and never mutates `onChange` listeners.
    @discardableResult
    func debugSnapshot() -> AgentDetectorDebugSnapshot {
        let now = Date()
        let pidFileSources = scanPIDFiles(now: now)
        // 디버그 단일샷은 비동기 캐시(빈 값일 수 있음)에 의존하면 안 된다 —
        // ADR-0006 §M 계약이 "동기 1회 결과"이므로 ps/lsof 를 직접 동기 실행한다.
        // 이 경로는 폴링 루프(메인 런루프)가 아니라 CLI `debug agents` 트리거라
        // heartbeat 굶주림 위험이 없다.
        let liveClaude: Set<String>
        switch Self.computeLiveClaudeWorkspaces() {
        case .ok(let cwds):   liveClaude = cwds
        case .unavailable:    liveClaude = []
        }
        var perTrace: [AgentDetectorDebugSnapshot.TraceRow] = []
        var nextActive: Set<String> = []

        for trace in traces {
            let row = evaluateTrace(trace, now: now, liveClaude: liveClaude, pidFileSources: pidFileSources)
            if row.active { nextActive.insert(trace.id) }
            perTrace.append(row)
        }

        var hookPings: [(String, Date)] = []
        for (k, v) in lastHookPing { hookPings.append((k, v)) }

        return AgentDetectorDebugSnapshot(
            generatedAt: now,
            traces: perTrace,
            hookPings: hookPings,
            liveClaudeWorkspaces: liveClaude,
            pidFileSources: Array(pidFileSources),
            active: nextActive)
    }

    // MARK: - Hook subscription (Darwin notify)

    private func subscribeHook(key: String) {
        let sanitized = HelperServiceName.sanitizeActivitySource(key)
        guard !sanitized.isEmpty else { return }
        let name = "\(HelperServiceName.activityNotifyPrefix).\(sanitized)"
        var token: Int32 = 0
        // Pre-build the block so it isn't materialized inside `withCString`'s
        // @noescape scope (which traps when the block is captured and stored
        // by libnotify for the lifetime of the registration).
        let block: @convention(block) (Int32) -> Void = { [weak self] _ in
            guard let self = self else { return }
            self.lastHookPing[sanitized] = Date()
            self.tick()
        }
        let status = name.withCString { cstr -> UInt32 in
            notify_register_dispatch(cstr, &token, DispatchQueue.main, block)
        }
        if status == NOTIFY_STATUS_OK {
            hookTokens[sanitized] = token
            log.info("subscribed hook channel \(name, privacy: .public)")
        } else {
            log.error("notify_register_dispatch(\(name, privacy: .public)) status=\(status, privacy: .public)")
        }
    }

    // MARK: - Watcher reconciliation (ADR-0006 §K)

    private func reconcileWatchers() {
        guard timer != nil else { return }  // only manage watchers while running
        // Compute the set of watch directories from current traces.
        var wantedDirs: Set<String> = []
        var dirToTraceIds: [String: [String]] = [:]
        for t in traces {
            guard let dir = staticWatchDirectory(for: t.globPattern) else { continue }
            wantedDirs.insert(dir)
            dirToTraceIds[dir, default: []].append(t.id)
        }

        // Drop watchers no longer needed.
        for (dir, w) in watchers where !wantedDirs.contains(dir) {
            w.stop()
            watchers.removeValue(forKey: dir)
        }

        // Soft-cap watchers at RLIMIT_NOFILE / 4 (warn — but still attempt).
        var rl = rlimit()
        getrlimit(RLIMIT_NOFILE, &rl)
        let softCap = Int(rl.rlim_cur) / 4
        if wantedDirs.count > softCap {
            log.warning("watcher count \(wantedDirs.count, privacy: .public) exceeds RLIMIT_NOFILE/4 (\(softCap, privacy: .public)) — DispatchSources may starve fds")
        }

        for dir in wantedDirs where watchers[dir] == nil {
            // Skip if the directory does not yet exist; the next poll cycle
            // will re-attempt once it's created.
            var st = stat()
            guard stat(dir, &st) == 0 else { continue }
            do {
                let url = URL(fileURLWithPath: dir)
                let traceIds = dirToTraceIds[dir] ?? []
                let watcher = try FileChangeWatcher(directoryURL: url, queue: .main) { [weak self] in
                    guard let self = self else { return }
                    // Sub-100ms re-evaluation — but only for traces that map
                    // to THIS directory, so a noisy /tmp event doesn't fan
                    // out across the whole set.
                    self.revalidateMtime(traceIds: traceIds)
                }
                watchers[dir] = watcher
                let idsJoined = traceIds.joined(separator: ",")
                log.info("watching \(dir, privacy: .public) for \(idsJoined, privacy: .public)")
            } catch {
                log.error("could not watch \(dir, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Walks up `pattern` until the last static path segment. Tilde-expanded.
    /// e.g. `~/.claude/projects/*/*.jsonl` → `~/.claude/projects`.
    /// Returns nil if no static prefix exists (pure glob).
    private func staticWatchDirectory(for pattern: String) -> String? {
        let expanded = Glob.expand_tildeOnly(pattern)
        let parts = expanded.split(separator: "/", omittingEmptySubsequences: false)
        var staticParts: [String] = []
        for part in parts {
            if part.contains("*") || part.contains("?") || part.contains("[") {
                break
            }
            staticParts.append(String(part))
        }
        // Drop the final basename — we want the directory containing it.
        // If the pattern was static all the way down (no wildcards), use the
        // dirname so we still watch a directory.
        if staticParts.count <= 1 { return nil }
        if staticParts.count == parts.count {
            staticParts.removeLast()
        } else {
            // Wildcard appeared; staticParts is everything before it. The last
            // element of staticParts is the directory we want.
        }
        let dir = staticParts.joined(separator: "/")
        return dir.isEmpty ? "/" : dir
    }

    // MARK: - Tick

    /// Targeted re-evaluation for a subset of traces (used by file watchers
    /// to skip the full sweep). Updates `active` if necessary.
    private func revalidateMtime(traceIds: [String]) {
        let now = Date()
        let liveClaude = liveClaudeWorkspaces(now: now)
        let pidFileSources = scanPIDFiles(now: now)
        var changed = false
        var nextActive = active

        for trace in traces where traceIds.contains(trace.id) {
            let row = evaluateTrace(trace, now: now, liveClaude: liveClaude, pidFileSources: pidFileSources)
            if row.active && !nextActive.contains(trace.id) {
                nextActive.insert(trace.id); changed = true
            } else if !row.active && nextActive.contains(trace.id) {
                // Don't drop here — full tick has the authoritative view.
            }
        }

        if changed {
            active = nextActive
            let snapshot = nextActive
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(snapshot)
            }
        }
    }

    private func tick() {
        let now = Date()
        let liveClaude = liveClaudeWorkspaces(now: now)
        let pidFileSources = scanPIDFiles(now: now)
        var nextActive: Set<String> = []

        for trace in traces {
            let row = evaluateTrace(trace, now: now, liveClaude: liveClaude, pidFileSources: pidFileSources)
            if row.active { nextActive.insert(trace.id) }
        }

        // v0.3.2 — merge in `session:<name>` ids from the SessionWatcher.
        // The scan is local + cheap (one directory listing); no need to
        // de-duplicate against trace ids because session names use a `session:`
        // prefix and trace ids never start with `session:`.
        nextActive.formUnion(sessionWatcher.aliveSessionIDs(now: now))

        // Re-check watcher reconciliation in case a trace's watch dir
        // appeared since the last tick.
        reconcileWatchers()

        if nextActive != active {
            active = nextActive
            let snapshot = nextActive
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(snapshot)
            }
        }
    }

    private func evaluateTrace(_ trace: AgentTrace,
                               now: Date,
                               liveClaude: Set<String>,
                               pidFileSources: Set<String>) -> AgentDetectorDebugSnapshot.TraceRow {
        // Hook channel (Darwin notify) — match by hookKey (sanitized). Resolve the
        // raw signals here (dictionary/Set lookups, no I/O) and let the pure
        // `AgentActivity` layer decide. Short-circuit preserved: the mtime glob/
        // `stat` below only runs when the hook channel does not already fire, so
        // hook-ping/pidfile rows keep `latestMatch`/`mtimeAge` nil as before.
        if let key = trace.hookKey {
            let sanitized = HelperServiceName.sanitizeActivitySource(key)
            let hookPingAge = lastHookPing[sanitized].map { now.timeIntervalSince($0) }
            if let hook = AgentActivity.hookDecision(hookPingAge: hookPingAge,
                                                     hookGrace: hookGrace,
                                                     pidFilePresent: pidFileSources.contains(sanitized)) {
                return .init(label: trace.label, glob: trace.globPattern,
                             latestMatch: nil, mtimeAge: nil,
                             active: hook.active, reason: hook.reason)
            }
        }

        // File-mtime channel. For Claude apply workspace pairing (§J).
        let pair = freshestMatch(pattern: trace.globPattern, now: now)
        let mtimeMatch = pair.map { AgentActivity.MtimeMatch(path: $0.0, age: $0.1) }

        // Resolve the Claude pairing signal (pure string + Set lookup); only the
        // `claude` trace ever consults it.
        var claudeCwdMatched = false
        var claudeSegment: String?
        if trace.id == "claude", let (path, _) = pair, !liveClaude.isEmpty {
            if let segment = ClaudeWorkspacePathing.projectSegment(fromMatchedPath: path) {
                claudeSegment = segment
                claudeCwdMatched = liveClaude.contains(segment)
            }
        }

        let decision = AgentActivity.mtimeDecision(
            mtimeMatch: mtimeMatch,
            freshness: trace.freshness,
            isClaude: trace.id == "claude",
            liveClaudeEmpty: liveClaude.isEmpty,
            claudeCwdMatched: claudeCwdMatched,
            claudeSegment: claudeSegment)

        return .init(label: trace.label, glob: trace.globPattern,
                     latestMatch: pair?.0, mtimeAge: pair?.1,
                     active: decision.active, reason: decision.reason)
    }

    private func freshestMatch(pattern: String, now: Date) -> (String, TimeInterval)? {
        var bestPath: String?
        var bestAge: TimeInterval = .infinity
        for path in Glob.expand(pattern) {
            var st = stat()
            if stat(path, &st) == 0 {
                let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                                 + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
                let age = now.timeIntervalSince(mtime)
                if age < bestAge {
                    bestAge = age
                    bestPath = path
                }
            }
        }
        if let p = bestPath { return (p, bestAge) }
        return nil
    }

    // MARK: - Claude workspace pairing (ADR-0006 §J)

    /// Live `claude` / `claude-code` process cwds, sanitized to Claude's
    /// `~/.claude/projects/<sanitized>/` filename convention (`/` → `-`,
    /// leading `-` stripped).
    ///
    /// **논블로킹.** 메인 스레드에서만 호출된다(tick/revalidate/debugSnapshot).
    /// 캐시(≤`pollInterval`s)가 신선하면 그대로 반환한다. stale 하면 마지막
    /// 캐시값을 즉시 반환하면서 백그라운드 갱신(`ps`/`lsof`)을 트리거하고, 갱신
    /// 완료 시 메인에서 `tick()` 을 다시 돌려 새 값을 반영한다. 이렇게 해서
    /// 메인 런루프가 ps/lsof 로 절대 블록되지 않아 heartbeat 가 굶지 않는다.
    ///
    /// On `ps`/`lsof` failure the background refresh stores an empty set; callers
    /// treat empty as "skip pairing" rather than "no live procs" (logged once via
    /// `liveClaudeWorkspacesFallbackWarned`).
    func liveClaudeWorkspaces(now: Date = Date()) -> Set<String> {
        if now.timeIntervalSince(liveClaudeWorkspacesCachedAt) < pollInterval {
            return liveClaudeWorkspacesCache
        }
        triggerLiveClaudeRefreshIfNeeded()
        return liveClaudeWorkspacesCache
    }

    /// 캐시가 stale 하고 비행 중인 갱신이 없으면 백그라운드에서 `ps`/`lsof` 를
    /// 돌려 캐시를 갱신한다. 완료 콜백은 메인에서 캐시를 쓰고 `tick()` 을 재호출.
    /// 메인 전용(in-flight 플래그 보호).
    private func triggerLiveClaudeRefreshIfNeeded() {
        guard !liveClaudeRefreshInFlight else { return }
        liveClaudeRefreshInFlight = true
        procQueue.async { [weak self] in
            guard let self = self else { return }
            let result = Self.computeLiveClaudeWorkspaces()
            DispatchQueue.main.async {
                self.liveClaudeRefreshInFlight = false
                self.liveClaudeWorkspacesCachedAt = Date()
                switch result {
                case .unavailable:
                    if !self.liveClaudeWorkspacesFallbackWarned {
                        self.liveClaudeWorkspacesFallbackWarned = true
                        self.log.warning("ps unavailable; Claude workspace pairing disabled (fallback to permissive mtime)")
                    }
                    self.liveClaudeWorkspacesCache = []
                case .ok(let cwds):
                    self.liveClaudeWorkspacesCache = cwds
                }
                // 새 값이 들어왔으니 한 번 더 평가 — 타이머 사이의 변화를 즉시
                // 반영(전체 sweep 은 idempotent, no-op 이면 onChange 안 쏨).
                self.tick()
            }
        }
    }

    private enum LiveClaudeResult { case unavailable; case ok(Set<String>) }

    /// 백그라운드 전용. `ps`/`lsof` 를 실행해 live claude cwd 집합을 계산한다.
    /// 인스턴스 상태를 만지지 않는 순수 정적 함수라 큐 경쟁이 없다.
    private static func computeLiveClaudeWorkspaces() -> LiveClaudeResult {
        guard let pids = listClaudePIDs() else { return .unavailable }
        var cwds: Set<String> = []
        for cwd in cwdsForPIDs(pids) {
            cwds.insert(ClaudeWorkspacePathing.sanitizeCwdToSegment(cwd))
        }
        return .ok(cwds)
    }

    /// `ps -axo pid,comm` and grep for processes named `claude` or `claude-code`.
    /// Returns nil on failure (caller treats as "pairing unavailable"). 백그라운드
    /// 전용(`procQueue`) — 4s 타임아웃으로 hung ps 를 SIGKILL 회수.
    private static func listClaudePIDs() -> [Int32]? {
        guard let out = Subprocess.capture("/bin/ps", ["-axo", "pid,comm"],
                                           timeoutSeconds: 4) else { return nil }
        var result: [Int32] = []
        out.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // pid<space>comm
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { return }
            let pidPart = String(trimmed[..<spaceIdx])
            let comm = trimmed[trimmed.index(after: spaceIdx)...].trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(pidPart) else { return }
            // `comm` may be a full path (e.g. /usr/local/bin/claude-code) — match basename.
            // Claude Code's native installer relaunches by full path
            // (`…/.local/share/claude/versions/<semver>`), so also accept that
            // path shape — its basename is a bare version number.
            let basename = (comm as NSString).lastPathComponent
            if basename == "claude" || basename == "claude-code"
                || comm.contains("/claude/versions/") {
                result.append(pid)
            }
        }
        return result
    }

    /// 한 번의 lsof 호출로 모든 pid 의 cwd 를 얻는다. 이전에는 pid 당 1회
    /// spawn(claude 세션 N개면 5초마다 N회)이라 spawn churn 이 컸다 —
    /// 2026-06-11 시스템 포화 사고 후속 위생 조치로 틱당 1회로 배칭.
    /// `lsof -a -p p1,p2 -d cwd -F pn` 출력: `p<pid>` / `fcwd` / `n<path>` 반복.
    /// `-a` 필수 (없으면 -p/-d 가 OR 로 풀려 시스템 전체를 덤프).
    /// 백그라운드 전용(`procQueue`). lsof 는 hung 마운트/느린 fs 에서 가장 잘
    /// 블록되는 명령이라 6s 타임아웃으로 SIGKILL 회수 (단일 프로세스).
    private static func cwdsForPIDs(_ pids: [Int32]) -> [String] {
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = Subprocess.capture("/usr/sbin/lsof",
                                           ["-a", "-p", list, "-d", "cwd", "-F", "pn"],
                                           timeoutSeconds: 6) else { return [] }
        var result: [String] = []
        for raw in out.split(separator: "\n") where raw.first == "n" {
            let s = String(raw.dropFirst())
            if !s.isEmpty && s != "/" { result.append(s) }
        }
        return result
    }

    // MARK: - PID-file IPC fallback (ADR-0006 §L)

    /// Scans `<NSTemporaryDirectory()>/eclam_working_pids/*`. Files older
    /// than `pidFileTTL` or whose pid is no longer live are deleted, but only
    /// when owned by the current uid (v0.3.2 sticky-bit safety — the dir is
    /// now per-user but the same predicate is cheap and defensive). Returns
    /// the set of source ids (from filename `<source>-<pid>`) with at least
    /// one fresh & live entry within `pidFileGrace`.
    func scanPIDFiles(now: Date = Date()) -> Set<String> {
        let fm = FileManager.default
        var sources: Set<String> = []
        guard let entries = try? fm.contentsOfDirectory(atPath: kPIDFileDir) else {
            return []
        }
        let myUID = getuid()
        for name in entries {
            let path = kPIDFileDir + "/" + name
            var st = stat()
            guard stat(path, &st) == 0 else { continue }
            // Only consider — and only ever delete — files owned by us.
            guard st.st_uid == myUID else { continue }
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                             + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
            let age = now.timeIntervalSince(mtime)

            // Parse `<source>-<pid>`. Allow source to contain `-` so split from the last `-`.
            guard let lastDash = name.lastIndex(of: "-") else {
                try? fm.removeItem(atPath: path); continue
            }
            let source = String(name[..<lastDash])
            let pidStr = String(name[name.index(after: lastDash)...])
            guard let pid = Int32(pidStr) else {
                try? fm.removeItem(atPath: path); continue
            }

            // Stale by TTL?
            if age > pidFileTTL {
                try? fm.removeItem(atPath: path)
                continue
            }
            // Stale by process death?
            if kill(pid, 0) == -1 && errno == ESRCH {
                try? fm.removeItem(atPath: path)
                continue
            }
            // Fresh enough to count as active?
            if age <= pidFileGrace {
                sources.insert(source)
            }
        }
        return sources
    }

    // MARK: - Subprocess helpers

    // runProcess — Subprocess.capture로 통합. 아래 두 호출처에서 직접 사용.
    // (AgentDetector 인스턴스 내부였으나 로직 동일 → 제거하고 정적 유틸로 위임)
}

// MARK: - Debug snapshot (ADR-0006 §M)

struct AgentDetectorDebugSnapshot {
    struct TraceRow {
        let label: String
        let glob: String
        let latestMatch: String?
        let mtimeAge: TimeInterval?
        let active: Bool
        let reason: String
    }

    let generatedAt: Date
    let traces: [TraceRow]
    let hookPings: [(String, Date)]
    let liveClaudeWorkspaces: Set<String>
    let pidFileSources: [String]
    let active: Set<String>
}

// MARK: - Glob

/// Tiny `~`-aware wrapper around POSIX `glob(3)`. No external deps.
enum Glob {
    static func expand(_ pattern: String) -> [String] {
        let resolved = expand_tildeOnly(pattern)
        var g = glob_t()
        defer { globfree(&g) }
        // Flags:
        //   GLOB_NOSORT  — order doesn't matter for "any match fresh?" check.
        //   GLOB_TILDE   — we already expanded `~`, but harmless if set; not all
        //                  libcs define it, so we leave it off and do it ourselves.
        let flags: Int32 = GLOB_NOSORT
        let rc = resolved.withCString { cstr in
            glob(cstr, flags, nil, &g)
        }
        guard rc == 0 else { return [] }
        var out: [String] = []
        out.reserveCapacity(Int(g.gl_pathc))
        if let v = g.gl_pathv {
            for i in 0..<Int(g.gl_pathc) {
                if let p = v[i] {
                    out.append(String(cString: p))
                }
            }
        }
        return out
    }

    /// Expand a leading `~` or `~/` to the current user's home directory.
    static func expand_tildeOnly(_ pattern: String) -> String {
        guard pattern.hasPrefix("~") else { return pattern }
        let home = NSHomeDirectory()
        if pattern == "~" { return home }
        if pattern.hasPrefix("~/") {
            return home + String(pattern.dropFirst(1))
        }
        // `~user/...` — not supported; pass through.
        return pattern
    }
}

// MARK: - SessionWatcher (v0.3.2)

/// v0.3.2 — directory poller for `eclam session start/stop`. The CLI
/// creates one file per named session under `<NSTemporaryDirectory()>/eclam_sessions/`
/// containing the foreground PID as ASCII decimal and rewrites its mtime every
/// 5s as a heartbeat. A session is **alive** iff:
///
///   - file exists AND
///   - `mtime > now - 30s` (heartbeat fresh) AND
///   - `kill(pid, 0)` does NOT return ESRCH (process still in the table)
///
/// On every scan we also sweep stale entries:
///   - mtime > 60s → remove
///   - dead pid (ESRCH) → remove
///   - only files owned by `getuid()` are ever deleted (sticky-bit safety)
///
/// Output ids carry a `session:` prefix so they don't collide with trace ids.
/// The set is consulted by `AgentDetector.tick()` on the 5s timer; the watcher
/// itself does not own a timer (no extra fds).
final class SessionWatcher {
    /// Per-user, sticky-bit-safe location. Both the CLI and watcher agree on
    /// this exact path (the v0.3.2 shared contract). Computed once at load.
    static let directory: String = {
        let base = NSTemporaryDirectory()
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmed + "/eclam_sessions"
    }()

    /// Heartbeat freshness — must match the CLI's 5s mtime touch + 25s slack.
    private let aliveCutoff: TimeInterval = 30
    /// Stale-sweep threshold — anything older than this is removed.
    private let staleCutoff: TimeInterval = 60

    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "session")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        // No standalone timer — `AgentDetector` calls `aliveSessionIDs(now:)`
        // on its 5s tick. Best-effort `mkdir -p` so the contract directory
        // exists before the CLI ever writes to it.
        try? FileManager.default.createDirectory(atPath: Self.directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        log.info("SessionWatcher started, scanning \(Self.directory, privacy: .public)")
    }

    func stop() {
        started = false
    }

    /// Returns the set of alive sessions formatted as `session:<name>`. Empty
    /// (NOT an error) when the directory is missing or empty.
    func aliveSessionIDs(now: Date = Date()) -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: Self.directory) else {
            return []
        }
        let myUID = getuid()
        var alive: Set<String> = []
        for name in entries {
            // Name must be in the sanitized form spec'd in the shared contract.
            // We don't reject invalid names here — they just won't match any
            // session the CLI would create — but we do clamp to avoid pathological
            // input from a tampering co-uid.
            guard isValidSessionName(name) else { continue }
            let path = Self.directory + "/" + name
            var st = stat()
            guard stat(path, &st) == 0 else { continue }
            let ownedByUs = (st.st_uid == myUID)

            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                             + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
            let age = now.timeIntervalSince(mtime)

            // Read PID. File is plain ASCII decimal, max 10-ish bytes; cap read.
            var pid: Int32 = 0
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               data.count <= 32,
               let s = String(data: data, encoding: .ascii)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = Int32(s) {
                pid = parsed
            } else {
                if ownedByUs && age > staleCutoff {
                    try? fm.removeItem(atPath: path)
                }
                continue
            }

            // Process-alive probe (cheap, syscall-only).
            let procAlive = !(kill(pid, 0) == -1 && errno == ESRCH)

            if age > staleCutoff || !procAlive {
                if ownedByUs {
                    try? fm.removeItem(atPath: path)
                }
                continue
            }
            if age <= aliveCutoff && procAlive {
                alive.insert("session:\(name)")
            }
        }
        return alive
    }

    /// Mirror of the CLI sanitizer: lowercase `[a-z0-9_-]`, max 64 chars.
    private func isValidSessionName(_ name: String) -> Bool {
        if name.isEmpty || name.count > 64 { return false }
        for scalar in name.unicodeScalars {
            let v = scalar.value
            let isLower = (v >= 0x61 && v <= 0x7A)
            let isDigit = (v >= 0x30 && v <= 0x39)
            let isSep   = (v == 0x5F || v == 0x2D) // _ -
            if !(isLower || isDigit || isSep) { return false }
        }
        return true
    }
}
