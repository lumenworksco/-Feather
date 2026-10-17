import SwiftUI
import WebKit

/// A message about the safety of the user's data. It is shown over the window (in either layout) until it is
/// dismissed or the problem goes away.
enum PersistenceBanner: Equatable {
    case saveFailed(String)
    case restoredFromBackup(String)
    case partialRestore
    case unreadable
    case lockedOut
    case info(String)

    var kind: String {
        switch self {
        case .saveFailed: return "saveFailed"
        case .restoredFromBackup: return "restoredFromBackup"
        case .partialRestore: return "partialRestore"
        case .unreadable: return "unreadable"
        case .lockedOut: return "lockedOut"
        case .info: return "info"
        }
    }
    var message: String {
        switch self {
        case .saveFailed(let why): return "Feather couldn’t save your tabs (\(why)). It keeps trying, and your open tabs are unaffected."
        case .restoredFromBackup(let text): return text
        case .partialRestore: return "Some tabs in your saved session were damaged and couldn’t be restored. A copy of the file was kept."
        case .unreadable: return "Your saved tabs couldn’t be read. Nothing was deleted: the damaged files were kept."
        case .lockedOut: return "Feather is already open with this profile, so changes made here won’t be saved."
        case .info(let text): return text
        }
    }
    var isWarning: Bool {
        switch self { case .saveFailed, .partialRestore, .unreadable, .lockedOut: return true; case .restoredFromBackup, .info: return false }
    }
}

/// Text shown in the address field. Its own small object (not part of TabStore) so a keystroke re-renders only the
/// address field, not every view that watches the store.
@MainActor
final class AddressModel: ObservableObject {
    @Published var text = ""
}

/// How a URL is displayed in the address field when it is not being edited.
enum AddressFormat {
    /// Drops "https://" and a bare trailing slash.
    static func pretty(_ url: URL?) -> String {
        guard var s = url?.absoluteString else { return "" }
        if s.hasPrefix("https://") { s.removeFirst(8) }
        if s.hasSuffix("/"), s.filter({ $0 == "/" }).count == 1 { s.removeLast() }
        return s
    }
}

