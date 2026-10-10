import Foundation

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
}

@MainActor
final class Bookmarks: ObservableObject {
    @Published private(set) var items: [Bookmark]

    init() {
        items = Storage.load("bookmarks.json", as: [Bookmark].self) ?? [
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

    func flush() { Storage.save(items, as: "bookmarks.json", durability: .full, keepPrevious: true) }
}
