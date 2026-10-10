import WebKit

/// One-shot cookie import: if a `cookies-import.json` file (written by a local migration script) is present in Feather's
/// data folder at launch, its cookies are loaded into WebKit's cookie store and the file is deleted straight away
/// (it holds live session tokens, so it must not linger).
private struct ImportedCookie: Codable {
    var domain: String, name: String, value: String, path: String
    var expires: Double
    var secure: Bool, httpOnly: Bool
    var sameSite: Int                                  // Chromium: -1 unspecified, 0 none, 1 lax, 2 strict

    var httpCookie: HTTPCookie? {
        var p: [HTTPCookiePropertyKey: Any] = [.domain: domain, .name: name, .value: value,
                                               .path: path.isEmpty ? "/" : path,
                                               .expires: Date(timeIntervalSince1970: expires)]
        if secure { p[.secure] = "TRUE" }
        if httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if sameSite == 1 { p[.sameSitePolicy] = "lax" } else if sameSite == 2 { p[.sameSitePolicy] = "strict" }
        return HTTPCookie(properties: p)
    }
}

@MainActor
enum CookieImport {
    private static var file: URL { Storage.directory.appendingPathComponent("cookies-import.json") }
    static var isPending: Bool { FileManager.default.fileExists(atPath: file.path) }

    static func run() async {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file), let items = try? JSONDecoder().decode([ImportedCookie].self, from: data) else {
            Log.lifecycle.error("cookie import file unreadable")
            return
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        var loaded = 0
        for item in items {
            guard let cookie = item.httpCookie else { continue }
            await store.setCookie(cookie)
            loaded += 1
        }
        Log.lifecycle.info("imported \(loaded) of \(items.count) cookies")
        if TabStore.bench { print("COOKIES_IMPORTED \(loaded)/\(items.count)"); fflush(stdout) }
    }
}
