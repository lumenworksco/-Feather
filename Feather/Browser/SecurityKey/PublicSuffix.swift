import Foundation

/// Public Suffix List lookups (https://publicsuffix.org, MPL-2.0; bundled as public_suffix_list.txt).
/// Used so a site can never claim an identity (rpId) that is a public suffix like "com" or "co.uk",
/// and to decide whether two hosts belong to the same registrable domain.
final class PublicSuffix {
    static let shared: PublicSuffix = {
        let text = Bundle.main.url(forResource: "public_suffix_list", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return PublicSuffix(rules: text)
    }()

    /// False if the list is missing or damaged: security-key requests are then refused rather than checked against nothing.
    var isLoaded: Bool { exact.count > 1000 }

    private var exact = Set<String>(), wildcard = Set<String>(), exceptions = Set<String>()

    init(rules text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let rule = line.trimmingCharacters(in: .whitespaces).lowercased()
            if rule.isEmpty || rule.hasPrefix("//") { continue }
            if rule.hasPrefix("!") { exceptions.insert(String(rule.dropFirst())) }
            else if rule.hasPrefix("*.") { wildcard.insert(String(rule.dropFirst(2))) }
            else { exact.insert(rule) }
        }
    }

    /// Number of labels in the public suffix of `host` (the default rule "*" makes every TLD a suffix).
    private func suffixLabelCount(_ labels: [Substring]) -> Int {
        var best = 1
        for i in 0..<labels.count {
            let candidate = labels[i...].joined(separator: ".")
            let n = labels.count - i
            if exceptions.contains(candidate) { return n - 1 }
            if exact.contains(candidate) { best = max(best, n) }
            if i + 1 < labels.count, wildcard.contains(labels[(i + 1)...].joined(separator: ".")) { best = max(best, n) }
        }
        return best
    }

    func isPublicSuffix(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty && suffixLabelCount(labels) >= labels.count
    }

    /// "accounts.example.co.uk" → "example.co.uk"; nil for a public suffix itself, an IP address or a single label.
    func registrableDomain(_ host: String) -> String? {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !Self.isIPAddress(host) else { return nil }
        let suffix = suffixLabelCount(labels)
        guard labels.count > suffix else { return nil }
        return labels[(labels.count - suffix - 1)...].joined(separator: ".")
    }

    static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil } && host.split(separator: ".").count == 4
    }
}
