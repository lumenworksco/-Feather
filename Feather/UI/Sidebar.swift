import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let featherTab = UTType(exportedAs: "dev.feather.tab") }

/// What is dragged between sidebar rows: just the tab's id, in a type only Feather understands
/// (so dropping a tab on another app does nothing, instead of pasting an id).
struct TabDrag: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .featherTab) }
}

/// Thin accent line shown where a dragged tab would be inserted.
private struct InsertionMark: ViewModifier {
    let active: Bool
    let vertical: Bool
    func body(content: Content) -> some View {
        content.overlay(alignment: vertical ? .leading : .top) {
            Capsule().fill(Brand.accent)
                .frame(width: vertical ? 3 : nil, height: vertical ? nil : 3)
                .padding(vertical ? .vertical : .horizontal, 4)
                .opacity(active ? 1 : 0)
                .scaleEffect(x: vertical ? 1 : (active ? 1 : 0.4), y: vertical ? (active ? 1 : 0.4) : 1)
                .motion(Theme.quick, value: active)
        }
    }
}
extension View { fileprivate func insertionMark(_ active: Bool, vertical: Bool = false) -> some View { modifier(InsertionMark(active: active, vertical: vertical)) } }

/// Vertical tab layout: navigation row (beside the traffic lights), address field, pinned grid, tab list, settings.
struct Sidebar: View {
    @ObservedObject var store: TabStore
    var focused: FocusState<Bool>.Binding
    @Namespace private var selection
    @Environment(\.trafficLightInset) private var trafficInset

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                SidebarToggle(settings: store.settings)
                Spacer(minLength: 0)
                NavControls(store: store)
            }
            .padding(.leading, trafficInset)             // room for the window's traffic lights
            .frame(height: 28)

            AddressBar(store: store, focused: focused)

            PinnedGrid(store: store, selection: selection)

            NewTabRow(store: store)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.tabs.filter { !$0.isPinned }) { tab in
                        TabRow(tab: tab, store: store, selected: tab.id == store.selectedID, selection: selection)
                            .transition(Theme.rowTransition)
                    }
                }
                .motion(Theme.spring, value: store.tabs.map(\.id))
            }
            .scrollIndicators(.never)
            .dropDestination(for: TabDrag.self) { items, _ in
                guard let item = items.first, let dragged = store.tab(withID: item.id) else { return false }
                Theme.animate { store.move(dragged, before: nil, pinned: false) }
                return true
            }

            HStack {
                SettingsLink { Image(systemName: "gearshape").frame(width: 26, height: 26).hoverFill(radius: 7, strength: 0.10) }
                    .buttonStyle(PressStyle()).foregroundStyle(.secondary).help("Settings")
                Spacer()
            }
            .padding(.horizontal, 2)
        }
        .motion(Theme.spring, value: store.selectedID)          // lets the selection pill glide between rows
        .padding(.horizontal, 10)
        .padding(.top, 2)                               // puts the nav row on the traffic lights' centre line
        .padding(.bottom, 10)
    }
}

/// Shown instead of the sidebar when it is hidden (⌘S), so the window is never without controls.
struct TopBar: View {
    @ObservedObject var store: TabStore
    var focused: FocusState<Bool>.Binding
    @Environment(\.trafficLightInset) private var trafficInset

    var body: some View {
        HStack(spacing: 8) {
            SidebarToggle(settings: store.settings)
            NavControls(store: store)
            Spacer(minLength: 8)
            AddressBar(store: store, focused: focused).frame(maxWidth: 640)
            Spacer(minLength: 8)
            IconButton(symbol: "plus", help: "New Tab") { store.newTab() }
            SettingsLink { Image(systemName: "gearshape").frame(width: 26, height: 26).hoverFill(radius: 7, strength: 0.10) }
                .buttonStyle(PressStyle()).foregroundStyle(.secondary).help("Settings")
        }
        .padding(.leading, trafficInset).padding(.trailing, 12)
        .frame(height: 32)
    }
}

struct SidebarToggle: View {
    @ObservedObject var settings: BrowserSettings
    var body: some View {
        IconButton(symbol: "sidebar.left", help: settings.sidebarVisible ? "Hide Sidebar (⌘S)" : "Show Sidebar (⌘S)") {
            Theme.animate { settings.sidebarVisible.toggle() }
        }
    }
}

private struct NewTabRow: View {
    let store: TabStore
    @State private var hovering = false

    var body: some View {
        Button { store.newTab() } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium)).frame(width: 16)
                    .rotationEffect(.degrees(hovering ? 90 : 0))
                Text("New Tab").font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(Color.primary.opacity(hovering ? 0.9 : 0.6))
            .padding(.horizontal, 10).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .hoverFill(radius: 8)
        .onHover { hovering = $0 }
        .motion(Theme.quick, value: hovering)
    }
}

