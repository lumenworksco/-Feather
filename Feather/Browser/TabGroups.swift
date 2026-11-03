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

    /// A new blank tab at the end of the group (the group is unfolded so the tab is not hidden).
    @discardableResult
    func newTab(in groupID: UUID) -> Tab? {
        guard group(groupID) != nil else { return nil }
        let tab = Tab(store: self)
        tab.groupID = groupID
        tabs.insert(tab, at: tabs.lastIndex { $0.groupID == groupID }.map { $0 + 1 } ?? tabs.count)
        updateGroup(groupID) { $0.isCollapsed = false }
        select(tab.id)
        focusAddress()
        return tab
    }

    /// Drag and drop: the whole group goes before `target`, or to the end of the list when `target` is nil. A target inside another
    /// group means before that group's first tab, so a group is never split; never into the pinned area.
    func moveGroup(_ id: UUID, before target: Tab?) {
        let moving = tabs.filter { $0.groupID == id }
        guard !moving.isEmpty, target?.groupID != id else { return }
        tabs.removeAll { $0.groupID == id }
        var index = tabs.count
        if let target, let t = tabs.firstIndex(where: { $0 === target }) {
            index = target.groupID.flatMap { g in tabs.firstIndex { $0.groupID == g } } ?? t
        }
        tabs.insert(contentsOf: moving, at: max(index, tabs.prefix(while: \.isPinned).count))
        tabsChanged()
    }

    /// Drag and drop: the tab goes to the very top of the unpinned tabs, outside every group.
    func moveToTop(_ tab: Tab) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: from)
        let old = tab.groupID
        tab.groupID = nil
        if tab.isPinned { tab.isPinned = false }
        tabs.insert(tab, at: tabs.prefix(while: \.isPinned).count)
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

    /// Folding a group also unloads its tabs to free their memory (they reload when opened). The selected tab stays, and so does
    /// anything the lifecycle manager would never discard (typed-in form input, camera or microphone, audio, a pending security key).
    func toggleCollapsed(_ id: UUID) {
        if group(id)?.isCollapsed == true { updateGroup(id) { $0.isCollapsed = false } } else { collapse(id) }
    }

    /// Folds the group (and does nothing if it is already folded, so a timer can never unfold one).
    func collapse(_ id: UUID) {
        guard group(id)?.isCollapsed == false else { return }
        updateGroup(id) { $0.isCollapsed = true }
        Task { await lifecycle.unload(members(of: id)) }
    }

    // MARK: Folding idle groups

    /// When this group would be folded for being idle: its most recently used tab plus the setting's time. Nil when it never will be
    /// (setting off, already folded, holds the selected tab, or something in it is playing sound).
    func foldDeadline(_ group: TabGroup) -> Date? {
        let minutes = settings.groupFoldMinutes
        guard minutes > 0, !group.isCollapsed else { return nil }
        let tabs = members(of: group.id)
        guard !tabs.isEmpty, !tabs.contains(where: { $0.id == selectedID || $0.isPlayingAudio }) else { return nil }
        return tabs.map(\.lastActive).max()?.addingTimeInterval(Double(minutes) * 60)
    }

    func foldIdleGroups(now: Date = Date()) {
        for g in groups where foldDeadline(g).map({ $0 <= now }) == true { collapse(g.id) }
    }

    /// One timer for the soonest deadline (never shorter than 30 s, like the unload timer), set again whenever tabs or the setting change. Nothing polls.
    func scheduleGroupFold() {
        foldTimer?.invalidate()
        foldTimer = nil
        guard let next = groups.compactMap(foldDeadline).min() else { return }
        let delay = max(next.timeIntervalSinceNow, 30)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in Task { @MainActor in self?.foldIdleGroups(); self?.scheduleGroupFold() } }
        timer.tolerance = delay * 0.1
        RunLoop.main.add(timer, forMode: .common)
        foldTimer = timer
    }
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
