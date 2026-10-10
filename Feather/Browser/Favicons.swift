import AppKit
import WebKit

/// Site icons for tabs, pins and bookmarks.
///
/// Each icon is fetched once per site (declared <link rel=icon>, else /favicon.ico), shrunk to a 32 px PNG (typically
/// 1-3 KB) and saved in the profile folder, so tabs that haven't been loaded yet still show their icon after a relaunch.
/// Icons are read back lazily, one small file at a time, into a bounded in-memory cache, so neither RAM nor disk
/// grows with the number of tabs. A saved icon is refreshed in the background once a week, and the folder is capped.
/// This is the only background network request the browser makes; it exists purely to draw icons.
@MainActor
final class Favicons {
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 64                                  // decoded images kept in memory (a 32 px image is ~4 KB)
    private let directory: URL
    private let ioQueue = DispatchQueue(label: "dev.feather.favicons", qos: .utility)
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    nonisolated static let refreshAge: TimeInterval = 7 * 86400        // re-fetch an icon this old (the old one keeps showing meanwhile)
    nonisolated static let maxFiles = 400                               // oldest are deleted beyond this
    nonisolated static let maxAge: TimeInterval = 120 * 86400           // icons not refreshed for this long are deleted

    init(directory: URL = Storage.directory.appendingPathComponent("Favicons", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dir = directory
        ioQueue.async { Self.trim(dir) }
    }

    // MARK: Reading

    /// The icon for a site: from memory, else from its small file on disk, else nil.
    func cached(host: String) -> NSImage? {
        if let hit = cache[host] { return hit }
        guard let data = try? Data(contentsOf: file(for: host)), let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 16, height: 16)          // 32 px of detail, drawn at 16 pt
        remember(image, for: host)
        return image
    }

    /// True when the saved icon is older than a week (or missing).
    func isStale(host: String) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file(for: host).path)[.modificationDate]) as? Date else { return true }
        return Date().timeIntervalSince(modified) > Self.refreshAge
    }

    // MARK: Fetching

    /// The page's declared icon URL. Split from the download so the caller holds the web view only for this JS call.
    func declaredHref(in webView: WKWebView) async -> String? {
        let js = "(document.querySelector('link[rel~=\"icon\"]')||document.querySelector('link[rel=\"apple-touch-icon\"]')||{}).href||''"
        return (try? await webView.evaluateJavaScript(js)) as? String
    }

    func icon(page: URL, declared: String?) async -> NSImage? {
        guard page.scheme == "http" || page.scheme == "https", let host = page.host else { return nil }
        if let hit = cached(host: host), !isStale(host: host) { return hit }
        let candidates = [declared.flatMap { URL(string: $0) }, URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL]
            .compactMap { $0 }.filter { $0.scheme == "http" || $0.scheme == "https" }

        for url in candidates {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 512_000,
                  let thumb = Self.thumbnail(data) else { continue }
            put(thumb.image, png: thumb.png, host: host)
            return thumb.image
        }
        return cached(host: host)                           // refresh failed: keep showing the old icon
    }

    // MARK: Saving

    /// Remembers an icon in memory and saves it to disk.
    func put(_ image: NSImage, png: Data? = nil, host: String) {
        remember(image, for: host)
        guard !Storage.readOnly, let data = png ?? Self.pngData(of: image) else { return }
        let url = file(for: host)
        ioQueue.async { try? data.write(to: url, options: .atomic) }
    }

    /// Deletes every saved icon except those of `keeping` (sites that are still open or bookmarked).
    func prune(keeping hosts: Set<String>) {
        let keep = Set(hosts.map { file(for: $0).lastPathComponent })
        cache = cache.filter { hosts.contains($0.key) }
        order = order.filter { hosts.contains($0) }
        let dir = directory
        ioQueue.async {
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(f.lastPathComponent) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    /// Waits for pending disk work (used by tests and at quit).
    func flush() { ioQueue.sync {} }

    // MARK: Internals

    /// Host names are already file-name-safe apart from a few characters (IPv6 brackets, colons); keep it readable.
    private func file(for host: String) -> URL {
        let safe = String(host.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }.prefix(100))
        return directory.appendingPathComponent(safe + ".png")
    }

    private func remember(_ image: NSImage, for host: String) {
        if cache[host] == nil { order.append(host) }
        cache[host] = image
        if order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
    }

    /// Keeps the folder bounded: drop icons not refreshed for months, then the oldest beyond the cap.
    private nonisolated static func trim(_ dir: URL) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, d)
            }
            .sorted { $0.1 > $1.1 }
        for (index, entry) in files.enumerated() where index >= maxFiles || Date().timeIntervalSince(entry.1) > maxAge {
            try? fm.removeItem(at: entry.0)
        }
    }

    private static func pngData(of image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    private static func thumbnail(_ data: Data) -> (image: NSImage, png: Data)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 32,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        return (NSImage(cgImage: cg, size: NSSize(width: 16, height: 16)), png)
    }
}
