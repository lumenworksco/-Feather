import SwiftUI

/// Colors a group can have. The raw value is what the session file stores, so keep the names stable.
enum GroupColor: String, CaseIterable {
    case lavender, blue, green, yellow, orange, red, pink, gray

    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .lavender: return Brand.accent
        case .blue: return Color(red: 0.30, green: 0.55, blue: 0.95)
        case .green: return Color(red: 0.30, green: 0.70, blue: 0.45)
        case .yellow: return Color(red: 0.90, green: 0.72, blue: 0.20)
        case .orange: return Color(red: 0.95, green: 0.55, blue: 0.20)
        case .red: return Color(red: 0.90, green: 0.35, blue: 0.35)
        case .pink: return Color(red: 0.90, green: 0.45, blue: 0.70)
        case .gray: return Color.gray
        }
    }
}

/// A named, colored set of tabs that sit next to each other in the sidebar and can be folded away.
/// Which tabs belong to it is stored on the tabs (`Tab.groupID`); the group itself holds only its look.
struct TabGroup: Identifiable, Equatable {
    let id: UUID
    var name: String
    var color: GroupColor
    var isCollapsed = false

    var displayName: String { name.isEmpty ? "Group" : name }
}

/// A group as written to the session file.
struct SavedGroup: Codable {
    var id: String
    var name: String
    var color: String?
    var collapsed: Bool?
}

extension TabGroup {
    init?(_ saved: SavedGroup) {
        guard let id = UUID(uuidString: saved.id) else { return nil }
        self.init(id: id, name: saved.name, color: saved.color.flatMap(GroupColor.init(rawValue:)) ?? .lavender, isCollapsed: saved.collapsed ?? false)
    }
    var saved: SavedGroup { SavedGroup(id: id.uuidString, name: name, color: color.rawValue, collapsed: isCollapsed ? true : nil) }
}

// MARK: - Grouping operations

extension TabStore {
    func group(_ id: UUID?) -> TabGroup? { id.flatMap { id in groups.first { $0.id == id } } }
    func members(of group: UUID) -> [Tab] { tabs.filter { $0.groupID == group } }

    /// Puts `tab` in a new group (named and recolored by the user afterwards) and starts renaming it.
    @discardableResult
    func newGroup(with tab: Tab) -> TabGroup {
        let used = Set(groups.map(\.color))
        let g = TabGroup(id: UUID(), name: "", color: GroupColor.allCases.first { !used.contains($0) } ?? .lavender)
        groups.append(g)
        addToGroup(tab, g.id)
        renamingGroup = g.id
        return g
    }

    /// Moves `tab` to the end of the group (a pinned tab is unpinned first: pinned tabs are never in a group).
    func addToGroup(_ tab: Tab, _ groupID: UUID) {
        guard group(groupID) != nil, tab.groupID != groupID else { return }
        if tab.isPinned { setPinned(tab, false) }
        let old = tab.groupID
        let from = tabs.firstIndex { $0 === tab } ?? tabs.count
        tabs.removeAll { $0 === tab }
        tab.groupID = groupID
        // After the group's last tab, or, for a brand-new group, where the tab already was.
        tabs.insert(tab, at: tabs.lastIndex { $0.groupID == groupID }.map { $0 + 1 } ?? min(from, tabs.count))
        dropEmptyGroups(old)
        tabsChanged()
    }

    /// The tab leaves its group and stays right after it.
    func removeFromGroup(_ tab: Tab) {
        guard let old = tab.groupID else { return }
        tabs.removeAll { $0 === tab }
        tab.groupID = nil
        tabs.insert(tab, at: (tabs.lastIndex { $0.groupID == old }.map { $0 + 1 }) ?? min(tabs.count, tabs.prefix(while: \.isPinned).count))
        dropEmptyGroups(old)
        tabsChanged()
    }

    /// Dissolves the group; its tabs stay where they are.
    func ungroup(_ id: UUID) {
        tabs.filter { $0.groupID == id }.forEach { $0.groupID = nil }
        groups.removeAll { $0.id == id }
        tabsChanged()
    }

    func closeGroup(_ id: UUID) {
        for tab in members(of: id) { close(tab.id) }
        groups.removeAll { $0.id == id }
        tabsChanged()
    }

    func toggleCollapsed(_ id: UUID) { updateGroup(id) { $0.isCollapsed.toggle() } }
    func rename(_ id: UUID, to name: String) { updateGroup(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) } }
    func setColor(_ id: UUID, _ color: GroupColor) { updateGroup(id) { $0.color = color } }

    private func updateGroup(_ id: UUID, _ change: (inout TabGroup) -> Void) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        change(&groups[i])
        tabsChanged()
    }

    /// A group with no tabs left disappears.
    func dropEmptyGroups(_ candidate: UUID? = nil) {
        let used = Set(tabs.compactMap(\.groupID))
        groups.removeAll { !used.contains($0.id) && (candidate == nil || $0.id == candidate) }
    }

    /// Keeps each group's tabs together, at the place of its first tab, and keeps pinned tabs ungrouped.
    func enforceGroupOrder() {
        tabs.filter(\.isPinned).forEach { $0.groupID = nil }
        let known = Set(groups.map(\.id))
        tabs.filter { $0.groupID.map { !known.contains($0) } ?? false }.forEach { $0.groupID = nil }
        var result: [Tab] = [], placed = Set<UUID>()
        for tab in tabs {
            if let g = tab.groupID {
                if placed.insert(g).inserted { result += tabs.filter { $0.groupID == g } }
            } else {
                result.append(tab)
            }
        }
        tabs = result
        dropEmptyGroups()
    }

    /// What the sidebar shows for the unpinned tabs: a header where each group starts, and its tabs unless it is folded
    /// (the selected tab always stays visible, so the selection is never hidden).
    enum SidebarItem: Identifiable {
        case header(TabGroup, count: Int)
        case tab(Tab, group: TabGroup?)
        var id: UUID {
            switch self { case .header(let g, _): return g.id; case .tab(let t, _): return t.id }
        }
    }

    var sidebarItems: [SidebarItem] {
        var items: [SidebarItem] = [], lastGroup: UUID?
        for tab in tabs where !tab.isPinned {
            let g = group(tab.groupID)
            if let g, g.id != lastGroup { items.append(.header(g, count: tabs.filter { $0.groupID == g.id }.count)) }
            lastGroup = g?.id
            if let g, g.isCollapsed, tab.id != selectedID { continue }
            items.append(.tab(tab, group: g))
        }
        return items
    }
}
