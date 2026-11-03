import SwiftUI

enum LibraryPane: String, CaseIterable, Identifiable {
    case bookmarks = "Bookmarks", history = "History"
    var id: String { rawValue }
}

extension TabStore {
    /// Shows a page: switches to a tab that already has it, or opens a new one (and brings the browser window forward).
    func openPage(_ url: URL, inNewTab: Bool = false) {
        if !inNewTab, let open = tabs.first(where: { $0.url == url }) { select(open.id) } else { newTab(url: url) }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "Feather" }?.makeKeyAndOrderFront(nil)
    }
}

/// The "Bookmarks and History" window: look through, search, organise and clean up what Feather has saved.
struct LibraryView: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var bookmarks: Bookmarks
    @ObservedObject private var history: History
    @State private var query = ""

    init(store: TabStore) {
        self.store = store
        _bookmarks = ObservedObject(wrappedValue: store.bookmarks)
        _history = ObservedObject(wrappedValue: store.history)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $store.libraryPane) { ForEach(LibraryPane.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
                if store.libraryPane == .history { ClearHistoryMenu(store: store) }
            }
            .padding(12)
            Divider()
            switch store.libraryPane {
            case .bookmarks: BookmarksPane(store: store, bookmarks: bookmarks, query: query)
            case .history: HistoryPane(store: store, history: history, query: query)
            }
        }
        .tint(Brand.accent)
        .frame(minWidth: 560, minHeight: 420)
    }
}

/// Every word of the query must appear in the title or the address.
private func matches(_ query: String, _ title: String, _ url: String) -> Bool {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return true }
    let t = title.lowercased(), u = url.lowercased()
    return words.allSatisfy { t.contains($0) || u.contains($0) }
}

// MARK: - Bookmarks

private struct BookmarksPane: View {
    let store: TabStore
    @ObservedObject var bookmarks: Bookmarks
    let query: String
    @State private var selection = Set<UUID>()
    @State private var editing: Bookmark?
    @State private var folderFor: [UUID]?

    private func shown(_ folder: String?) -> [Bookmark] { bookmarks.bookmarks(in: folder).filter { matches(query, $0.title, $0.url.absoluteString) } }

