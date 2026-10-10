import SwiftUI

/// Native start page: no web view, no network, no feeds. The icon, title and tiles fade up in sequence when it appears.
struct StartPage: View {
    @ObservedObject var tab: Tab
    @ObservedObject var bookmarks: Bookmarks
    @ObservedObject var history: History
    let favicons: Favicons

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 80, height: 80).reveal(delay: 0)
                Text("Feather")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [Brand.accent, Brand.accent.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    .reveal(delay: 0.05)
                // No second search box: the address bar is focused on every new tab, so typing just works.
                Text("Start typing to search Google").font(.system(size: 14)).foregroundStyle(.secondary).reveal(delay: 0.1)
            }

            if !bookmarks.items.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 14)], spacing: 16) {
                    ForEach(Array(bookmarks.items.prefix(12).enumerated()), id: \.element.id) { index, b in
                        BookmarkTile(bookmark: b, color: Theme.palette[index % Theme.palette.count], icon: b.url.host.flatMap { favicons.cached(host: $0) }) { tab.open(b.url) }
                            .contextMenu { Button("Remove Bookmark") { Theme.animate { bookmarks.remove(b) } } }
                            .reveal(delay: 0.16 + Double(index) * 0.035)
                    }
                }
                .frame(maxWidth: 540)
                .motion(Theme.spring, value: bookmarks.items.map(\.id))
            }

            let recents = recentHosts()
            if !recents.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(recents.enumerated()), id: \.element.host) { index, r in
                        RecentChip(host: r.host) { tab.open(r.url) }.reveal(delay: 0.45 + Double(index) * 0.04)
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Rectangle().fill(.background)
                RadialGradient(colors: [Brand.accent.opacity(0.13), .clear], center: UnitPoint(x: 0.5, y: 0.12), startRadius: 0, endRadius: 560)
            }
        }
    }

    /// Up to 5 most recent distinct hosts.
    private func recentHosts() -> [(host: String, url: URL)] {
        var seen = Set<String>(), out: [(String, URL)] = []
        for e in history.entries {
            guard let url = URL(string: e.url), let host = url.host, seen.insert(host).inserted else { continue }
            out.append((host, url))
            if out.count == 5 { break }
        }
        return out
    }
}

private struct BookmarkTile: View {
    let bookmark: Bookmark
    let color: Color                 // by position, so neighbours always differ (hashing a few names clumps colors)
    let icon: NSImage?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(color.opacity(hovering ? 0.36 : 0.26))
                    if let icon { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 26, height: 26) }
                    else {
                        Text(String(bookmark.title.prefix(1)).uppercased())
                            .font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(color)
                    }
                }
                .frame(width: 58, height: 58)
                .scaleEffect(hovering ? 1.08 : 1)
                .offset(y: hovering ? -2 : 0)
                Text(bookmark.title).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(Color.primary.opacity(hovering ? 0.95 : 0.6))
            }
            .frame(width: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .onHover { hovering = $0 }
        .motion(Theme.quick, value: hovering)
    }
}

private struct RecentChip: View {
    let host: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(Theme.tileColor(for: host)).frame(width: 7, height: 7)
                Text(host).font(.system(size: 12))
            }
            .foregroundStyle(Color.primary.opacity(hovering ? 0.95 : 0.6))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.10 : 0.05)))
            .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .onHover { hovering = $0 }
        .motion(Theme.quick, value: hovering)
    }
}
