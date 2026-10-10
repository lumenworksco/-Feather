import SwiftUI

struct BrowserWindow: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var settings: BrowserSettings
    @FocusState private var addressFocused: Bool
    @State private var launched = false
    @State private var fullScreen = false

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
        .overlay(alignment: .top) {
            // Over the whole window, not inside the sidebar: it must be visible with the sidebar hidden too.
            ZStack {
                if let banner = store.banner {
                    PersistenceBannerView(banner: banner, store: store)
                        .padding(.top, 46).padding(.horizontal, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .motion(Theme.spring, value: store.banner)
        }
        .opacity(launched ? 1 : 0)
        .scaleEffect(launched ? 1 : 0.985)
        .ignoresSafeArea()
        .tint(Brand.accent)
        .background(WindowConfigurator())
        .environment(\.trafficLightInset, fullScreen ? 14 : 78)
        .motion(Theme.spring, value: fullScreen)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
        .onChange(of: store.addressFocusRequest) { _, _ in AddressFocus.request() }
        .onAppear {
            AddressFocus.installClickSelectsAll()
            if store.selected?.url == nil { AddressFocus.request() }
            else {
                // macOS hands the first text field initial focus; with a page open, keystrokes belong to the page
                // (Space should scroll, typing should not replace the URL).
                for delay in [0.05, 0.3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if AddressFocus.fieldHasFocus() { NSApp.windows.first { $0.title == "Feather" }?.makeFirstResponder(nil) }
                    }
                }
            }
            if Theme.reduceMotion { launched = true } else { withAnimation(.easeOut(duration: 0.4)) { launched = true } }
        }
    }
}

/// "Your tabs were restored from a backup", "Feather couldn't save your tabs", and the like.
private struct PersistenceBannerView: View {
    let banner: PersistenceBanner
    @ObservedObject var store: TabStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.isWarning ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                .foregroundStyle(banner.isWarning ? Color.orange : Brand.accent).font(.system(size: 14)).padding(.top, 1)
            Text(banner.message).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            switch banner {
            case .saveFailed, .lockedOut, .info: EmptyView()
            default:
                Button("Show Files") { NSWorkspace.shared.activateFileViewerSelecting([store.sessions.directory]) }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Brand.accent)
            }
            Button { store.dismissBanner() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(PressStyle(scale: 0.88)).foregroundStyle(.secondary).padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder((banner.isWarning ? Color.orange : Color.primary).opacity(banner.isWarning ? 0.45 : 0.10)))
    }
}

private struct TrafficLightInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 78 }
extension EnvironmentValues {
    /// Space the top row leaves for the window's traffic lights (they are hidden in full screen).
    var trafficLightInset: CGFloat {
        get { self[TrafficLightInsetKey.self] }
        set { self[TrafficLightInsetKey.self] = newValue }
    }
}

/// Puts keyboard focus in the address field and selects its text.
/// The field lives for the whole window (it is not rebuilt per tab), so there is never a moment after ⌘T without a field
/// to type into. This goes through AppKit rather than SwiftUI's FocusState, which proved unreliable here, and retries
/// briefly in case the field is still being laid out (launch, sidebar/top-bar swap).
@MainActor
enum AddressFocus {
    /// SwiftUI does not propagate accessibilityIdentifier to the NSTextField, but it does set the placeholder.
    static let placeholder = "Search or enter address"

    private static var generation = 0
    #if DEBUG
    static var trace: [String] = []         // what each focus attempt saw (printed by the self-test when a focus check fails)
    #endif

    static func request() {
        #if DEBUG
        trace = []
        #endif
        generation += 1
        attempt(generation: generation, step: 0)
    }

