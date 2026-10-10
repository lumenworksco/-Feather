import SwiftUI
import WebKit

/// Hosts the active tab's existing WKWebView (never creates one). Inactive live web views are detached
/// from the window, which lets WebKit throttle their rendering and timers.
struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> NSView { NSView() }

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
