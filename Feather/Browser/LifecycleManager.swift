import Foundation
import WebKit

/// Decides which inactive tabs keep a live WKWebView.
///
/// Policy (see InactiveMode): the active tab is always live; the most recently used inactive tabs stay live up to
/// the mode's cap; older ones are unloaded. Triggers are events only — a tab switch, a settings change, a
/// memory-pressure notification — plus one coarse one-shot timer for idle expiry that exists only while some
/// inactive tab is still live. Nothing polls.
///
/// WKWebView cannot freeze a page and resume its JavaScript state. Unloading releases the page; coming back
/// reloads it from the saved URL / interactionState (back-forward list, scroll position).
private final class Once { var done = false }

@MainActor
final class LifecycleManager {
    private unowned let store: TabStore
    private var pressureSource: DispatchSourceMemoryPressure?
    private var idleTimer: Timer?
    private var running = false
    private var pendingLimit: Int?
    private var rerun = false
    /// Set when a tab was kept only because its web process did not answer the safety check in time.
    private var sawTimeout = false
    private var retries = 0
    private var retryTask: Task<Void, Never>?

    init(store: TabStore) {
        self.store = store
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let critical = source?.data.contains(.critical) ?? false
            Task { @MainActor in self?.handlePressure(critical: critical) }
        }
        source.resume()
        pressureSource = source
    }

    deinit { pressureSource?.cancel() }

    func handlePressure(critical: Bool) {
        guard !store.settings.lifecycleDisabled else { return }
        let balanced = store.settings.inactiveMode == .balanced
        Log.lifecycle.notice("memory pressure (critical: \(critical))")
        enforce(limit: critical ? 1 : (balanced ? 3 : 1))
    }

    /// `limit` = max live web views including the active tab; defaults to the current mode's cap.
    func enforce(limit: Int? = nil) {
        guard !store.settings.lifecycleDisabled else { return }
        if running { rerun = true; pendingLimit = min(pendingLimit ?? .max, limit ?? .max); return }
        running = true
        Task {
            await run(limit: limit ?? store.settings.inactiveMode.maxLive)
            running = false
            if rerun {
                let l = pendingLimit
                rerun = false
                pendingLimit = nil
                enforce(limit: l == .max ? nil : l)
            }
        }
    }

    private func run(limit: Int) async {
        let mode = store.settings.inactiveMode
        let now = Date()
        let inactive = store.tabs.filter { $0.isLoaded && $0.id != store.selectedID && !store.isSplitMember($0) }.sorted { $0.lastActive > $1.lastActive }
        sawTimeout = false
        let keep = max(0, limit - 1)
        var doomed = Array(inactive.dropFirst(keep))
        if let idle = mode.maxIdle {
            doomed += inactive.prefix(keep).filter { now.timeIntervalSince($0.lastActive) > idle }
        }
        for tab in doomed.reversed() {                         // oldest first
            guard await canUnload(tab), tab.isLoaded, tab.id != store.selectedID else { continue }
            tab.unload()
            Log.lifecycle.info("unloaded tab (\(tab.url?.host ?? "-"))")
        }
        scheduleIdleTimer()
        scheduleRetryIfNeeded()
    }

    /// A tab kept only because its page was too slow to answer is tried again shortly (a busy page is usually busy only for a moment),
    /// at most three times in a row, so a permanently stuck page is not asked forever. Without this it would stay loaded until some
    /// unrelated event happened to run the check again.
    private func scheduleRetryIfNeeded() {
        guard sawTimeout, retries < 3 else { if !sawTimeout { retries = 0 }; return }
        retries += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.enforce() }
        }
    }

    /// Unloads these tabs now (a folded tab group), skipping the active tab and any tab `canUnload` vetoes. A tab that is vetoed
    /// (still loading, or slow to answer) is tried again every few seconds, up to three times, and only while its group is still folded.
    func unload(_ tabs: [Tab], attempt: Int = 0) async {
        var skipped: [Tab] = []
        for tab in tabs {
            guard tab.isLoaded, tab.id != store.selectedID else { continue }
            if await canUnload(tab), tab.isLoaded, tab.id != store.selectedID {
                tab.unload()
                Log.lifecycle.info("unloaded tab of a folded group (\(tab.url?.host ?? "-"))")
            } else {
                skipped.append(tab)
            }
        }
        guard !skipped.isEmpty, attempt < 3 else { return }
        try? await Task.sleep(for: .seconds(4))
        let stillFolded = skipped.filter { store.group($0.groupID)?.isCollapsed == true }
        if !stillFolded.isEmpty { await unload(stillFolded, attempt: attempt + 1) }
    }

    /// Never discard something the user would notice losing. Anything uncertain (including a web process that
    /// doesn't answer in time) means "keep it".
    private func canUnload(_ tab: Tab) async -> Bool {
        guard let wv = tab.webView, !tab.isLoading else { return false }
        if let host = tab.url?.host, store.settings.isExcluded(host) { return false }
        if store.isSplitMember(tab) { return false }            // shown next to the active tab
        if store.webauthn.isBusy(wv) { return false }          // a security-key sign-in is waiting for a touch
        if wv.cameraCaptureState != .none || wv.microphoneCaptureState != .none { return false }
        let host = tab.url?.host ?? "-"
        return await race(seconds: 2, fallback: false, onTimeout: { [weak self] in self?.sawTimeout = true; Log.lifecycle.error("unload check timed out for \(host); keeping tab") }) { [weak wv] in
            guard let wv else { return false }
            if await wv.requestMediaPlaybackState() == .playing { return false }
            let dirty = (try? await wv.evaluateJavaScript("window.__featherDirty === true")) as? Bool ?? false
            return !dirty
        }
    }

    /// Runs `op`, but gives up after `seconds`. Unlike a task group this returns even if `op` never finishes
    /// (WebKit callbacks aren't cancellable), so a stuck web process can't wedge the lifecycle manager.
    private func race<T>(seconds: Double, fallback: T, onTimeout: @escaping () -> Void, _ op: @escaping @MainActor () async -> T) async -> T {
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            Task { @MainActor in
                let value = await op()
                if !once.done { once.done = true; cont.resume(returning: value) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if !once.done { once.done = true; onTimeout(); cont.resume(returning: fallback) }
            }
        }
    }

    private func scheduleIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard let idle = store.settings.inactiveMode.maxIdle,
              let oldest = store.tabs.filter({ $0.isLoaded && $0.id != store.selectedID }).map(\.lastActive).min() else { return }
        let delay = max(oldest.addingTimeInterval(idle).timeIntervalSinceNow, 30)   // floor avoids thrash on vetoed tabs
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in Task { @MainActor in self?.enforce() } }
        timer.tolerance = delay * 0.2
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }
}