    /// True while the address field is the active text field (the user is editing it).
    static func fieldHasFocus() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == "Feather" }), let field = find(in: window.contentView),
              let editor = window.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    private static func attempt(generation gen: Int, step: Int) {
        // The first attempt runs immediately (the field already exists), so focus is in place before the next keystroke.
        let work = {
            guard gen == generation, step < 60 else { return }                  // a newer request supersedes this one
            #if DEBUG
            if step < 4 || step % 20 == 0 {
                let w = NSApp.windows.first(where: { $0.title == "Feather" })
                trace.append("step \(step): window=\(w != nil) field=\(find(in: w?.contentView) != nil) responder=\(type(of: w?.firstResponder as Any)) keyWindow=\(w?.isKeyWindow ?? false)")
            }
            #endif
            if let window = NSApp.windows.first(where: { $0.title == "Feather" }) ?? NSApp.keyWindow,
               let field = find(in: window.contentView) {
                // Select-all happens only here, at the moment focus arrives; a later select-all could swallow letters you
                // have already typed. (The field swaps in the full address itself, and selects it, when it gains focus.)
                if let editor = window.firstResponder as? NSTextView, editor.delegate === field { editor.selectAll(nil); return }
                window.makeFirstResponder(field)
                if let editor = window.firstResponder as? NSTextView, editor.delegate === field { editor.selectAll(nil); return }
            }
            attempt(generation: gen, step: step + 1)
        }
        if step == 0 { work() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work) }
    }

    // MARK: Click selects everything (like Safari and Chrome)

    private static var clickMonitor: Any?
    private static var pendingClick: NSPoint?
    private static var lastKeyTime = Date.distantPast

    /// A click into the address field while it is NOT focused selects its whole text once the click has finished, so you
    /// can click and type over the old address. A click while it is already focused places the caret as usual, and
    /// a drag still selects just what you dragged over. (The select-all has to wait for the mouse-up: the click itself
    /// places a caret after focus arrives, which would otherwise undo it.)
    static func installClickSelectsAll() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { event in
            switch event.type {
            case .keyDown:
                lastKeyTime = Date()
            case .leftMouseDown:
                pendingClick = nil
                if let window = event.window, window.title == "Feather", !fieldHasFocus(),
                   let field = find(in: window.contentView), let hit = window.contentView?.hitTest(event.locationInWindow), contains(field, hit) {
                    pendingClick = event.locationInWindow
                }
            case .leftMouseUp:
                guard let down = pendingClick else { break }
                pendingClick = nil
                guard hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) < 4 else { break }      // a drag: leave its selection alone
                let clickTime = Date()
                // Twice: right after the click, and again after SwiftUI has swapped the full address into the field.
                for delay in [0.03, 0.16] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if lastKeyTime < clickTime, fieldHasFocus(),
                           let editor = NSApp.windows.first(where: { $0.title == "Feather" })?.firstResponder as? NSTextView { editor.selectAll(nil) }
                    }
                }
            default: break
            }
            return event
        }
    }

    private static func contains(_ field: NSView, _ view: NSView) -> Bool {
        var v: NSView? = view
        while let current = v { if current === field { return true }; v = current.superview }
        return false
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

/// The address field: ONE view for the whole window. Its text lives in `store.address`, which the store updates
/// synchronously when the tab changes.
struct AddressBar: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var bookmarks: Bookmarks
    @ObservedObject private var address: AddressModel
    var focused: FocusState<Bool>.Binding

    init(store: TabStore, focused: FocusState<Bool>.Binding) {
        self.store = store
        self.focused = focused
        _bookmarks = ObservedObject(wrappedValue: store.bookmarks)
        _address = ObservedObject(wrappedValue: store.address)
    }

    /// Magnifier while typing / on a blank tab; a lock for HTTPS; an open lock for plain HTTP.
    private var leadingSymbol: (name: String, tint: Color) {
        if focused.wrappedValue || store.selectedURL == nil { return ("magnifyingglass", .secondary) }
        switch store.selectedURL?.scheme {
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
            TextField(AddressFocus.placeholder, text: $address.text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focused)
                .autocorrectionDisabled()
                .onSubmit { store.selected?.go(to: address.text); focused.wrappedValue = false }
                .onExitCommand {                       // Escape: forget what was typed and go back to the page
                    address.text = AddressFormat.pretty(store.selectedURL)
                    focused.wrappedValue = false
                    DispatchQueue.main.async { store.selected?.focusContent() }           // after SwiftUI has resigned the field
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { store.selected?.focusContent() }
                }
            if let url = store.selectedURL {
                let marked = bookmarks.contains(url)
                Button { bookmarks.toggle(url: url, title: store.selected?.title ?? "") } label: {
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
        .motion(Theme.quick, value: store.selectedURL == nil)
        .onChange(of: focused.wrappedValue) { _, nowFocused in
            if nowFocused {
                // Show the full address for editing and select it, but only if the text is still the untouched display
                // text: anything already typed (fast typing right after the shortcut) must survive, unselected.
                if address.text == AddressFormat.pretty(store.selectedURL) {
                    address.text = store.selectedURL?.absoluteString ?? ""
                    DispatchQueue.main.async {
                        if address.text == store.selectedURL?.absoluteString ?? "" { (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil) }
                    }
                }
            } else {
                address.text = AddressFormat.pretty(store.selectedURL)
            }
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
