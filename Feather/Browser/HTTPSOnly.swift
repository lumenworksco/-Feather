import Foundation

/// "HTTPS-only mode": a page address that starts with http:// is opened as https:// instead. If the secure version cannot be reached,
/// the tab says so and offers to continue over http (that choice is remembered only until Feather quits, per site).
enum HTTPSOnly {
    /// The https address to use instead of `url`, or nil when `url` should be left alone: not http, a machine on this network or this
    /// computer (localhost, .local names, IP addresses, single-word names like a router's), an explicit port (a development server, which
    /// would not speak https on the same port), or a site the user allowed.
    static func upgraded(_ url: URL, allowed: Set<String>) -> URL? {
        guard url.scheme?.lowercased() == "http", url.port == nil, let host = url.host?.lowercased(), !host.isEmpty,
              !isLocal(host), !allowed.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        return parts.url
    }

    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        if host.contains(":") { return true }                                                       // an IPv6 address
        let labels = host.split(separator: ".")
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true }               // an IPv4 address
        return labels.count < 2                                                                     // a single word: a name on the local network
    }

    /// Errors that mean "no secure version here" (as opposed to no network at all, or a name that does not exist, which http would not fix).
    static func offersInsecure(after error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorCannotConnectToHost, NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                NSURLErrorClientCertificateRequired, NSURLErrorCannotParseResponse].contains(error.code)
    }
}
