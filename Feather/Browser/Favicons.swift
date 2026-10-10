import AppKit
import WebKit

/// Fetches a page's icon once per host (declared <link rel=icon>, else /favicon.ico) and keeps a small in-memory cache.
/// This is the only background network request the browser makes; it exists purely to draw tab icons.
@MainActor
final class Favicons {
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 64
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    func cached(host: String) -> NSImage? { cache[host] }

    /// The page's declared icon URL. Split from the download so the caller holds the web view only for this JS call.
    func declaredHref(in webView: WKWebView) async -> String? {
        let js = "(document.querySelector('link[rel~=\"icon\"]')||document.querySelector('link[rel=\"apple-touch-icon\"]')||{}).href||''"
        return (try? await webView.evaluateJavaScript(js)) as? String
    }

    func icon(page: URL, declared: String?) async -> NSImage? {
        guard page.scheme == "http" || page.scheme == "https", let host = page.host else { return nil }
        if let hit = cache[host] { return hit }
        let candidates = [declared.flatMap { URL(string: $0) }, URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL]
            .compactMap { $0 }.filter { $0.scheme == "http" || $0.scheme == "https" }

        for url in candidates {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 512_000,
                  let image = Self.thumbnail(data) else { continue }
            store(image, for: host)
            return image
        }
        return nil
    }

    private func store(_ image: NSImage, for host: String) {
        cache[host] = image
        order.append(host)
        if order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
    }

    private static func thumbnail(_ data: Data) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 32,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 16, height: 16))
    }
}