    var body: some View {
        let unfiled = shown(nil)
        List(selection: $selection) {
            if !unfiled.isEmpty { Section("Bookmarks") { rows(unfiled, folder: nil) } }
            ForEach(bookmarks.folders, id: \.self) { folder in
                let inside = shown(folder)
                if !inside.isEmpty {
                    Section {
                        rows(inside, folder: folder)
                    } header: {
                        HStack {
                            Label(folder, systemImage: "folder")
                            Spacer()
                            Menu {
                                Button("Rename Folder…") { renameFolder(folder) }
                                Button("Dissolve Folder (keep bookmarks)") { bookmarks.dissolveFolder(folder) }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
            }
        }
        .overlay {
            if bookmarks.items.isEmpty { empty("No bookmarks yet", "Press ⌘D on a page to bookmark it.") }
            else if unfiled.isEmpty && bookmarks.folders.allSatisfy({ shown($0).isEmpty }) { empty("No matches", "Nothing in your bookmarks matches “\(query)”.") }
        }
        .onDeleteCommand { bookmarks.remove(ids: Array(selection)); selection = [] }
        .contextMenu(forSelectionType: UUID.self) { ids in menu(ids) } primaryAction: { ids in
            for url in ids.compactMap({ id in bookmarks.items.first { $0.id == id }?.url }).prefix(1) { store.openPage(url) }
        }
        .sheet(item: $editing) { EditBookmarkSheet(bookmarks: bookmarks, bookmark: $0) }
        .sheet(item: Binding(get: { folderFor.map { FolderTarget(ids: $0) } }, set: { if $0 == nil { folderFor = nil } })) { target in
            NewFolderSheet(ids: target.ids, bookmarks: bookmarks)
        }
    }

    private func rows(_ list: [Bookmark], folder: String?) -> some View {
        ForEach(list) { b in
            VStack(alignment: .leading, spacing: 2) {
                Text(b.title).lineLimit(1)
                Text(b.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.vertical, 2)
        }
        .onMove(perform: query.isEmpty ? { from, to in bookmarks.move(in: folder, from: from, to: to) } : nil)       // not while the list is filtered: positions would not match
        .onDelete { offsets in bookmarks.remove(ids: offsets.map { list[$0].id }) }
    }

    @ViewBuilder private func menu(_ ids: Set<UUID>) -> some View {
        let picked = bookmarks.items.filter { ids.contains($0.id) }
        if !picked.isEmpty {
            Button("Open") { picked.forEach { store.openPage($0.url) } }
            Button("Open in New Tab") { picked.forEach { store.openPage($0.url, inNewTab: true) } }
            Divider()
            if picked.count == 1, let one = picked.first { Button("Edit…") { editing = one } }
            Menu("Move to Folder") {
                Button("New Folder…") { folderFor = picked.map(\.id) }
                if !bookmarks.folders.isEmpty { Divider() }
                ForEach(bookmarks.folders, id: \.self) { f in Button(f) { bookmarks.setFolder(picked.map(\.id), to: f) } }
                if picked.contains(where: { $0.folder != nil }) { Divider(); Button("No Folder") { bookmarks.setFolder(picked.map(\.id), to: nil) } }
            }
            Divider()
            Button("Delete") { bookmarks.remove(ids: picked.map(\.id)); selection = [] }
        }
    }

    private func renameFolder(_ folder: String) {
        let alert = NSAlert()
        alert.messageText = "Rename folder"
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); field.stringValue = folder
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn { bookmarks.renameFolder(folder, to: field.stringValue) }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) { Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary) }
    }
}

private struct FolderTarget: Identifiable { let ids: [UUID]; var id: String { ids.map(\.uuidString).joined() } }

private struct EditBookmarkSheet: View {
    let bookmarks: Bookmarks
    let bookmark: Bookmark
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var address = ""
    @State private var folder = ""

    private var url: URL? { AddressResolver.resolve(address).flatMap { $0.scheme == "http" || $0.scheme == "https" ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Bookmark").font(.headline)
            TextField("Title", text: $title)
            TextField("Address", text: $address)
            TextField("Folder (optional)", text: $folder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { if let url { bookmarks.update(bookmark.id, title: title, url: url, folder: folder); dismiss() } }
                    .keyboardShortcut(.defaultAction).disabled(url == nil)
            }
        }
        .textFieldStyle(.roundedBorder).padding(18).frame(width: 380)
        .onAppear { title = bookmark.title; address = bookmark.url.absoluteString; folder = bookmark.folder ?? "" }
    }
}

private struct NewFolderSheet: View {
    let ids: [UUID]
    let bookmarks: Bookmarks
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Folder").font(.headline)
            TextField("Folder name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18).frame(width: 320)
    }
    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        bookmarks.setFolder(ids, to: name); dismiss()
    }
}

// MARK: - History

private struct HistoryPane: View {
    let store: TabStore
    @ObservedObject var history: History
    let query: String
    @State private var selection = Set<String>()

    var body: some View {
        let list = history.entries.filter { matches(query, $0.title, $0.url) }.prefix(1500)
        let sections = HistoryGrouping.sections(Array(list))
        List(selection: $selection) {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.entries) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(e.lastVisit, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title.isEmpty ? (URL(string: e.url)?.host ?? e.url) : e.title).lineLimit(1)
                                Text(e.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .overlay {
            if history.entries.isEmpty { VStack(spacing: 6) { Text("No history").font(.headline); Text("Pages you visit appear here. They stay on this Mac.").font(.callout).foregroundStyle(.secondary) } }
            else if sections.isEmpty { VStack(spacing: 6) { Text("No matches").font(.headline); Text("Nothing in your history matches “\(query)”.").font(.callout).foregroundStyle(.secondary) } }
        }
        .onDeleteCommand { history.remove(ids: selection); selection = [] }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button("Open") { ids.compactMap { URL(string: $0) }.forEach { store.openPage($0) } }
                Button("Open in New Tab") { ids.compactMap { URL(string: $0) }.forEach { store.openPage($0, inNewTab: true) } }
                Divider()
                Button("Delete from History") { history.remove(ids: ids); selection = [] }
            }
        } primaryAction: { ids in
            if let url = ids.first.flatMap({ URL(string: $0) }) { store.openPage(url) }
        }
    }
}

private struct ClearHistoryMenu: View {
    let store: TabStore
    @State private var confirmAll = false

    var body: some View {
        Menu("Clear…") {
            Button("Last Hour") { store.history.clear(since: Date().addingTimeInterval(-3600)) }
            Button("Today") { store.history.clear(since: Calendar.current.startOfDay(for: Date())) }
            Button("All History…") { confirmAll = true }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .confirmationDialog("Clear all history?", isPresented: $confirmAll) {
            Button("Clear All History", role: .destructive) { store.clearHistory() }
        } message: { Text("This also removes the saved icons of sites you no longer have open or bookmarked.") }
    }
}