/// Owns the tab list and selection, the shared WebKit configuration, and the app's local data.
@MainActor
final class TabStore: ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedID: Tab.ID?
    /// The selected tab's URL, published here so the single, long-lived address field can follow it without being rebuilt per tab.
    @Published private(set) var selectedURL: URL?
    @Published private(set) var lastRestoreMilliseconds: Int?
    @Published private(set) var addressFocusRequest = 0
    @Published var banner: PersistenceBanner? {
        didSet { if Self.bench { print(banner.map { "BANNER \($0.kind) \($0.message)" } ?? "BANNER cleared"); fflush(stdout) } }
    }
    @Published private(set) var backups: [BackupEntry] = []

    let settings = BrowserSettings()
    let history = History()
    let bookmarks = Bookmarks()
    let favicons = Favicons()
    let downloads = Downloads()
    let address = AddressModel()
    /// Security keys (YubiKey etc.): WebKit does not offer them to third-party browsers, so Feather speaks to the key itself.
    let webauthn = WebAuthnController()
    /// New versions: found and prepared by the app, installed by the helper in Contents/Library.
    private(set) lazy var updates = Updates(store: self)
    private(set) lazy var lifecycle = LifecycleManager(store: self)

    /// False until the app has finished launching. Creating WKWebViews inside SwiftUI's @StateObject init
    /// (before the scene exists) stops the window from ever appearing, so loading waits for this.
    private(set) var isReady = false
    private let configuration: WKWebViewConfiguration
    private var closedTabs: [ClosedTab] = []
    let sessions: SessionStore
    private var saveTask: Task<Void, Never>?
    private var saveDeadline = Date.distantFuture
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 3

    var selected: Tab? { tabs.first { $0.id == selectedID } }
    var liveCount: Int { tabs.filter(\.isLoaded).count }

    init() {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true      // YouTube fullscreen
        // Without a Safari token some sites (notably Google sign-in) treat WKWebView as an embedded browser.
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        // Tracks whether the user typed into a form field, so the lifecycle manager never unloads unsaved input.
        config.userContentController.addUserScript(WKUserScript(source: Self.dirtyTracker, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // WKWebView reports window.outerWidth/outerHeight as 0, where Safari reports the window size. Canvas-based apps
        // (Google Sheets and Docs) use it to choose their drawing resolution and fall back to a blurry 1x canvas when it is 0.
        config.userContentController.addUserScript(WKUserScript(source: Self.windowMetrics, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(WKUserScript(source: WebAuthnBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addScriptMessageHandler(WebAuthnBridge(controller: webauthn), contentWorld: .page, name: WebAuthnBridge.name)
        configuration = config

        // The profile lock comes first: a second Feather on the same profile must not write anything to it.
        sessions = SessionStore(directory: Storage.directory)
        if !Storage.acquireProfileLock() {
            Storage.readOnly = true
            sessions.enabled = false
            banner = .lockedOut
        }
        // `--snapshot-interval=SECONDS` shortens the backup interval (tests).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-interval=") }), let v = Double(arg.dropFirst(20)) { sessions.snapshotInterval = v }
        sessions.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } }

        // `--open=URL` (repeatable). A bare URL argument would make AppKit treat the launch as "open a document" and SwiftUI would skip creating the window.
        let launchURLs = CommandLine.arguments.filter { $0.hasPrefix("--open=") }.compactMap { URL(string: String($0.dropFirst(7))) }
        restoreSession()
        let external = Self.pendingExternal
        Self.pendingExternal = []
        if tabs.isEmpty && launchURLs.isEmpty && external.isEmpty { newTab() }
        launchURLs.forEach { newTab(url: $0) }
        // `--open-pinned=URL` (repeatable): open a pinned tab (used by tests).
        CommandLine.arguments.filter { $0.hasPrefix("--open-pinned=") }.compactMap { URL(string: String($0.dropFirst(14))) }
            .forEach { setPinned(newTab(url: $0), true) }
        external.forEach { openExternal($0) }
        Self.current = self
        if Self.bench { installBenchSignals() }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isReady = true
                self.updates.startAutomaticChecks()
                // Cookies from a profile import must be in place before any page loads, or the first loads would be signed out.
                if CookieImport.isPending { Task { await CookieImport.run(); self.finishLaunch() } } else { self.finishLaunch() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushAll() }
        }
        // Also save whenever the user leaves the app, so a crash while it's in the background loses nothing.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSessionNow(refreshStates: true) }
        }
        // Sleep, shutdown/restart and fast user switching are announced on the *workspace* notification center
        // (not NotificationCenter.default; subscribing there silently receives nothing). Flush synchronously, like at quit.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushAll() }
            }
        }
    }

    private func finishLaunch() {
        if CommandLine.arguments.contains("--load-all") { tabs.forEach { $0.ensureLoaded() } }     // benchmarks measure every launch URL as a live tab
        selected?.ensureLoaded()
        lifecycle.enforce()
        tabsChanged()
    }

    // MARK: Links opened from other apps (default browser)

    static weak var current: TabStore?
    static var pendingExternal: [URL] = []

    static func open(external url: URL) {
        guard ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let store = current { store.openExternal(url) } else { pendingExternal.append(url) }
    }

    func openExternal(_ url: URL) {
        // A lone blank tab (fresh launch) is reused instead of leaving an empty tab behind.
        if tabs.count == 1, let only = tabs.first, only.url == nil, !only.isLoaded { only.open(url); select(only.id) }
        else { newTab(url: url) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeWebView() -> WKWebView { WKWebView(frame: WebViewMetrics.initialFrame, configuration: configuration) }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true) -> Tab {
        let tab = Tab(url: url, store: self)
        tabs.append(tab)
        if select { self.select(tab.id) } else { tabsChanged() }
        if url == nil { focusAddress() }
        return tab
    }

    func openPopup(configuration: WKWebViewConfiguration, from opener: Tab, select: Bool = true) -> WKWebView {
        let webView = WKWebView(frame: WebViewMetrics.initialFrame, configuration: configuration)
        let tab = Tab(store: self)
        tab.attach(webView, restore: false)
        let pinnedCount = tabs.filter(\.isPinned).count
        tabs.insert(tab, at: max((tabs.firstIndex { $0 === opener } ?? tabs.count - 1) + 1, pinnedCount))   // never into the pinned group
        if select { self.select(tab.id) } else { tabsChanged() }
        return webView
    }

    func select(_ id: Tab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selected?.lastActive = Date()
        selectedID = id
        selectedURL = tab.url
        // Updated here, synchronously, not from a view's onChange: anything typed after this point must never be overwritten.
        address.text = AddressFormat.pretty(tab.url)
        tab.lastActive = Date()
        tab.ensureLoaded()
        lifecycle.enforce()
        tabsChanged()
    }

    func select(index: Int) {
        guard !tabs.isEmpty else { return }
        select(tabs[min(max(index, 0), tabs.count - 1)].id)
    }

    func selectNext(_ step: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == selectedID }), !tabs.isEmpty else { return }
        select(tabs[(i + step + tabs.count) % tabs.count].id)
    }

    func close(_ id: Tab.ID) {
        if let wv = tabs.first(where: { $0.id == id })?.webView { webauthn.cancel(webView: wv) }
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: i)
        if let closed = tab.close() {
            closedTabs.append(closed)
            if closedTabs.count > 10 { closedTabs.removeFirst() }
        }
        if selectedID == id {
            if tabs.isEmpty { newTab() } else { select(tabs[min(i, tabs.count - 1)].id) }
        } else {
            tabsChanged()
        }
    }

    func reopenClosed() {
        guard let closed = closedTabs.popLast() else { return }
        let tab = Tab(url: closed.url, title: closed.title, store: self)
        tab.savedState = closed.state
        tab.isPinned = closed.pinned
        tabs.insert(tab, at: closed.pinned ? tabs.filter(\.isPinned).count : tabs.count)
        select(tab.id)
    }

    // MARK: Pinning

    /// Pinned tabs form a group at the front of `tabs`, so tab order, Cmd+1-9 and next/previous follow what the sidebar shows.
    func setPinned(_ tab: Tab, _ pinned: Bool) {
        guard tab.isPinned != pinned, let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: i)
        tab.isPinned = pinned
        tabs.insert(tab, at: tabs.filter(\.isPinned).count)      // the tab is out of the array here: end of the pinned group / top of the rest
        tabsChanged()
    }

    func togglePin(_ tab: Tab) { setPinned(tab, !tab.isPinned) }

    /// Drag and drop: put `tab` before `target` (or at the end of the destination group when `target` is nil).
    /// Whether it ends up pinned is decided by where it was dropped, and the pinned-first order is always kept.
    func move(_ tab: Tab, before target: Tab?, pinned: Bool) {
        guard target !== tab, let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: from)
        tab.isPinned = pinned
        let pinnedCount = tabs.filter(\.isPinned).count          // the tab itself is out of the array here
        var index = target.flatMap { t in tabs.firstIndex { $0 === t } } ?? (pinned ? pinnedCount : tabs.count)
        index = pinned ? min(index, pinnedCount) : max(index, pinnedCount)
        tabs.insert(tab, at: index)
        tabsChanged()
    }

    func tabURLChanged(_ tab: Tab) {
        guard tab.id == selectedID else { return }
        selectedURL = tab.url
        if !AddressFocus.fieldHasFocus() { address.text = AddressFormat.pretty(tab.url) }     // never clobber what is being typed
    }

    func tab(withID id: UUID) -> Tab? { tabs.first { $0.id == id } }

    func focusAddress() {
        addressFocusRequest += 1
        AddressFocus.request()          // immediately, not after the next render, so keystrokes right after the shortcut land in the field
    }

    // MARK: Bookkeeping

    /// Tab list/selection/load state changed: refresh the UI and schedule a session save.
    func tabsChanged() {
        objectWillChange.send()
        sessionChanged(.structural)
    }

    enum SaveUrgency { case structural, incidental }

    /// Schedules a save. Opening, closing, pinning, moving or selecting a tab is saved within ~0.25 s; incidental
    /// changes (a page's address changing by itself) within ~1 s. Changes arriving while a save is pending don't
    /// postpone it, so a page that keeps changing can't starve saving, and the final state always lands because the
    /// session is read when the timer fires, not when it was scheduled.
    func sessionChanged(_ urgency: SaveUrgency = .incidental) {
        let delay: TimeInterval = urgency == .structural ? 0.25 : 1.0
        let deadline = Date().addingTimeInterval(delay)
        if saveTask != nil, saveDeadline <= deadline { return }
        saveTask?.cancel()
        saveDeadline = deadline
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            guard let self else { return }
            self.saveTask = nil
            self.saveDeadline = .distantFuture
            self.saveSessionNow()
        }
    }

    func noteRestore(milliseconds: Int) {
        lastRestoreMilliseconds = milliseconds
        if Self.bench { print("RESTORE_MS \(milliseconds)"); fflush(stdout) }
        Log.lifecycle.info("restored unloaded tab in \(milliseconds) ms")
    }

    // MARK: Benchmark hooks (`--bench`)
    // SIGUSR1: select the first unloaded tab and report how long it took to come back (RESTORE_MS).
    // SIGUSR2: print how many web views are live (LIVE n/m). Used by bench/bench.py; inert without --bench.

    static let bench = CommandLine.arguments.contains("--bench")
    private var signalSources: [DispatchSourceSignal] = []

    private func installBenchSignals() {
        func listen(_ sig: Int32, _ action: @escaping @MainActor (TabStore) -> Void) {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { if let self { action(self) } } }
            source.resume()
            signalSources.append(source)
        }
        listen(SIGUSR1) { store in
            if let tab = store.tabs.first(where: { !$0.isLoaded && $0.url != nil }) { store.select(tab.id) }
            else { print("RESTORE_NONE"); fflush(stdout) }
        }
        listen(SIGUSR2) { store in
            print("LIVE \(store.liveCount)/\(store.tabs.count)")
            for (i, t) in store.tabs.enumerated() {
                print("TAB \(i) \(t.isLoaded ? "live" : "unloaded") \(t.id == store.selectedID ? "selected" : "-") back=\(t.webView?.canGoBack ?? false) \(t.url?.absoluteString ?? "-") | \(t.title) | zoom=\(t.webView?.pageZoom ?? 0) | pinned=\(t.isPinned) icon=\(t.favicon != nil)")
            }
            fflush(stdout)
        }
    }

    // MARK: Persistence

    private static let maxStateBytes = 256_000      // skip pathological histories rather than bloat every save

    /// The session as it is right now. Page state (back/forward + scroll) comes from each tab's cache, and is
    /// refreshed only for tabs that navigated since (or for all of them when `refresh` is set: quit, sleep, leaving the app).
    private func makeSession(refresh: Bool) -> Session {
        let entries = tabs.map { tab -> SessionTab in
            if tab.isLoaded && (refresh || tab.stateDirty) { tab.refreshState() }
            var data = tab.sessionState
            if let d = data, d.count > Self.maxStateBytes { data = nil }
            return SessionTab(url: tab.url, title: tab.title, state: data, pinned: tab.isPinned ? true : nil)
        }
        return Session(tabs: entries,
                       selected: tabs.firstIndex { $0.id == selectedID } ?? 0,
                       closed: closedTabs.suffix(10).map { SavedClosed(url: $0.url, title: $0.title, pinned: $0.pinned ? true : nil) })
    }

    func saveSessionNow(refreshStates: Bool = false) {
        guard !tabs.isEmpty else { return }
        sessions.commitAsync(makeSession(refresh: refreshStates))
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .saved(let count):
            if Self.bench { print("PERSIST saved tabs=\(count)"); fflush(stdout) }
            if case .saveFailed = banner { banner = nil }          // the problem went away
            retryDelay = 3
        case .failed(let why):
            if Self.bench { print("PERSIST failed \(why)"); fflush(stdout) }
            banner = .saveFailed(why)
            scheduleRetry()
        case .backupsChanged(let list):
            backups = list
        }
    }

    /// After a failed save, try again with a growing delay (3 s, 6 s … at most 30 s). Nothing runs while saves succeed.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            self?.retryTask = nil
            self?.saveSessionNow(refreshStates: true)
        }
    }

    /// Restored tabs stay unloaded; only the selected one gets a web view, so launch cost doesn't scale with tab count.
    private func restoreSession() {
        backups = sessions.listBackups()
        let outcome = sessions.load()
        func report(_ source: String, _ tabs: Int, _ partial: Bool, _ quarantined: Int) {
            if Self.bench { print("SESSION source=\(source) tabs=\(tabs) partial=\(partial) quarantined=\(quarantined)"); fflush(stdout) }
        }
        switch outcome {
        case .fresh:
            report("fresh", 0, false, 0)
        case .unreadable(let quarantined):
            report("unreadable", 0, false, quarantined)
            if banner == nil { banner = .unreadable }
        case .loaded(let session, let source, let partial, let quarantined, _):
            tabs = session.tabs.map { saved in
                let tab = Tab(url: saved.url, title: saved.title, store: self)
                tab.savedState = saved.state
                tab.isPinned = saved.pinned ?? false
                return tab
            }
            tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
            closedTabs = (session.closed ?? []).map { ClosedTab(url: $0.url, title: $0.title, state: nil, pinned: $0.pinned ?? false) }
            select(index: session.selected)
            switch source {
            case .primary: report("primary", tabs.count, partial, quarantined)
            case .previous: report("previous", tabs.count, partial, quarantined)
            case .backup: report("backup", tabs.count, partial, quarantined)
            }
            if banner == nil {
                if partial { banner = .partialRestore }
                else if source == .previous { banner = .restoredFromBackup("Your last session file was damaged, so Feather restored the save before it. Nothing was lost beyond the last moments.") }
                else if case .backup(let date) = source {
                    banner = .restoredFromBackup("Your session file was damaged, so Feather restored the backup from \(BackupEntry(url: URL(fileURLWithPath: "/"), date: date, tabs: tabs.count, pinned: 0).menuTitle.components(separatedBy: " · ").first ?? "earlier").")
                }
            }
        }
    }

    /// Opens the tabs of a backup in this window. Nothing is replaced or closed: tabs already open (same address) are
    /// skipped, and pins are kept.
    func restoreBackup(_ entry: BackupEntry) {
        guard let data = try? Data(contentsOf: entry.url), let parsed = SessionParser.parse(data) else {
            banner = .info("That backup couldn’t be read.")
            return
        }
        let open = Set(tabs.compactMap { $0.url?.absoluteString })
        var added: [Tab] = [], skipped = 0
        for saved in parsed.session.tabs {
            guard let url = saved.url else { continue }
            if open.contains(url.absoluteString) { skipped += 1; continue }
            let tab = Tab(url: url, title: saved.title, store: self)
            tab.savedState = saved.state
            tab.isPinned = saved.pinned ?? false
            tabs.insert(tab, at: tab.isPinned ? tabs.filter(\.isPinned).count : tabs.count)
            added.append(tab)
        }
        if let first = added.first { select(first.id) }
        banner = .info("Opened \(added.count) tab\(added.count == 1 ? "" : "s") from the backup" + (skipped > 0 ? " (\(skipped) already open)." : "."))
        tabsChanged()
    }

    func dismissBanner() { banner = nil }

    /// Clears browsing history, and the saved icons of sites you visited, except those still open or bookmarked.
    func clearHistory() {
        history.clear()
        let open = tabs.compactMap { $0.url?.host } + bookmarks.items.compactMap { $0.url.host }
        favicons.prune(keeping: Set(open))
    }

    /// Quit, sleep, shutdown: refresh every tab's state and write synchronously.
    func flushAll() {
        saveTask?.cancel(); saveTask = nil
        retryTask?.cancel(); retryTask = nil
        if !tabs.isEmpty { sessions.commitSync(makeSession(refresh: true)) }
        history.flush()
        bookmarks.flush()
        Storage.drain()
    }

    /// Only replaces the values when the engine reports 0 (so a future WebKit that reports them properly is left alone).
    private static let windowMetrics = """
    (function () {
      function fix(name, fallback) {
        if (window[name] !== 0) return;
        try { Object.defineProperty(window, name, { get: fallback, set: function () {}, configurable: true }); } catch (e) {}
      }
      fix('outerWidth', function () { return window.innerWidth; });
      fix('outerHeight', function () { return window.innerHeight; });
    })();
    """

    // Typed-into-a-field detection. Search boxes and non-text inputs are ignored; a submit resets the flag.
    private static let dirtyTracker = """
    (function () {
      if (window.__featherDirty !== undefined) return;
      window.__featherDirty = false;
      addEventListener('input', function (e) {
        var t = e.target; if (!t) return;
        var n = (t.tagName || '').toLowerCase();
        if (n === 'textarea' || t.isContentEditable ||
            (n === 'input' && !/^(checkbox|radio|submit|button|range|color|hidden|search|file)$/i.test(t.type || 'text'))) {
          window.__featherDirty = true;
        }
      }, true);
      addEventListener('submit', function () { window.__featherDirty = false; }, true);
    })();
    """
}
