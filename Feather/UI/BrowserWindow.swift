import SwiftUI

struct BrowserWindow: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var settings: BrowserSettings
    @FocusState private var addressFocused: Bool
    @State private var launched = false

    init(store: TabStore) {
        self.store = store
        _settings = ObservedObject(wrappedValue: store.settings)
    }

    var body: some View {
        let sidebar = settings.sidebarVisible
        ZStack {
            WindowMaterial()
            HStack(spacing: 0) {
                if sidebar {
                    Sidebar(store: store, focused: $addressFocused)
                        .frame(width: 240)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    if !sidebar {
                        TopBar(store: store, focused: $addressFocused)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let tab = store.selected { ContentArea(tab: tab, store: store) } else { Spacer() }
                }
                // With the sidebar showing, the page is a rounded card inset from the window edge.
                .clipShape(RoundedRectangle(cornerRadius: sidebar ? 10 : 0, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: sidebar ? 10 : 0, style: .continuous).strokeBorder(Color.primary.opacity(sidebar ? 0.12 : 0)))
                .padding(sidebar ? EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 8) : EdgeInsets())
            }
            .motion(Theme.spring, value: sidebar)
        }
        .overlay(alignment: .bottomTrailing) {
            DownloadBadge(downloads: store.downloads).padding(18)
        }
        .opacity(launched ? 1 : 0)
        .scaleEffect(launched ? 1 : 0.985)
        .ignoresSafeArea()
        .tint(Brand.accent)
        .background(WindowConfigurator())
        .onChange(of: store.addressFocusRequest) { _, _ in AddressFocus.request() }
        .onAppear {
            if store.selected?.url == nil { AddressFocus.request() }
            if Theme.reduceMotion { launched = true } else { withAnimation(.easeOut(duration: 0.4)) { launched = true } }
        }
    }
}

/// Puts keyboard focus in the address field and selects its text.
/// SwiftUI's FocusState races with the field being rebuilt for each new tab (it's keyed by tab id), which made focus
/// unreliable, so this finds the real NSTextField and retries until it actually is the first responder.
@MainActor
enum AddressFocus {
    /// SwiftUI does not propagate accessibilityIdentifier to the NSTextField, but it does set the placeholder.
    static let placeholder = "Search or enter address"

    private static var generation = 0

    /// Keeps trying (up to ~2 s) until the *same* field instance has held focus for 150 ms. Right after a new tab the
    /// lookup can still find the previous tab's field, which has focus but is about to be removed; counting that
    /// as success would leave the new field unfocused.
    static func request() {
        generation += 1
        attempt(generation: generation, step: 0, candidate: nil, since: Date())
    }

    private static func attempt(generation gen: Int, step: Int, candidate: NSTextField?, since: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (step == 0 ? 0 : 0.04)) {
            guard gen == generation, step < 50 else { return }                 // a newer request supersedes this one
            var candidate = candidate, since = since
            if let window = NSApp.windows.first(where: { $0.title == "Feather" }) ?? NSApp.keyWindow,
               let field = find(in: window.contentView) {
                if let editor = window.firstResponder as? NSTextView, editor.delegate === field {
                    if candidate === field {
                        if Date().timeIntervalSince(since) >= 0.15 {
                            field.currentEditor()?.selectAll(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { field.currentEditor()?.selectAll(nil) }
                            return
                        }
                    } else { candidate = field; since = Date() }
                } else {
                    candidate = nil
                    window.makeFirstResponder(field)
                }
            }
            attempt(generation: gen, step: step + 1, candidate: candidate, since: since)
        }
    }

    private static func find(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
        for sub in view.subviews { if let hit = find(in: sub) { return hit } }
        return nil
    }
}

/// Native sidebar material behind the whole window (cheap: the system stops blurring when the window is inactive).
private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Lets the window be dragged by its background (the title bar is hidden).
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hook() }
    func updateNSView(_ v: NSView, context: Context) {}
    private final class Hook: NSView {
        override func viewDidMoveToWindow() {
            window?.isMovableByWindowBackground = true
            window?.titlebarAppearsTransparent = true
        }
    }
}

// MARK: - Navigation

struct NavControls: View {
    @ObservedObject var store: TabStore
    var body: some View { if let tab = store.selected { Buttons(tab: tab) } }

    private struct Buttons: View {
        @ObservedObject var tab: Tab
        var body: some View {
            HStack(spacing: 2) {
                IconButton(symbol: "chevron.left", help: "Back", enabled: tab.canGoBack) { tab.goBack() }
                IconButton(symbol: "chevron.right", help: "Forward", enabled: tab.canGoForward) { tab.goForward() }
                IconButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", help: tab.isLoading ? "Stop" : "Reload", spins: !tab.isLoading) { tab.reloadOrStop() }
            }
        }
    }
}

struct AddressBar: View {
    @ObservedObject var store: TabStore
    var focused: FocusState<Bool>.Binding

    var body: some View {
        if let tab = store.selected {
            // Swapping the field per tab must be instant: a cross-fade would leave the old field in the window for a
            // moment, and focus would land on it instead of the new one.
            Field(tab: tab, bookmarks: store.bookmarks, focused: focused).id(tab.id).transition(.identity)
        }
    }

    private struct Field: View {
        @ObservedObject var tab: Tab
        @ObservedObject var bookmarks: Bookmarks
        var focused: FocusState<Bool>.Binding
        @State private var text = ""

