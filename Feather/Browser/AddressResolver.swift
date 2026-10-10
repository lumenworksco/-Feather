import Foundation

/// Turns whatever the user typed into either a URL to load or a Google search.
enum AddressResolver {
    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = explicitURL(text) { return url }
        if looksLikeHost(text) {
            let local = text.hasPrefix("localhost") || text.first?.isNumber == true   // dev servers / LAN devices rarely have TLS
            return URL(string: (local ? "http://" : "https://") + text)
        }
        return searchURL(for: text)
    }

    static func searchURL(for query: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: query)]
        return c?.url
    }

    /// Inputs that already carry a scheme we're willing to open.
    private static func explicitURL(_ text: String) -> URL? {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") || lower.hasPrefix("about:") {
            return URL(string: text)
        }
        return nil
    }

    /// "example.com", "example.com/path?x=1", "localhost:3000", "192.168.1.1" — but not "swift tutorial".
    private static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        guard let c = URLComponents(string: "https://" + text), let host = c.host, !host.isEmpty else { return false }
        if host == "localhost" { return true }
        if host.split(separator: ".").count == 4, host.split(separator: ".").allSatisfy({ UInt8($0) != nil }) { return true }
        // Needs a dot with a non-numeric, alphabetic TLD of 2+ chars.
        guard let tld = host.split(separator: ".").last, host.contains("."), tld.count >= 2 else { return false }
        return tld.allSatisfy { $0.isLetter || $0 == "-" }
    }
}
