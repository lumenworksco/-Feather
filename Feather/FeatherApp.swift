import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--appearance=light|dark` forces an appearance (for screenshots and tests).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--appearance=") }) {
            NSApp.appearance = NSAppearance(named: arg.hasSuffix("light") ? .aqua : .darkAqua)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Links clicked in other apps (once Feather is the default browser) and .html files opened with Feather.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { TabStore.open(external: $0) }
    }
}

@main
struct FeatherApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var store = TabStore()

    var body: some Scene {
        Window("Feather", id: "main") {
            BrowserWindow(store: store)
                .frame(minWidth: 640, minHeight: 400)
                #if DEBUG
                .task {
                    // `--window-size=640x480` sets the window's content size (screenshots of narrow layouts).
                    if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--window-size=") }) {
                        let dims = arg.dropFirst(14).split(separator: "x").compactMap { Double($0) }
                        try? await Task.sleep(for: .milliseconds(600))
                        if dims.count == 2, let w = NSApp.windows.first(where: { $0.title == "Feather" }) { w.setContentSize(NSSize(width: dims[0], height: dims[1])) }
                    }
                    if CommandLine.arguments.contains("--selftest") { await SelfTest.run(store) }
                    if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot=") }) {
                        // Renders the window's own views (not web content or the blur material) to a PNG, for layout checks.
                        try? await Task.sleep(for: .seconds(Double(CommandLine.arguments.first { $0.hasPrefix("--snapshot-delay=") }.map { String($0.dropFirst(17)) } ?? "6") ?? 6))
                        if let w = NSApp.windows.first(where: { $0.title == "Feather" }), let v = w.contentView,
                           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.cacheDisplay(in: v.bounds, to: rep)
                            let out = FileManager.default.temporaryDirectory.appendingPathComponent(String(arg.dropFirst(11)))   // sandbox: only the container is writable
                            try? rep.representation(using: .png, properties: [:])?.write(to: out)
                            print("SNAPSHOT \(out.path) \(Int(v.bounds.width))x\(Int(v.bounds.height))")
                            print("SNAPSHOT ok \(Int(v.bounds.width))x\(Int(v.bounds.height))")
                        } else { print("SNAPSHOT no window; windows=\(NSApp.windows.map { "\($0.title)|vis=\($0.isVisible)" })") }
                        fflush(stdout)
                    }
                    if CommandLine.arguments.contains("--probe") {   // prints the window id so screencapture -l can target only Feather
                        try? await Task.sleep(for: .seconds(1))
                        print("WINDOW \(NSApp.windows.first { $0.title == "Feather" }?.windowNumber ?? -1)"); fflush(stdout)
                    }
                }
                #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { BrowserCommands(store: store) }

        Settings { SettingsView(store: store) }
    }
}
