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
    private let fileName: String

    init(fileName: String = "history.json") {
        self.fileName = fileName
        entries = Storage.load(fileName, as: [HistoryEntry].self) ?? []
    }

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

    /// Forgets visits since `date` (the "last hour" and "today" choices); an entry visited before that stays.
    func clear(since date: Date) {
        entries.removeAll { $0.lastVisit >= date }
        flush()
    }

    func remove(ids: Set<String>) {
        entries.removeAll { ids.contains($0.id) }
        flush()
    }

    #if DEBUG
    func setEntriesForTesting(_ list: [HistoryEntry]) { entries = list }
    #endif

    func flush() {
        saveTask?.cancel()
        Storage.save(entries, as: fileName)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { flush() }
        }
    }
}

/// History split into "Today", "Yesterday" and one section per earlier day, newest first. Pure, so it can be tested.
enum HistoryGrouping {
    static func sections(_ entries: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> [(title: String, entries: [HistoryEntry])] {
        let sorted = entries.sorted { $0.lastVisit > $1.lastVisit }
        var result: [(title: String, entries: [HistoryEntry])] = []
        var lastDay: Date?
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"; f.calendar = calendar
        for e in sorted {
            let day = calendar.startOfDay(for: e.lastVisit)
            if day != lastDay {
                let title = calendar.isDate(e.lastVisit, inSameDayAs: now) ? "Today" : (calendar.isDate(e.lastVisit, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now) ?? now) ? "Yesterday" : f.string(from: e.lastVisit))
                result.append((title, []))
                lastDay = day
            }
            result[result.count - 1].entries.append(e)
        }
        return result
    }
}
