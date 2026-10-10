import SwiftUI
import WebKit

/// Hosts the active tab's existing WKWebView (never creates one). Inactive live web views are detached
/// from the window, which lets WebKit throttle their rendering and timers.
/// The size of the page area, remembered so web views are created at the right size even while they are not on screen
/// (a tab loading in the background would otherwise see a 0x0 window, and lay itself out for that).
enum WebViewMetrics {
    static var contentSize = CGSize.zero
    static var initialFrame: NSRect {
        let s = contentSize
        return NSRect(origin: .zero, size: s.width > 200 && s.height > 200 ? s : NSSize(width: 1280, height: 800))
    }
}

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView?

    private final class Host: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if newSize.width > 200, newSize.height > 200 { WebViewMetrics.contentSize = newSize }
        }
    }

    func makeNSView(context: Context) -> NSView { Host() }

    func updateNSView(_ host: NSView, context: Context) {
        if host.subviews.first === webView { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        guard let webView else { return }
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
    }

    static func dismantleNSView(_ host: NSView, coordinator: ()) {
        host.subviews.forEach { $0.removeFromSuperview() }
    }
}
