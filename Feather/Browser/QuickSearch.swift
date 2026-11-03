import Foundation

/// One line in the quick switcher.
struct QuickResult: Identifiable, Equatable {
    enum Kind: Equatable { case tab(UUID), page(URL), search(String) }
    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
    /// "Tab", "Bookmark", "History" or "Search", shown on the right.
    let label: String
}

/// What the switcher finds for a query. A pure function (no UI, no stores) so it can be tested.
enum QuickSearch {
    struct TabInfo { let id: UUID; let title: String; let url: URL? }

    /// `tabs` should be in the order they should be offered when the query is empty (most recently used first).
    /// Every word of the query must appear in the title or the address. Tabs beat bookmarks beat history; a page that
    /// is already open is not offered again as a bookmark or history entry.
    static func results(query: String, tabs: [TabInfo], bookmarks: [Bookmark], history: [HistoryEntry], limit: Int = 12) -> [QuickResult] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var out: [(score: Int, order: Int, result: QuickResult)] = []
        var seen = Set<String>()
        var order = 0

        func score(title: String, url: String) -> Int? {
            let t = title.lowercased(), u = url.lowercased()
            let host = URL(string: url)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
            var total = 0
            for w in words {
                if t.hasPrefix(w) || host.hasPrefix(w) { total += 30 }
                else if t.split(separator: " ").contains(where: { $0.hasPrefix(w) }) { total += 20 }
                else if t.contains(w) { total += 12 }
                else if u.contains(w) { total += 6 }
                else { return nil }
            }
            return total
        }
        func add(_ base: Int, _ title: String, _ url: URL?, _ kind: QuickResult.Kind, _ label: String, key: String) {
            let address = url?.absoluteString ?? ""
            guard let s = words.isEmpty ? 0 : score(title: title, url: address) else { return }
            if let url, !seen.insert(url.absoluteString).inserted, case .page = kind { return }
            if let url, case .tab = kind { seen.insert(url.absoluteString) }
            order += 1
            let shown = title.isEmpty ? (url?.host ?? address) : title
            out.append((base + s, order, QuickResult(id: key, title: shown, subtitle: AddressFormat.pretty(url), kind: kind, label: label)))
        }

        for t in tabs { add(100, t.title, t.url, .tab(t.id), "Tab", key: "tab-\(t.id)") }
        if !words.isEmpty {
            for b in bookmarks { add(60, b.title, b.url, .page(b.url), "Bookmark", key: "bm-\(b.id)") }
            for h in history.prefix(600) { if let u = URL(string: h.url) { add(20, h.title, u, .page(u), "History", key: "h-\(h.url)") } }
        }
        let ranked = out.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.prefix(limit).map(\.result)
        var list = Array(ranked)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { list.append(QuickResult(id: "search", title: q, subtitle: "Search or go to this address", kind: .search(q), label: "Go")) }
        return list
    }
}
