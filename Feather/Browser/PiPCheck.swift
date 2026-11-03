#if DEBUG
import AppKit
import WebKit

/// `Feather --pip-check --pip-main=URL [--pip-frame=URL] [--pip-remote=URL]` (started by tests/pip-test.py): drives Picture in Picture the way
/// a user does (the real Navigate menu item) and checks that a floating window with content really appears, because "the page says it is
/// playing in picture in picture" proved nothing: twice the page said so while no window was shown.
@MainActor
enum PiPCheck {
    static func run(_ store: TabStore) async {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("[pip] \(ok ? "PASS" : "FAIL")  \(name) \(detail)"); fflush(stdout)
        }
        func arg(_ name: String) -> URL? { CommandLine.arguments.first { $0.hasPrefix(name + "=") }.flatMap { URL(string: String($0.dropFirst(name.count + 1))) } }
        func wait(_ seconds: Double, _ done: () -> Bool) async -> Bool {
            for _ in 0..<Int(seconds * 10) { if done() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
            return done()
        }
        /// The floating window: it exists, is shown, has the video in it and lies on a screen. (An empty panel is what the sandbox bug produced.)
        func panel() -> NSWindow? { NSApp.windows.first { $0.title == "PIPPanel" && $0.isVisible } }
        func panelHasVideo() -> Bool {
            guard let p = panel(), let content = p.contentView, !content.subviews.isEmpty else { return false }
            return NSScreen.screens.contains { $0.frame.intersects(p.frame) } && p.frame.width > 100
        }
        func menu(_ title: String) -> Bool {
            guard let nav = NSApp.mainMenu?.items.first(where: { $0.title == "Navigate" })?.submenu, let i = nav.items.firstIndex(where: { $0.title == title }) else { return false }
            nav.performActionForItem(at: i)
            return true
        }
        func js(_ tab: Tab, _ code: String, frame: WKFrameInfo? = nil) async -> String {
            do { return String(describing: try await tab.webView?.evaluateJavaScript(code, in: frame, contentWorld: frame == nil ? .page : .defaultClient) ?? "nil") } catch { return "ERROR \(error.localizedDescription)" }
        }
        func settle(_ tab: Tab) async {
            try? await Task.sleep(for: .milliseconds(500))
            for _ in 0..<150 where tab.isLoading || tab.webView == nil { try? await Task.sleep(for: .milliseconds(200)) }
        }
        func front() {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.title == "Feather" }?.makeKeyAndOrderFront(nil)
        }
        let play = "(function(){var v=document.querySelector('video');if(!v)return 'no video';v.muted=false;v.play();return 'ok'})()"
        let mode = "(function(){var v=document.querySelector('video');return v?v.webkitPresentationMode:'no video'})()"
        let enter = "Picture in Picture"

        try? await Task.sleep(for: .seconds(1))
        front()

        // 1. A normal page with a video, through the real menu item.
        if let main = arg("--pip-main") {
            let tab = store.newTab(url: main)
            await settle(tab)
            let started = await js(tab, play)
            let sounding = await wait(8) { tab.isPlayingAudio }
            check("the video starts playing", started == "ok" && sounding, "play=\(started) playing=\(tab.isPlayingAudio)")
            front()
            check("the Navigate menu has a Picture in Picture item", menu(enter))
            check("a floating window with the video appears", await wait(6) { panelHasVideo() }, "windows=\(NSApp.windows.map { $0.title })")
            let floating = await js(tab, mode)
            check("and the page's video reports picture-in-picture", floating == "picture-in-picture", floating)
            if let p = panel() { print("[pip] panel frame=\(p.frame) subviews=\(p.contentView?.subviews.count ?? -1)"); fflush(stdout) }

            // 2. Asking again brings it back to the page.
            _ = menu(enter)
            let closed = await wait(6) { panel() == nil }
            let back = await js(tab, mode)
            check("asking again closes the floating window and returns the video to the page", closed && back == "inline", "mode=\(back)")

            // 2b. The floating window's own buttons, clicked with real mouse events by the test script (they are drawn by the system, so they
            // cannot be pressed from inside the app).
            if CommandLine.arguments.contains("--pip-clicks") {
                for (button, expectation) in [("close", "closes it"), ("return", "returns the video to the page")] {
                    _ = menu(enter)
                    _ = await wait(6) { panelHasVideo() }
                    try? await Task.sleep(for: .seconds(2))                          // the window glides to its corner first
                    if let p = panel() {
                        print("[pip] CLICK \(button) \(p.frame.minX) \(p.frame.minY) \(p.frame.width) \(p.frame.height) \(NSScreen.screens.first?.frame.height ?? 0)"); fflush(stdout)
                    }
                    let gone = await wait(15) { panel() == nil }
                    try? await Task.sleep(for: .seconds(1))
                    let after = await js(tab, mode)
                    let paused = await js(tab, "document.querySelector('video').paused")
                    check("the floating window's \(button) button \(expectation) and the page's video is back inline", gone && after == "inline", "gone=\(gone) mode=\(after) paused=\(paused)")
                    _ = menu(enter)
                    let again = await wait(6) { panelHasVideo() }
                    check("after the \(button) button, picture in picture can be started again", again)
                    _ = menu(enter)
                    _ = await wait(6) { panel() == nil }
                    _ = await js(tab, play)
                }
            }

            // 3. Closing the tab while it is floating.
            _ = menu(enter)
            check("it floats again", await wait(6) { panelHasVideo() })
            store.close(tab.id)
            check("closing the tab takes the floating window with it", await wait(6) { panel() == nil }, "windows=\(NSApp.windows.map { $0.title })")
        } else { check("a test page was given (--pip-main=URL)", false) }

        // 4. A video inside an iframe from another site (embedded players are like this).
        if let outer = arg("--pip-frame") {
            let tab = store.newTab(url: outer)
            await settle(tab)
            try? await Task.sleep(for: .seconds(2))
            let frames = tab.mediaFrames.values.map(\.frame).filter { !$0.isMainFrame }
            check("Feather knows about the embedded frame", !frames.isEmpty, "frames=\(tab.mediaFrames.count)")
            if let inner = frames.first {
                _ = await js(tab, play, frame: inner)
                _ = await wait(6) { tab.isPlayingAudio }
                front()
                _ = menu(enter)
                check("a video in an iframe from another site goes into the floating window", await wait(8) { panelHasVideo() }, "playing=\(tab.isPlayingAudio)")
                _ = menu(enter)
                _ = await wait(6) { panel() == nil }
            }
            store.close(tab.id)
        }

        // 5. A real video over https (a plain video document, like a direct link to an .mp4).
        if let remote = arg("--pip-remote") {
            let tab = store.newTab(url: remote)
            await settle(tab)
            let hasVideo = await js(tab, "document.querySelector('video') ? 'yes' : 'no'")
            if hasVideo == "yes" {
                _ = await js(tab, play)
                try? await Task.sleep(for: .seconds(3))
                front()
                _ = menu(enter)
                check("a real video from the internet goes into the floating window", await wait(8) { panelHasVideo() }, "url=\(remote.host ?? "")")
                _ = menu(enter)
                _ = await wait(6) { panel() == nil }
            } else {
                print("[pip] SKIP  the remote video did not load (no network?)"); fflush(stdout)
            }
            store.close(tab.id)
        }

        print("[pip] \(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")"); fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