/// Favicon, a spinner while the page loads, or a placeholder; changes cross-fade.
private struct TabIcon: View {
    @ObservedObject var tab: Tab
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            if tab.isLoading && tab.isLoaded {
                ProgressView().controlSize(.mini).transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else if let icon = tab.favicon {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
            } else {
                Image(systemName: tab.url == nil ? "plus.square.dashed" : "globe")
                    .foregroundStyle(.secondary).transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .motion(Theme.quick, value: tab.isLoading)
        .motion(Theme.quick, value: tab.favicon != nil)
    }
}

private struct TabRow: View {
    @ObservedObject var tab: Tab
    let store: TabStore
    let selected: Bool
    let selection: Namespace.ID
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        Button { store.select(tab.id) } label: {
            HStack(spacing: 9) {
                TabIcon(tab: tab)
                Text(tab.displayTitle)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.74))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, selected || hovering ? 32 : 10)         // leave room for the close button so the title never runs under it
            .frame(height: 32)
            .background {
                ZStack {
                    if hovering && !selected { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)) }
                    if selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.accent.opacity(0.30))
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
            }
            .opacity(selected || tab.isLoaded || tab.url == nil ? 1 : 0.55)            // dimmed = unloaded, reloads on click
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.985))
        .overlay(alignment: .trailing) {
            if selected || hovering { CloseButton { store.close(tab.id) }.padding(.trailing, 7).transition(.opacity.combined(with: .scale(scale: 0.5))) }
        }
        .insertionMark(dropTargeted)
        .onHover { hovering = $0 }
        .motion(Theme.quick, value: hovering)
        .draggable(TabDrag(id: tab.id))
        .dropDestination(for: TabDrag.self) { items, _ in
            guard let item = items.first, let dragged = store.tab(withID: item.id) else { return false }
            Theme.animate { store.move(dragged, before: tab, pinned: false) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .help(tab.isLoaded || tab.url == nil ? tab.displayTitle : "\(tab.displayTitle) — unloaded to save memory; reloads when opened")
        .contextMenu { TabMenu(tab: tab, store: store) }
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.16 : 0)))
        }
        .buttonStyle(PressStyle(scale: 0.88))
        .foregroundStyle(Color.primary.opacity(hovering ? 0.9 : 0.55))
        .onHover { hovering = $0 }
        .motion(Theme.fade, value: hovering)
        .help("Close Tab")
    }
}

private struct TabMenu: View {
    let tab: Tab
    let store: TabStore
    var body: some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { Theme.animate { store.togglePin(tab) } }
        Button("Reload") { tab.reloadOrStop() }
        if let host = tab.url?.host {
            Button("Never Unload \(host)") { store.settings.addExcluded(host) }
        }
        Divider()
        Button("Close Tab") { store.close(tab.id) }
    }
}

/// Pinned tabs as a compact icon grid above the tab list (4 per row; the sidebar is fixed-width so rows are explicit,
/// which also avoids lazy containers, which retained closed tabs earlier).
private struct PinnedGrid: View {
    @ObservedObject var store: TabStore
    let selection: Namespace.ID
    @State private var dropTargeted = false

    var body: some View {
        let pinned = store.tabs.filter(\.isPinned)
        VStack(spacing: 6) {
            if pinned.isEmpty {
                // Always present while nothing is pinned: it is the drop target for pinning by drag, and it tells you so.
                HStack(spacing: 6) {
                    Image(systemName: "pin").font(.system(size: 11)).rotationEffect(.degrees(dropTargeted ? -20 : 0))
                    Text("Drag a tab here to pin it").font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(dropTargeted ? Brand.accent : Color.secondary.opacity(0.7))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.accent.opacity(dropTargeted ? 0.12 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(dropTargeted ? Brand.accent : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .scaleEffect(dropTargeted ? 1.02 : 1)
                .motion(Theme.quick, value: dropTargeted)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                // Four equal columns that share the full sidebar width (so margins match the address field on both sides);
                // a partial last row is padded with empty cells so its tiles keep the same width.
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(Array(stride(from: 0, to: pinned.count, by: 4)), id: \.self) { start in
                        GridRow {
                            ForEach(0..<4, id: \.self) { column in
                                if start + column < pinned.count {
                                    PinnedTile(tab: pinned[start + column], store: store, selected: pinned[start + column].id == store.selectedID, selection: selection)
                                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                                } else {
                                    Color.clear.frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Divider().opacity(0.5).padding(.top, 2)
        }
        .motion(Theme.spring, value: pinned.map(\.id))
        .contentShape(Rectangle())
        .dropDestination(for: TabDrag.self) { items, _ in
            guard let item = items.first, let dragged = store.tab(withID: item.id) else { return false }
            Theme.animate { store.move(dragged, before: nil, pinned: true) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

private struct PinnedTile: View {
    @ObservedObject var tab: Tab
    let store: TabStore
    let selected: Bool
    let selection: Namespace.ID
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        Button { store.select(tab.id) } label: {
            Group {
                if let icon = tab.favicon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                } else {
                    Text(String((tab.url?.host ?? tab.displayTitle).replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
            .overlay(alignment: .topTrailing) {
                if tab.isLoading && tab.isLoaded { ProgressView().controlSize(.mini).scaleEffect(0.7).padding(3).transition(.opacity) }
            }
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.10 : 0.05))
                    if selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.accent.opacity(0.30))
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
            }
            .scaleEffect(hovering ? 1.04 : 1)
            .opacity(selected || tab.isLoaded ? 1 : 0.55)                              // dimmed = unloaded, reloads on click
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .insertionMark(dropTargeted, vertical: true)
        .onHover { hovering = $0 }
        .motion(Theme.quick, value: hovering)
        .motion(Theme.quick, value: tab.isLoading)
        .draggable(TabDrag(id: tab.id))
        .dropDestination(for: TabDrag.self) { items, _ in
            guard let item = items.first, let dragged = store.tab(withID: item.id) else { return false }
            Theme.animate { store.move(dragged, before: tab, pinned: true) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .help(tab.displayTitle)
        .contextMenu { TabMenu(tab: tab, store: store) }
    }
}
