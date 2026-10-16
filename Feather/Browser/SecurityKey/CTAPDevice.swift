import Foundation
import CryptoKit

/// What the key says it can do (authenticatorGetInfo).
struct AuthenticatorInfo {
    var versions: [String] = []
    var options: [String: Bool] = [:]
    var pinProtocols: [Int] = []
    var maxCredentialCountInList: Int?
    var maxCredentialIdLength: Int?

    init(_ cbor: CBOR) {
        versions = cbor[1]?.arrayValue?.compactMap(\.textValue) ?? []
        if case .map(let entries)? = cbor[4] { for e in entries { if let k = e.key.textValue, let v = e.value.boolValue { options[k] = v } } }
        pinProtocols = cbor[6]?.arrayValue?.compactMap(\.intValue) ?? []
        maxCredentialCountInList = cbor[7]?.intValue
        maxCredentialIdLength = cbor[8]?.intValue
    }
    var pinIsSet: Bool { options["clientPin"] == true }
    var canResidentKey: Bool { options["rk"] == true }
}

struct Assertion {
    var credentialID: Data
    var authData: Data
    var signature: Data
    var userHandle: Data?
    var userName: String?
    var count: Int
}

/// One key, one channel: the CTAP2 commands the browser needs.
@MainActor final class CTAPDevice {
    let client: CTAPClient
    let device: KeyDevice
    let cid: UInt32
    private(set) var info: AuthenticatorInfo
    var onTouchNeeded: () -> Void = {}

    static func open(_ client: CTAPClient, _ device: KeyDevice) async throws -> CTAPDevice {
        let cid = try await client.allocateChannel(on: device)
        guard let infoCBOR = try await client.ctap2(device, cid: cid, command: 0x04) else { throw CTAPError.transport("no info") }
        return CTAPDevice(client: client, device: device, cid: cid, info: AuthenticatorInfo(infoCBOR))
    }
    private init(client: CTAPClient, device: KeyDevice, cid: UInt32, info: AuthenticatorInfo) { self.client = client; self.device = device; self.cid = cid; self.info = info }

    func run(_ command: UInt8, _ params: CBOR?) async throws -> CBOR? {
        try await client.ctap2(device, cid: cid, command: command, params: params) { [weak self] status in
            if status == 2 { self?.onTouchNeeded() }
        }
    }

    private static func descriptor(_ id: Data) -> CBOR { .map([(.text("id"), .bytes(id)), (.text("type"), .text("public-key"))]) }

    /// Credentials that don't fit the key's limits are skipped, like other browsers do.
    func usable(_ ids: [Data]) -> [Data] {
        guard let limit = info.maxCredentialIdLength else { return ids }
        return ids.filter { $0.count <= limit }
    }

    /// The key's cap on a credential list (at least 1); longer lists are tried in chunks.
    var listLimit: Int { max(1, info.maxCredentialCountInList ?? 1) }

    private func auth(_ token: Data?, _ clientDataHash: Data) -> [(CBOR, CBOR)] {
        guard let token else { return [] }
        return [(.int(0x06), .bytes(PinProtocolV1.hmac16(token, clientDataHash))), (.int(0x07), .int(1))]
    }

    // MARK: Signing in

    /// Which of these credentials does the key hold for this site? Asks without requiring a touch.
    /// Returns nil when the key refuses to answer this way (then the caller just tries the real request).
    func probe(rpId: String, clientDataHash: Data, allow: [Data]) async throws -> Data?? {
        let params = CBOR.map([(.int(1), .text(rpId)), (.int(2), .bytes(clientDataHash)), (.int(3), .array(allow.map(Self.descriptor))),
                               (.int(5), .map([(.text("up"), .bool(false))]))])
        do {
            let response = try await run(0x02, params)
            return .some(response?[1]?["id"]?.dataValue)
        } catch CTAPError.status(let s) where s == CTAPError.noCredentials { return .some(nil) }
          catch CTAPError.status(let s) where s == 0x2C || s == 0x2B || s == 0x12 { return nil }
    }

