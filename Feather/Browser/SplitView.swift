import SwiftUI
import WebKit

/// Two tabs shown side by side in the one window. The pair is not saved with the session.
struct SplitPair: Equatable {
    var left: UUID
    var right: UUID
    func contains(_ id: UUID) -> Bool { id == left || id == right }
}

extension TabStore {
    /// Shows the current tab and `other` side by side. The tab you click is the active one (address bar, back and forward follow it).
    func openSplit(with other: Tab) {
        guard let current = selected, current !== other else { return }
        other.ensureLoaded()
        split = SplitPair(left: current.id, right: other.id)
        tabsChanged()
    }

    func closeSplit() {
        guard split != nil else { return }
        split = nil
        tabsChanged()
    }

    /// The two tabs, when a split is showing for the current selection.
    var splitTabs: (left: Tab, right: Tab)? {
        guard let s = split, let selectedID, s.contains(selectedID), let l = tab(withID: s.left), let r = tab(withID: s.right) else { return nil }
        return (l, r)
    }

    /// Both halves must stay loaded while the split is open.
    func isSplitMember(_ tab: Tab) -> Bool { split?.contains(tab.id) ?? false }
}

/// A click inside a pane makes that pane's tab the active one. (The page itself takes the click; this only watches.)
@MainActor
enum SplitFocus {
    private static var monitor: Any?

    static func install(_ store: TabStore) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak store] event in
            guard let store, store.split != nil, let window = event.window, window.title == "Feather",
                  var view = window.contentView?.hitTest(event.locationInWindow) else { return event }
            while !(view is WKWebView) { guard let up = view.superview else { return event }; view = up }
            if let tab = store.tabs.first(where: { $0.webView === view }), tab.id != store.selectedID, store.split?.contains(tab.id) == true {
                DispatchQueue.main.async { store.select(tab.id) }
            }
            return event
        }
    }
}
