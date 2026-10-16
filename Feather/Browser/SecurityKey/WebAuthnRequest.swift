import Foundation
import CryptoKit

struct WebAuthnError: Error {
    let name: String, message: String
    static func notAllowed(_ m: String = "The operation either timed out or was not allowed.") -> Self { .init(name: "NotAllowedError", message: m) }
    static func security(_ m: String) -> Self { .init(name: "SecurityError", message: m) }
    static func invalid(_ m: String) -> Self { .init(name: "TypeError", message: m) }
    static func notSupported(_ m: String) -> Self { .init(name: "NotSupportedError", message: m) }
}

enum Base64URL {
    static func encode(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t)
    }
}

/// Where a request comes from. Always taken from WebKit's own frame information, never from what the page claims.
struct CallerOrigin: Equatable {
    let scheme: String, host: String, port: Int          // port 0 = the scheme's default

    var string: String {
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(host)" + (port != 0 && port != defaultPort ? ":\(port)" : "")
    }
    /// https, or plain http on this machine (for development and tests).
    var isSecureContext: Bool { scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".localhost"))) }

    /// The relying-party id (the site identity) must be the caller's host or a parent domain of it, and never a public suffix.
    func validate(rpId: String) -> Bool {
        let rp = rpId.lowercased(), h = host.lowercased()
        guard !rp.isEmpty, !rp.contains(":"), !rp.contains("/"), rp == rpId else { return false }
        if rp == h { return rp == "localhost" || (!PublicSuffix.isIPAddress(rp) && !PublicSuffix.shared.isPublicSuffix(rp)) }
        return h.hasSuffix("." + rp) && !PublicSuffix.isIPAddress(h) && !PublicSuffix.shared.isPublicSuffix(rp)
    }

    /// FIDO AppID rule: an https URL on the same registrable domain as the caller.
    func validate(appID: String) -> Bool {
        guard let url = URL(string: appID), url.scheme == "https", let h = url.host?.lowercased(),
              let a = PublicSuffix.shared.registrableDomain(h), let b = PublicSuffix.shared.registrableDomain(host) else { return false }
        return a == b
    }
}

struct ClientData {
    let json: Data
    var hash: Data { Data(SHA256.hash(data: json)) }

    init(type: String, challenge: Data, origin: String) {
        func quoted(_ s: String) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            return (try? String(data: encoder.encode(s), encoding: .utf8)) ?? "\"\""
        }
        json = Data("{\"type\":\(quoted(type)),\"challenge\":\"\(Base64URL.encode(challenge))\",\"origin\":\(quoted(origin)),\"crossOrigin\":false}".utf8)
    }
}

struct GetRequest {
    var challenge: Data, rpId: String, allow: [Data], appID: String?, userVerification: String, timeout: TimeInterval

    init(_ o: [String: Any], origin: CallerOrigin) throws {
        guard let c = (o["challenge"] as? String).flatMap(Base64URL.decode) else { throw WebAuthnError.invalid("challenge is missing") }
        challenge = c
        rpId = (o["rpId"] as? String) ?? origin.host
        allow = ((o["allowCredentials"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) == "public-key" }.compactMap { ($0["id"] as? String).flatMap(Base64URL.decode) }
        appID = (o["extensions"] as? [String: Any])?["appid"] as? String
        userVerification = (o["userVerification"] as? String) ?? "preferred"
        timeout = Self.clamp(o["timeout"])
    }
    static func clamp(_ v: Any?) -> TimeInterval { min(max(((v as? Double) ?? 120_000) / 1000, 20), 300) }
}

struct CreateRequest {
    var challenge: Data, rpId: String, rpName: String, userID: Data, userName: String, userDisplayName: String
    var algorithms: [Int], exclude: [Data], residentKey: Bool, userVerification: String, timeout: TimeInterval

    init(_ o: [String: Any], origin: CallerOrigin) throws {
        guard let c = (o["challenge"] as? String).flatMap(Base64URL.decode) else { throw WebAuthnError.invalid("challenge is missing") }
        challenge = c
        let rp = o["rp"] as? [String: Any] ?? [:]
        rpId = (rp["id"] as? String) ?? origin.host
        rpName = (rp["name"] as? String) ?? rpId
        guard let user = o["user"] as? [String: Any], let uid = (user["id"] as? String).flatMap(Base64URL.decode), (1...64).contains(uid.count) else { throw WebAuthnError.invalid("user.id is invalid") }
        userID = uid
        userName = (user["name"] as? String) ?? ""
        userDisplayName = (user["displayName"] as? String) ?? ""
        let params = ((o["pubKeyCredParams"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) == "public-key" }.compactMap { ($0["alg"] as? Double).map(Int.init) }
        algorithms = (o["pubKeyCredParams"] as? [Any])?.isEmpty == false ? params : [-7, -257]
        guard !algorithms.isEmpty else { throw WebAuthnError.notSupported("no supported public-key algorithm was requested") }
        exclude = ((o["excludeCredentials"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) == "public-key" }.compactMap { ($0["id"] as? String).flatMap(Base64URL.decode) }
        let sel = o["authenticatorSelection"] as? [String: Any] ?? [:]
        residentKey = (sel["residentKey"] as? String) == "required" || (sel["requireResidentKey"] as? Bool) == true
        userVerification = (sel["userVerification"] as? String) ?? "preferred"
        timeout = GetRequest.clamp(o["timeout"])
    }
}

enum COSE {
    /// DER SubjectPublicKeyInfo for an ES256 (P-256) COSE key, as WebAuthn's getPublicKey() returns.
    static func spki(_ key: CBOR?) -> Data? {
        guard let key, key[3]?.intValue == -7, let x = key[-2]?.dataValue, let y = key[-3]?.dataValue, x.count == 32, y.count == 32 else { return nil }
        let prefix: [UInt8] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04]
        return Data(prefix) + x + y
    }
}
