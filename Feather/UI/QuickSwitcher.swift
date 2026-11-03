import SwiftUI

extension TabStore {
    func showSwitcher() { switcherVisible = true }

    func hideSwitcher() {
        guard switcherVisible else { return }
        switcherVisible = false
        selected?.focusContent()
    }

    /// Opens what the user picked: switches to an open tab, or opens a page (reusing a tab that already shows it).
    func activate(_ result: QuickResult) {
        switch result.kind {
        case .tab(let id): select(id)
        case .page(let url): if let open = tabs.first(where: { $0.url == url }) { select(open.id) } else { newTab(url: url) }
        case .search(let text): if let url = AddressResolver.resolve(text) { newTab(url: url) }
        }
        hideSwitcher()
    }

    var switcherTabs: [QuickSearch.TabInfo] {
        tabs.sorted { $0.lastActive > $1.lastActive }.map { QuickSearch.TabInfo(id: $0.id, title: $0.title, url: $0.url) }
    }
}

/// "Search Tabs" (⇧⌘A): find an open tab, a bookmark or a page from history by typing part of its name or address.
struct QuickSwitcher: View {
    @ObservedObject var store: TabStore
    @State private var query = ""
    @State private var index = 0

    private var results: [QuickResult] {
        QuickSearch.results(query: query, tabs: store.switcherTabs, bookmarks: store.bookmarks.items, history: store.history.entries)
    }

    var body: some View {
        let list = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { store.hideSwitcher() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    SwitcherField(text: $query,
                                  onMove: { step in index = list.isEmpty ? 0 : min(max(index + step, 0), list.count - 1) },
                                  onSubmit: { if list.indices.contains(index) { store.activate(list[index]) } },
                                  onCancel: { store.hideSwitcher() })
                        .frame(height: 22)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, result in
                                Row(result: result, selected: i == index)
                                    .id(result.id)
                                    .onTapGesture { store.activate(result) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: index) { _, now in if list.indices.contains(now) { proxy.scrollTo(list[now].id) } }
                }
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.top, 90)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
        .onChange(of: query) { _, _ in index = 0 }
    }

    private struct Row: View {
        let result: QuickResult
        let selected: Bool
        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    Text(result.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(result.label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Brand.accent.opacity(0.30) : Color.clear))
            .contentShape(Rectangle())
        }
    }
}

/// The switcher's text field, through AppKit so it gets keyboard focus the moment it appears and so the arrow keys, Return and
/// Escape reach it and not the page behind it. (SwiftUI's focus handling was unreliable here; see docs/DEVELOPMENT.md.)
private struct SwitcherField: NSViewRepresentable {
    static let placeholder = "Search tabs, bookmarks and history"     // different from the address field's, which AddressFocus looks for
    @Binding var text: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = Self.placeholder
        f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
        f.font = .systemFont(ofSize: 16)
        f.delegate = context.coordinator
        f.cell?.usesSingleLineMode = true
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SwitcherField
        init(_ parent: SwitcherField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