        /// Magnifier while typing / on a blank tab; a lock for HTTPS; an open lock for plain HTTP.
        private var leadingSymbol: (name: String, tint: Color) {
            if focused.wrappedValue || tab.url == nil { return ("magnifyingglass", .secondary) }
            switch tab.url?.scheme {
            case "https": return ("lock.fill", .secondary)
            case "http": return ("lock.open.fill", .orange)
            default: return ("doc", .secondary)
            }
        }

        var body: some View {
            let isFocused = focused.wrappedValue
            let symbol = leadingSymbol
            HStack(spacing: 7) {
                Image(systemName: symbol.name)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(symbol.tint).frame(width: 14)
                    .contentTransition(.symbolEffect(.replace))
                TextField(AddressFocus.placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused(focused)
                    .autocorrectionDisabled()
                    .onSubmit { tab.go(to: text); focused.wrappedValue = false }
                if let url = tab.url {
                    let marked = bookmarks.contains(url)
                    Button { bookmarks.toggle(url: url, title: tab.title) } label: {
                        Image(systemName: marked ? "star.fill" : "star")
                            .foregroundStyle(marked ? Color.yellow : Color.secondary)
                            .font(.system(size: 12))
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, options: .nonRepeating, value: marked)
                    }
                    .buttonStyle(PressStyle(scale: 0.85)).help("Bookmark This Page")
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(isFocused ? 0.11 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Brand.accent.opacity(isFocused ? 0.85 : 0), lineWidth: 1.5))
            .shadow(color: Brand.accent.opacity(isFocused ? 0.28 : 0), radius: 7)
            .motion(Theme.fade, value: isFocused)
            .motion(Theme.quick, value: tab.url == nil)
            .onAppear { text = Self.pretty(tab.url) }
            .onChange(of: tab.url) { _, new in if !focused.wrappedValue { text = Self.pretty(new) } }
            .onChange(of: focused.wrappedValue) { _, isFocused in
                if isFocused {
                    text = tab.url?.absoluteString ?? ""
                    DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil) }
                } else {
                    text = Self.pretty(tab.url)
                }
            }
        }

        /// Unfocused display: drop "https://" and a bare trailing slash.
        static func pretty(_ url: URL?) -> String {
            guard var s = url?.absoluteString else { return "" }
            if s.hasPrefix("https://") { s.removeFirst(8) }
            if s.hasSuffix("/"), s.filter({ $0 == "/" }).count == 1 { s.removeLast() }
            return s
        }
    }
}

// MARK: - Content

private struct ContentArea: View {
    @ObservedObject var tab: Tab
    let store: TabStore

    var body: some View {
        ZStack {
            WebViewContainer(webView: tab.webView)
            if tab.webView == nil {
                StartPage(tab: tab, bookmarks: store.bookmarks, history: store.history, favicons: store.favicons)
                    .transition(.opacity)
            }
            if let failure = tab.failure { ErrorState(message: failure) { tab.reloadOrStop() }.transition(.opacity) }
        }
        .motion(Theme.fade, value: tab.webView == nil)
        .motion(Theme.fade, value: tab.failure)
        .overlay(alignment: .top) { LoadingBar(progress: tab.progress, visible: tab.isLoading) }
        .overlay(alignment: .topTrailing) {
            if tab.findVisible {
                FindBar(tab: tab).padding(10)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = tab.notice {
                Text(notice).font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
            }
        }
        .motion(Theme.spring, value: tab.findVisible)
        .motion(Theme.spring, value: tab.notice)
    }
}

private struct FindBar: View {
    @ObservedObject var tab: Tab
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in page", text: $tab.findQuery)
                .textFieldStyle(.plain).frame(width: 180).focused($focused)
                .onSubmit { tab.find(forward: true) }
            if tab.findNoMatch && !tab.findQuery.isEmpty {
                Text("No matches").font(.caption).foregroundStyle(.secondary).transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            IconButton(symbol: "chevron.up", help: "Previous") { tab.find(forward: false) }
            IconButton(symbol: "chevron.down", help: "Next") { tab.find(forward: true) }
            Button("Done") { tab.closeFind() }.buttonStyle(PressStyle()).font(.callout).foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
        .motion(Theme.quick, value: tab.findNoMatch)
        .onAppear { focused = true }
        .onChange(of: tab.findFocusToken) { _, _ in focused = true }
        .onChange(of: tab.findQuery) { _, _ in tab.find(forward: true) }
        .onExitCommand { tab.closeFind() }
    }
}

/// Thin progress line along the top of the page. It eases forward and fades out when loading ends.
private struct LoadingBar: View {
    let progress: Double
    let visible: Bool
    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(LinearGradient(colors: [Brand.accent.opacity(0.5), Brand.accent], startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width * max(progress, 0.05), height: 2.5)
                .animation(Theme.animation(.easeOut(duration: 0.3)), value: progress)
        }
        .frame(height: 2.5)
        .opacity(visible ? 1 : 0)
        .animation(Theme.animation(.easeOut(duration: 0.4)), value: visible)
        .allowsHitTesting(false)
    }
}

private struct ErrorState: View {
    let message: String
    let retry: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34)).foregroundStyle(Brand.accent)
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
            Text("Can’t open this page").font(.system(size: 17, weight: .semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(action: retry) {
                Text("Try Again").font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Capsule().fill(Brand.accent.opacity(0.22)))
            }
            .buttonStyle(PressStyle()).hoverFill(radius: 16, strength: 0.06).padding(.top, 4)
        }
        .reveal()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { appeared = true }
    }
}
