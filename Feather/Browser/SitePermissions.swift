import SwiftUI
import WebKit

/// What the user decided about camera and microphone for each site. WebKit has no public way to see or change its own remembered
/// answers, so Feather asks the question itself (see `Tab`'s media-capture delegate method) and keeps the answers here, where
/// Settings can list and undo them. Location is different: WebKit shows its own prompt for it and gives apps no hook, so macOS
/// (System Settings ▸ Privacy & Security ▸ Location Services) is where that is managed.
@MainActor
final class SitePermissions: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case camera, microphone
        var id: String { rawValue }
        var title: String { self == .camera ? "Camera" : "Microphone" }
    }
    enum Choice: String, Codable { case allow, block }
    enum Verdict: Equatable { case grant, deny, ask }

    struct Entry: Codable, Identifiable, Equatable {
        var host: String
        var camera: Choice?
        var microphone: Choice?
        var id: String { host }
        func choice(_ kind: Kind) -> Choice? { kind == .camera ? camera : microphone }
    }

    @Published private(set) var entries: [Entry]
    private let fileName: String

    init(fileName: String = "permissions.json") {
        self.fileName = fileName
        entries = (Storage.load(fileName, as: [Entry].self) ?? []).sorted { $0.host < $1.host }
    }

    func choice(host: String, _ kind: Kind) -> Choice? { entries.first { $0.host == host.lowercased() }?.choice(kind) }

    /// What to do with a request for these kinds: grant if every kind is allowed, deny if any is blocked, otherwise ask.
    func verdict(host: String, kinds: [Kind]) -> Verdict {
        let choices = kinds.map { choice(host: host, $0) }
        if choices.contains(.block) { return .deny }
        return choices.allSatisfy { $0 == .allow } && !choices.isEmpty ? .grant : .ask
    }

    func set(host: String, _ kind: Kind, to choice: Choice?) {
        let h = host.lowercased()
        var list = entries
        if let i = list.firstIndex(where: { $0.host == h }) {
            if kind == .camera { list[i].camera = choice } else { list[i].microphone = choice }
            if list[i].camera == nil && list[i].microphone == nil { list.remove(at: i) }
        } else if let choice {
            list.append(Entry(host: h, camera: kind == .camera ? choice : nil, microphone: kind == .microphone ? choice : nil))
        }
        entries = list.sorted { $0.host < $1.host }
        Storage.save(entries, as: fileName)
    }

    func forget(host: String) {
        entries.removeAll { $0.host == host.lowercased() }
        Storage.save(entries, as: fileName)
    }

    func forgetAll() {
        entries = []
        Storage.save(entries, as: fileName)
    }

    static func kinds(for type: WKMediaCaptureType) -> [Kind] {
        switch type {
        case .camera: return [.camera]
        case .microphone: return [.microphone]
        case .cameraAndMicrophone: return [.camera, .microphone]
        @unknown default: return [.camera, .microphone]
        }
    }

    /// Asks the user, as a sheet on the window. `completion(allowed, remember)` is called exactly once.
    static func ask(host: String, kinds: [Kind], window: NSWindow?, completion: @escaping (Bool, Bool) -> Void) {
        let what = kinds.map { $0.title.lowercased() }.joined(separator: " and ")
        let alert = NSAlert()
        alert.messageText = "Allow \(host) to use your \(what)?"
        alert.informativeText = "The site can see and hear what the \(what) picks up while the page is open."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice for this site"
        alert.suppressionButton?.state = .on
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}

/// Lists the remembered answers and lets the user change or remove each one.
struct SitePermissionsSection: View {
    @ObservedObject var permissions: SitePermissions

    var body: some View {
        Section("Site permissions") {
            if permissions.entries.isEmpty {
                Text("No camera or microphone answers are remembered yet. When a site asks and you tick “Remember my choice”, it appears here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(permissions.entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(entry.host).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("Forget") { permissions.forget(host: entry.host) }.buttonStyle(.borderless)
                    }
                    ForEach(SitePermissions.Kind.allCases) { kind in
                        Picker(kind.title, selection: Binding(
                            get: { entry.choice(kind)?.rawValue ?? "ask" },
                            set: { permissions.set(host: entry.host, kind, to: SitePermissions.Choice(rawValue: $0)) })) {
                            Text("Ask").tag("ask"); Text("Allow").tag("allow"); Text("Block").tag("block")
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.vertical, 2)
            }
            if !permissions.entries.isEmpty { Button("Forget All Sites") { permissions.forgetAll() } }
            HStack {
                Text("Location is asked by macOS, not by Feather.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Location Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.borderless).font(.caption)
            }
        }
    }
}
