import Foundation

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
    /// The folder it is filed in (folders are one level deep and exist only as long as a bookmark is in them); nil = not in a folder.
    /// Optional, so bookmark files from before folders existed still load.
    var folder: String?
}

@MainActor
final class Bookmarks: ObservableObject {
    @Published private(set) var items: [Bookmark]

    private let fileName: String

    init(fileName: String = "bookmarks.json") {
        self.fileName = fileName
        items = Storage.load(fileName, as: [Bookmark].self) ?? [
            Bookmark(title: "Google", url: URL(string: "https://www.google.com")!),
            Bookmark(title: "YouTube", url: URL(string: "https://www.youtube.com")!),
            Bookmark(title: "Maps", url: URL(string: "https://www.google.com/maps")!),
            Bookmark(title: "Wikipedia", url: URL(string: "https://www.wikipedia.org")!),
        ]
    }

    func contains(_ url: URL?) -> Bool { url.map { u in items.contains { $0.url == u } } ?? false }

    func toggle(url: URL, title: String) {
        if let i = items.firstIndex(where: { $0.url == url }) { items.remove(at: i) }
        else { items.append(Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url)) }
        flush()
    }

    func remove(_ bookmark: Bookmark) {
        items.removeAll { $0.id == bookmark.id }
        flush()
    }

    func flush() { Storage.save(items, as: fileName, durability: .full, keepPrevious: true) }

    // MARK: Managing (the Bookmarks window)

    /// Folder names, alphabetical.
    var folders: [String] { Array(Set(items.compactMap(\.folder))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }

    func bookmarks(in folder: String?) -> [Bookmark] { items.filter { $0.folder == folder } }

    func update(_ id: UUID, title: String, url: URL, folder: String?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let name = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        items[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (url.host ?? url.absoluteString) : title
        items[i].url = url
        items[i].folder = (name?.isEmpty ?? true) ? nil : name
        flush()
    }

    func setFolder(_ ids: [UUID], to folder: String?) {
        let name = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        for i in items.indices where ids.contains(items[i].id) { items[i].folder = (name?.isEmpty ?? true) ? nil : name }
        flush()
    }

    func renameFolder(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        for i in items.indices where items[i].folder == old { items[i].folder = name }
        flush()
    }

    /// Dissolves a folder: its bookmarks stay, outside any folder.
    func dissolveFolder(_ name: String) { for i in items.indices where items[i].folder == name { items[i].folder = nil }; flush() }

    func remove(ids: [UUID]) { items.removeAll { ids.contains($0.id) }; flush() }

    /// Reorders within one folder (or among the unfiled bookmarks), as a list's drag-to-move reports it.
    func move(in folder: String?, from source: IndexSet, to destination: Int) {
        var group = bookmarks(in: folder)
        group.move(fromOffsets: source, toOffset: destination)
        var next = group.makeIterator()
        for i in items.indices where items[i].folder == folder { if let b = next.next() { items[i] = b } }     // the group's slots in `items` are refilled in the new order
        flush()
    }
}
