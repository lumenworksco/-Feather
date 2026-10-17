import Foundation

enum InactiveMode: String, CaseIterable, Identifiable {
    case balanced, memorySaver, aggressive
    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .memorySaver: "Memory Saver"
        case .aggressive: "Aggressive Memory Saver"
        }
    }
    /// Maximum number of live web views, including the active tab.
    var maxLive: Int {
        switch self { case .balanced: 6; case .memorySaver: 3; case .aggressive: 2 }
    }
    /// Inactive tabs untouched for this long are unloaded even if under the live-view cap.
    var maxIdle: TimeInterval? {
        switch self { case .balanced: nil; case .memorySaver: 30 * 60; case .aggressive: 5 * 60 }
    }
    var detail: String {
        switch self {
        case .balanced: "Keeps up to 6 pages loaded. Oldest tabs beyond that are unloaded."
        case .memorySaver: "Keeps up to 3 pages loaded and unloads tabs left idle for 30 minutes."
        case .aggressive: "Keeps 2 pages loaded and unloads tabs idle for 5 minutes. Returning to an unloaded tab reloads the page and may lose its JavaScript state."
        }
    }
}

@MainActor
final class BrowserSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var inactiveMode: InactiveMode { didSet { defaults.set(inactiveMode.rawValue, forKey: "inactiveMode") } }
    /// Benchmark/test override: `--lifecycle=off|balanced|saver|aggressive` (not persisted). `off` never unloads tabs.
    let lifecycleDisabled: Bool

    @Published var sidebarVisible: Bool { didSet { defaults.set(sidebarVisible, forKey: "sidebarVisible") } }
    @Published private(set) var zoomLevels: [String: Double] { didSet { defaults.set(zoomLevels, forKey: "zoomLevels") } }
    @Published private(set) var excludedHosts: [String] { didSet { defaults.set(excludedHosts, forKey: "excludedHosts") } }
    /// Look for new versions about once a day (a request to GitHub; nothing is installed without a click).
    @Published var autoUpdateCheck: Bool { didSet { defaults.set(autoUpdateCheck, forKey: "autoUpdateCheck") } }
    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: "lastUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }

    init() {
        if let profile = Storage.profile {
            defaults = UserDefaults(suiteName: "dev.feather.profile.\(profile)")!
        } else if Storage.isFresh {
            defaults = UserDefaults(suiteName: "dev.feather.fresh")!
            defaults.removePersistentDomain(forName: "dev.feather.fresh")
        } else {
            defaults = .standard
        }
        let override = CommandLine.arguments.first { $0.hasPrefix("--lifecycle=") }.map { String($0.dropFirst(12)) }
        lifecycleDisabled = override == "off"
        let named: [String: InactiveMode] = ["balanced": .balanced, "saver": .memorySaver, "aggressive": .aggressive]
        inactiveMode = override.flatMap { named[$0] } ?? InactiveMode(rawValue: defaults.string(forKey: "inactiveMode") ?? "") ?? .balanced
        sidebarVisible = CommandLine.arguments.contains("--sidebar=hidden") ? false : (defaults.object(forKey: "sidebarVisible") as? Bool ?? true)
        zoomLevels = defaults.dictionary(forKey: "zoomLevels") as? [String: Double] ?? [:]
        excludedHosts = defaults.stringArray(forKey: "excludedHosts") ?? []
        autoUpdateCheck = defaults.object(forKey: "autoUpdateCheck") as? Bool ?? true
    }

    func zoom(for host: String) -> Double? { zoomLevels[host] }
    func setZoom(_ value: Double, for host: String) {
        if abs(value - 1.0) < 0.01 { zoomLevels.removeValue(forKey: host) } else { zoomLevels[host] = value }
    }

    func isExcluded(_ host: String) -> Bool {
        let h = host.lowercased()
        return excludedHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    func addExcluded(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.contains("://") { s = URL(string: s)?.host ?? s }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        guard !s.isEmpty, !excludedHosts.contains(s) else { return }
        excludedHosts.append(s)
    }

    func removeExcluded(_ host: String) { excludedHosts.removeAll { $0 == host } }
}
