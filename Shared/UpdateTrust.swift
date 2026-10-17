import Foundation
import CryptoKit

/// What a signed release says about itself (update.json). Compiled into both the app and the installer helper:
/// each checks the signature on its own and trusts nothing the other one says.
struct UpdateManifest: Codable, Equatable {
    var schema: Int
    var bundleID: String
    var version: String
    var build: Int
    var asset: String          // file name of the zip
    var sha256: String         // of the zip, lowercase hex
    var size: Int              // of the zip, bytes
}

enum UpdateTrust {
    static let expectedBundleID = "dev.feather.Feather"
    static let maxZipSize = 200_000_000

    /// The key that signs releases. It comes from the build (UPDATE_PUBLIC_KEY), so tests can use a throwaway key;
    /// a build without a key refuses every update.
    static func configuredKey() -> Curve25519.Signing.PublicKey? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "FeatherUpdatePublicKey") as? String else { return nil }
        return key(base64: text)
    }

    static func key(base64: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// Returns the manifest only if the signature is valid for exactly these bytes and every field is well formed.
    static func verify(manifest: Data, signatureText: Data, key: Curve25519.Signing.PublicKey?) -> UpdateManifest? {
        guard let key,
              let sigString = String(data: signatureText, encoding: .utf8),
              let signature = Data(base64Encoded: sigString.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(signature, for: manifest),
              let m = try? JSONDecoder().decode(UpdateManifest.self, from: manifest), isWellFormed(m) else { return nil }
        return m
    }

    static func isWellFormed(_ m: UpdateManifest) -> Bool {
        m.schema == 1 && m.bundleID == expectedBundleID
            && m.asset.range(of: #"^Feather-[0-9A-Za-z._-]+\.zip$"#, options: .regularExpression) != nil && !m.asset.contains("..")
            && m.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
            && (1...maxZipSize).contains(m.size)
            && m.version.range(of: #"^[0-9]+(\.[0-9]+){1,3}$"#, options: .regularExpression) != nil && m.build > 0
    }

    /// Version numbers compared part by part (0.1.10 is newer than 0.1.9), then the build number. Equal is not newer.
    static func isNewer(_ m: UpdateManifest, thanVersion version: String, build: Int) -> Bool {
        let c = compare(m.version, version)
        return c != 0 ? c > 0 : m.build > build
    }

    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Where the app leaves the update for the helper: outside the app's container, because macOS asks the user before one app
    /// may read another app's container.
    static func exchangeDirectory(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Caches/dev.feather.updater", isDirectory: true)
    }
}

/// The hand-off from the app to the helper (a file, because Launch Services drops launch arguments for sandboxed callers).
struct UpdateRequest: Codable {
    var manifest: String, signature: String, zip: String      // file names inside the exchange folder, never paths
    var target: String                                         // the app to replace
    var pid: Int32                                             // the running app that must quit first
    var relaunchArguments: [String]

    static let allowedArgumentPrefixes = ["--profile=", "--update-feed="]
}

struct UpdateStatus: Codable {
    var ok: Bool
    var from: String, to: String
    var message: String
    var time: Date
}
