import SwiftUI
import WebKit

struct SettingsView: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var settings: BrowserSettings
    @State private var newHost = ""
    @State private var confirmClearData = false

    init(store: TabStore) {
        self.store = store
        _settings = ObservedObject(wrappedValue: store.settings)
        _updatesModel = ObservedObject(wrappedValue: store.updates)
    }

    @ObservedObject private var updatesModel: Updates

    private var updateStatusText: String {
        switch store.updates.state {
        case .checking: return "Checking…"
        case .upToDate: return "You're up to date."
        case .available(let m): return "Version \(m.version) is available."
        case .downloading(let m, _): return "Downloading \(m.version)…"
        case .ready(let m): return "Version \(m.version) is ready to install."
        case .installing: return "Installing…"
        case .failed(let message): return message
        case .idle: return store.updates.canVerify ? "" : "This build has no update key, so it cannot update itself."
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Feather").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(version).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 4)
            form
        }
        .frame(width: 480, height: 720)
        .tint(Brand.accent)
    }

    private var form: some View {
        Form {
            Section("Inactive tabs") {
                Picker("Mode", selection: $settings.inactiveMode) {
                    ForEach(InactiveMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(settings.inactiveMode.detail).font(.callout).foregroundStyle(.secondary)
                Text("Tabs with typed-in form fields, playing media, camera/microphone use, or an excluded site are never unloaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Never unload these sites") {
                ForEach(settings.excludedHosts, id: \.self) { host in
                    HStack { Text(host); Spacer(); Button("Remove") { settings.removeExcluded(host) }.buttonStyle(.borderless) }
                }
                HStack {
                    TextField("Site", text: $newHost, prompt: Text("Add a site, e.g. example.com")).labelsHidden().onSubmit(addHost)
                    Button("Add", action: addHost).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $settings.autoUpdateCheck)
                HStack {
                    Text(updateStatusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { Task { await store.updates.check(userInitiated: true) } }.disabled(!store.updates.canVerify)
                }
                Text("Checking asks GitHub for the newest release about once a day. Updates are signed by the project owner, and Feather installs one only when you click.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Default browser") {
                Button("Make Feather the Default Browser…") {
                    // macOS asks for confirmation; Feather declares http/https handling in its Info.plist.
                    for scheme in ["http", "https"] {
                        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in }
                    }
                }
            }
            Section("Privacy") {
                Button("Clear Browsing History") { store.clearHistory() }
                Button("Clear Website Data…") { confirmClearData = true }
            }
            Section("Diagnostics") {
                LabeledContent("Tabs", value: "\(store.tabs.count)")
                LabeledContent("Live web views", value: "\(store.liveCount)")
                LabeledContent("Last unloaded-tab restore", value: store.lastRestoreMilliseconds.map { "\($0) ms" } ?? "—")
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.inactiveMode) { _, _ in store.lifecycle.enforce() }
        .confirmationDialog("Clear all website data?", isPresented: $confirmClearData) {
            Button("Clear Cookies, Cache and Site Data", role: .destructive) {
                Task { await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) }
            }
        } message: { Text("You will be signed out of websites. Open tabs are not reloaded.") }
    }

    private func addHost() { settings.addExcluded(newHost); newHost = "" }
}