    func getAssertion(rpId: String, clientDataHash: Data, allow: [Data], pinToken: Data?) async throws -> [Assertion] {
        var entries: [(CBOR, CBOR)] = [(.int(1), .text(rpId)), (.int(2), .bytes(clientDataHash))]
        if !allow.isEmpty { entries.append((.int(3), .array(allow.map(Self.descriptor)))) }
        entries += auth(pinToken, clientDataHash)
        guard let first = try await run(0x02, .map(entries)), let a = Self.assertion(first) else { throw CTAPError.transport("unreadable assertion") }
        var all = [a]
        if a.count > 1 {
            for _ in 1..<min(a.count, 20) {
                guard let next = try await run(0x08, nil), let n = Self.assertion(next) else { break }
                all.append(n)
            }
        }
        return all
    }

    private static func assertion(_ c: CBOR) -> Assertion? {
        guard let id = c[1]?["id"]?.dataValue, let authData = c[2]?.dataValue, let sig = c[3]?.dataValue else { return nil }
        return Assertion(credentialID: id, authData: authData, signature: sig, userHandle: c[4]?["id"]?.dataValue,
                         userName: c[4]?["displayName"]?.textValue ?? c[4]?["name"]?.textValue, count: c[5]?.intValue ?? 1)
    }

    // MARK: Registering

    struct Registration { var authData: Data; var credentialID: Data; var publicKey: CBOR? }

    func makeCredential(clientDataHash: Data, rpId: String, rpName: String, userID: Data, userName: String, userDisplayName: String,
                        algorithms: [Int], exclude: [Data], residentKey: Bool, pinToken: Data?) async throws -> Registration {
        var user: [(CBOR, CBOR)] = [(.text("id"), .bytes(userID)), (.text("name"), .text(userName))]
        if !userDisplayName.isEmpty { user.append((.text("displayName"), .text(userDisplayName))) }
        var entries: [(CBOR, CBOR)] = [
            (.int(1), .bytes(clientDataHash)),
            (.int(2), .map([(.text("id"), .text(rpId)), (.text("name"), .text(rpName))])),
            (.int(3), .map(user)),
            (.int(4), .array(algorithms.map { .map([(.text("alg"), .int($0)), (.text("type"), .text("public-key"))]) }))]
        if !exclude.isEmpty { entries.append((.int(5), .array(exclude.map(Self.descriptor)))) }
        if residentKey { entries.append((.int(7), .map([(.text("rk"), .bool(true))]))) }
        entries += auth(pinToken, clientDataHash).map { ($0.0.intValue == 0x06 ? .int(8) : .int(9), $0.1) }
        guard let response = try await run(0x01, .map(entries)), var authData = response[2]?.dataValue, authData.count >= 55 else { throw CTAPError.transport("unreadable registration") }
        let (id, key) = try Self.attested(authData)
        // Attestation is not passed on (format "none"), so the model identifier (AAGUID) is blanked as well.
        authData.replaceSubrange(37..<53, with: Data(count: 16))
        return Registration(authData: authData, credentialID: id, publicKey: key)
    }

    /// Credential id and public key out of the attested-credential-data part of authenticator data.
    static func attested(_ authData: Data) throws -> (Data, CBOR?) {
        let d = Data(authData)
        guard d.count >= 55, d[32] & 0x40 != 0 else { throw CTAPError.transport("no credential data") }
        let idLength = Int(d[53]) << 8 | Int(d[54])
        guard d.count >= 55 + idLength else { throw CTAPError.transport("short credential data") }
        let id = d.subdata(in: 55..<55 + idLength)
        // The COSE key follows the id; decode just that one item (extension data may follow it).
        let rest = d.dropFirst(55 + idLength)
        for end in stride(from: rest.count, through: 1, by: -1) { if let k = try? CBOR.decode(rest.prefix(end)) { return (id, k) } }
        return (id, nil)
    }
}
