import SwiftUI

struct BrowserCommands: Commands {
    @ObservedObject var store: TabStore
    @ObservedObject var history: History
    @ObservedObject var bookmarks: Bookmarks
    @ObservedObject var settings: BrowserSettings

    init(store: TabStore) {
        self.store = store
        _settings = ObservedObject(wrappedValue: store.settings)
        _history = ObservedObject(wrappedValue: store.history)
        _bookmarks = ObservedObject(wrappedValue: store.bookmarks)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await store.updates.check(userInitiated: true); store.updates.reportCheckResultInAlert() } }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.newTab() }.keyboardShortcut("t")
            Button("Open Location") { store.focusAddress() }.keyboardShortcut("l")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { if let id = store.selectedID { store.close(id) } }.keyboardShortcut("w")
            Button("Reopen Closed Tab") { store.reopenClosed() }.keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .sidebar) {
            Button(settings.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { Theme.animate { settings.sidebarVisible.toggle() } }
                .keyboardShortcut("s")
            Divider()
            Button("Zoom In") { store.selected?.zoom(step: 1) }.keyboardShortcut("=")
            Button("Zoom In (⌘+)") { store.selected?.zoom(step: 1) }.keyboardShortcut("+")
            Button("Zoom Out") { store.selected?.zoom(step: -1) }.keyboardShortcut("-")
            Button("Actual Size") { store.selected?.resetZoom() }.keyboardShortcut("0")
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { store.selected?.printPage() }.keyboardShortcut("p")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find in Page…") { store.selected?.showFind() }.keyboardShortcut("f")
            Button("Find Next") { store.selected?.find(forward: true) }.keyboardShortcut("g")
            Button("Find Previous") { store.selected?.find(forward: false) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandMenu("Navigate") {
            Button("Back") { store.selected?.goBack() }.keyboardShortcut("[")
            Button("Forward") { store.selected?.goForward() }.keyboardShortcut("]")
            Button("Reload / Stop") { store.selected?.reloadOrStop() }.keyboardShortcut("r")
            Button("Pin / Unpin Tab") { if let tab = store.selected { store.togglePin(tab) } }.keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Next Tab") { store.selectNext(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { store.selectNext(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab (Control-Tab)") { store.selectNext(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab (Control-Tab)") { store.selectNext(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Menu("Select Tab") {
                ForEach(1...9, id: \.self) { n in
                    Button(n == 9 ? "Last Tab" : "Tab \(n)") { store.select(index: n == 9 ? .max : n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                }
            }
        }
        CommandMenu("History") {
            ForEach(history.entries.prefix(15)) { entry in
                Button(entry.title.isEmpty ? entry.url : String(entry.title.prefix(60))) {
                    if let url = URL(string: entry.url) { open(url) }
                }
            }
            Divider()
            Menu("Restore Previous Session") {
                if store.backups.isEmpty {
                    Text("No backups yet")
                } else {
                    ForEach(store.backups) { backup in Button(backup.menuTitle) { store.restoreBackup(backup) } }
                }
                Divider()
                Button("Show Backups in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.sessions.backupsDirectory]) }
            }
            Button("Clear History") { store.clearHistory() }.disabled(history.entries.isEmpty)
        }
        CommandMenu("Bookmarks") {
            Button("Bookmark This Page") { toggleBookmark() }.keyboardShortcut("d")
            Divider()
            ForEach(bookmarks.items) { b in Button(b.title) { open(b.url) } }
        }
    }

    private func open(_ url: URL) {
        if let tab = store.selected { tab.open(url) } else { store.newTab(url: url) }
    }

    private func toggleBookmark() {
        guard let tab = store.selected, let url = tab.url else { return }
        bookmarks.toggle(url: url, title: tab.title)
    }
}
