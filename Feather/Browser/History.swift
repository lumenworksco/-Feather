import Foundation

struct HistoryEntry: Codable, Identifiable, Hashable {
    var url: String
    var title: String
    var lastVisit: Date
    var visits: Int
    var id: String { url }
}

/// Local-only browsing history, most recent first, capped. Never leaves the machine.
@MainActor
final class History: ObservableObject {
    private static let limit = 3000
    @Published private(set) var entries: [HistoryEntry]
    private var saveTask: Task<Void, Never>?

    init() { entries = Storage.load("history.json", as: [HistoryEntry].self) ?? [] }

    func record(url: URL, title: String) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let key = url.absoluteString
        var visits = 1
        if let i = entries.firstIndex(where: { $0.url == key }) {
            visits = entries[i].visits + 1
            entries.remove(at: i)
        }
        entries.insert(HistoryEntry(url: key, title: title, lastVisit: Date(), visits: visits), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        scheduleSave()
    }

    func clear() {
        entries = []
        flush()
    }

    func flush() {
        saveTask?.cancel()
        Storage.save(entries, as: "history.json")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { flush() }
        }
    }
}
