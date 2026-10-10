import SwiftUI
import WebKit

/// One tab. Its identity and metadata (URL, title, favicon, saved navigation state) always exist;
/// the WKWebView exists only while the tab is "live" and is dropped by `unload()` / `close()`.
@MainActor
final class Tab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    weak var store: TabStore?

    @Published private(set) var url: URL? { didSet { store?.tabURLChanged(self) } }
    @Published private(set) var title: String
    @Published private(set) var favicon: NSImage?
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var isPinned = false                      // pinned tabs live in the sidebar's icon grid and sort first
    @Published private(set) var failure: String?
    @Published private(set) var notice: String?          // brief, non-blocking message (e.g. "page reloaded")
    @Published var findVisible = false                   // find-in-page bar
    @Published var findQuery = ""
    @Published private(set) var findNoMatch = false
    @Published private(set) var findFocusToken = 0
    @Published private(set) var webView: WKWebView?

    var lastActive = Date()
    /// WKWebView.interactionState captured when unloaded: restores back/forward list and scroll position.
    var savedState: Any?
    /// The last known serialized state of the live page, kept so a session save doesn't have to ask the web view every time.
    var cachedState: Data?
    var stateDirty = true            // the page navigated since cachedState was taken

    private var observations: [NSKeyValueObservation] = []
    private var restoreStart: CFAbsoluteTime?
    private var gotInitialFocus = false
    private var lastCrash: Date?
    private var wasUnloaded = false      // only a return from unloading counts as a "restore" for timing

    var isLoaded: Bool { webView != nil }
    var displayTitle: String { title.isEmpty ? (url?.host ?? "Start Page") : title }

    init(url: URL? = nil, title: String = "", store: TabStore) {
        self.url = url
        self.title = title
        self.store = store
        super.init()
        // A restored tab hasn't loaded, but its site's icon was saved last time: show it right away.
        if let host = url?.host { favicon = store.favicons.cached(host: host) }
    }

    // MARK: Lifecycle

    /// Creates the web view if this tab has something to show. Blank tabs stay web-view-free.
    func ensureLoaded() {
        guard webView == nil, let store, store.isReady, url != nil || savedState != nil else { return }
        attach(store.makeWebView(), restore: true)
    }

    func attach(_ wv: WKWebView, restore: Bool) {
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        webView = wv
        observe(wv)
        if restore {
            if wasUnloaded { restoreStart = CFAbsoluteTimeGetCurrent() }
            if let state = savedState {
                wv.interactionState = state
                if !wv.isLoading, let url { load(url, in: wv) }   // state was rejected
            } else if let url {
                load(url, in: wv)
            }
            if let data = savedState as? Data { cachedState = data }
            savedState = nil
        }
        store?.tabsChanged()
    }

    /// What goes into the session file for this tab: the freshest known state, live or saved.
    var sessionState: Data? { cachedState ?? (savedState as? Data) }

    /// Asks the live page for its back/forward + scroll state (cheap, but not free, so it is only done when needed).
    func refreshState() {
        guard let wv = webView, wv.url != nil else { return }
        cachedState = wv.interactionState as? Data
        stateDirty = false
    }

    /// Releases the web view (and with it the page's memory) but keeps everything needed to bring it back.
    func unload() {
        guard let wv = webView else { return }
        let state = wv.interactionState
        savedState = state
        cachedState = state as? Data
        stateDirty = false
        wasUnloaded = true
        if let u = wv.url { url = u }
        if let t = wv.title, !t.isEmpty { title = t }
        detach()
        store?.tabsChanged()
    }

    /// Final teardown; returns what's needed to reopen the tab later.
    func close() -> ClosedTab? {
        let state = webView?.interactionState ?? savedState
        if let wv = webView {
            if let u = wv.url { url = u }
            if let t = wv.title, !t.isEmpty { title = t }
        }
        detach()
        savedState = nil
        guard let url else { return nil }
        return ClosedTab(url: url, title: title, state: state, pinned: isPinned)
    }

    private func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
        guard let wv = webView else { return }
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        wv.removeFromSuperview()
        webView = nil
        isLoading = false
        progress = 0
        canGoBack = false
        canGoForward = false
    }

    private func observe(_ wv: WKWebView) {
        // Weak self: observers must never keep a closed tab alive.
        observations = [
            // pushState/hash navigations only change `url` (no commit), so a URL change schedules a session save. Title changes
            // deliberately do not (flashing titles / unread counters would mean constant disk writes); titles are captured by the next save.
            wv.observe(\.url, options: .new) { [weak self] wv, _ in MainActor.assumeIsolated { if let u = wv.url { self?.url = u; self?.stateDirty = true; self?.store?.sessionChanged() } } },
            wv.observe(\.title, options: .new) { [weak self] wv, _ in MainActor.assumeIsolated { if let t = wv.title, !t.isEmpty { self?.title = t } } },
            wv.observe(\.isLoading, options: .new) { [weak self] wv, _ in MainActor.assumeIsolated { self?.isLoading = wv.isLoading } },
            wv.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in MainActor.assumeIsolated { self?.progress = wv.estimatedProgress } },
            wv.observe(\.canGoBack, options: .new) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack } },
            wv.observe(\.canGoForward, options: .new) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward } },
        ]
    }

    // MARK: Navigation

    func go(to input: String) {
        guard let url = AddressResolver.resolve(input) else { return }
        open(url)
        // The web view may not be in the window yet for a blank tab; give SwiftUI a beat to attach it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.focusContent() }
    }

    func open(_ url: URL) {
        failure = nil
        if let wv = webView {
            load(url, in: wv)
        } else {
            savedState = nil
            title = ""
            self.url = url
            ensureLoaded()
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reloadOrStop() {
        guard let wv = webView else { ensureLoaded(); return }
        if wv.isLoading { wv.stopLoading() }
        else if wv.url != nil { wv.reload() }
        else if let url { load(url, in: wv) }
    }

    /// Local files need an explicit read grant for their folder; everything else is a normal request.
    private func load(_ url: URL, in wv: WKWebView) {
        if url.isFileURL { wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { wv.load(URLRequest(url: url)) }
    }

    // MARK: Find in page, zoom, print

    func showFind() { findVisible = true; findFocusToken += 1 }

    func find(forward: Bool = true) {
        guard let wv = webView, !findQuery.isEmpty else { findNoMatch = false; return }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.wraps = true
        config.caseSensitive = false
        wv.find(findQuery, configuration: config) { [weak self] result in self?.findNoMatch = !result.matchFound }
    }

    func closeFind() {
        findVisible = false
        findNoMatch = false
        webView?.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
        focusContent()
    }

    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// Remembered per site, like Safari.
    func zoom(step: Int) {
        guard let wv = webView else { return }
        let current = Self.zoomSteps.enumerated().min { abs($0.element - wv.pageZoom) < abs($1.element - wv.pageZoom) }?.offset ?? 4
        setZoom(Self.zoomSteps[min(max(current + step, 0), Self.zoomSteps.count - 1)])
    }

    func resetZoom() { setZoom(1.0) }

    private func setZoom(_ value: CGFloat) {
        guard let wv = webView else { return }
        wv.pageZoom = value
        if let host = wv.url?.host { store?.settings.setZoom(Double(value), for: host) }
        flash("\(Int((value * 100).rounded()))%")
    }

    private func flash(_ text: String) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.notice == text { self?.notice = nil }
        }
    }

    func printPage() {
        guard let wv = webView, let window = wv.window else { return }
        let op = wv.printOperation(with: NSPrintInfo.shared.copy() as! NSPrintInfo)
        op.view?.frame = wv.bounds                      // without a frame WKWebView prints a blank page
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func focusContent() { if let wv = webView { wv.window?.makeFirstResponder(wv) } }
}

struct ClosedTab {
    let url: URL
    let title: String
    let state: Any?
    var pinned = false
}

// MARK: - WKNavigationDelegate

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "file", "blob", "data", "javascript"].contains(scheme) {
            // Only hand a few well-known schemes to other apps, and only for a real click.
            if navigationAction.navigationType == .linkActivated, ["mailto", "tel", "sms", "facetime"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    /// Files the browser can't display, and "Content-Disposition: attachment", become downloads.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
        decisionHandler(disposition?.hasPrefix("attachment") == true || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = store?.downloads }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = store?.downloads }

    /// WebKit killed or lost this page's process (crash, or reclaimed under memory pressure). Without this the tab stays blank.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.lifecycle.error("web content process ended for \(self.url?.host ?? "-")")
        if TabStore.bench { print("WEBCONTENT_TERMINATED \(store?.selectedID == id ? "selected" : "background")"); fflush(stdout) }
        guard store?.selectedID == id else { unload(); return }          // background tab: comes back when selected
        if let last = lastCrash, Date().timeIntervalSince(last) < 15 {
            failure = "This page keeps stopping unexpectedly."          // don't loop on a page that crashes every time
            return
        }
        lastCrash = Date()
        notice = "The page stopped unexpectedly and was reloaded."
        if webView.url != nil { webView.reload() } else if let url { webView.load(URLRequest(url: url)) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.notice = nil
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { failure = nil }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let host = webView.url?.host {
            favicon = store?.favicons.cached(host: host)
            webView.pageZoom = CGFloat(store?.settings.zoom(for: host) ?? 1.0)
        }
        stateDirty = true
        store?.tabsChanged()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        stateDirty = true
        store?.sessionChanged()
        if let start = restoreStart {
            restoreStart = nil
            store?.noteRestore(milliseconds: Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
        }
        guard let url = webView.url else { return }
        // The first page to finish loading in the selected tab gets keyboard focus (unless you're typing in the address bar).
        if !gotInitialFocus {
            gotInitialFocus = true
            if store?.selectedID == id && !AddressFocus.fieldHasFocus() { focusContent() }
        }
        store?.history.record(url: url, title: webView.title ?? "")
        // A background tab that was still loading was exempt from unloading; now that it's done, re-check.
        if store?.selectedID != id { store?.lifecycle.enforce() }
        // The Tab and web view are held strongly only while the JS call runs, never during the download,
        // so closing a tab mid-fetch can't keep it alive.
        Task { [weak self, weak webView] in
            guard let favicons = self?.store?.favicons, let webView, let page = webView.url else { return }
            let declared = await favicons.declaredHref(in: webView)
            guard let icon = await favicons.icon(page: page, declared: declared) else { return }
            self?.favicon = icon
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }

    /// Default TLS validation is untouched: bad certificates arrive here as errors, never as silent bypasses.
    private func report(_ error: Error) {
        restoreStart = nil
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }   // frame load interrupted (download/plug-in)
        if let failed = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL { url = failed }
        failure = ns.localizedDescription
    }
}

// MARK: - WKUIDelegate

extension Tab: WKUIDelegate {
    /// window.open / target=_blank: the returned web view must be built from the supplied configuration.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let background = navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2
        return store?.openPopup(configuration: configuration, from: self, select: !background)
    }

    func webViewDidClose(_ webView: WKWebView) { store?.close(id) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page asks"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page asks"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}
