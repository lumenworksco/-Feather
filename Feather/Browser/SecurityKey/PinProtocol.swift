import Foundation
import CryptoKit
import CommonCrypto

/// CTAP2 clientPin, PIN/UV auth protocol 1: ECDH key agreement, AES-256-CBC with a zero IV, HMAC-SHA-256 truncated to 16 bytes.
enum PinProtocolV1 {
    struct Session { let sharedSecret: Data; let platformKey: CBOR }

    static func aes(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        guard data.count % 16 == 0 else { throw CTAPError.transport("bad block size") }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { d in key.withUnsafeBytes { k in
            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, key.count,
                    [UInt8](repeating: 0, count: 16), d.baseAddress, data.count, o.baseAddress, o.count, &moved) } } }
        guard status == kCCSuccess else { throw CTAPError.transport("crypto failure") }
        return out.prefix(moved)
    }

    static func hmac16(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)).prefix(16))
    }

    /// Key agreement with the key (getKeyAgreement), producing the shared secret and our public key in COSE form.
    static func agree(_ device: CTAPDevice) async throws -> Session {
        let response = try await device.run(0x06, CBOR.map([(.int(1), .int(1)), (.int(2), .int(2))]))
        guard let cose = response?[1], let x = cose[-2]?.dataValue, let y = cose[-3]?.dataValue, x.count == 32, y.count == 32 else { throw CTAPError.transport("bad key agreement") }
        let theirs = try P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + x + y)
        let mine = P256.KeyAgreement.PrivateKey()
        let secret = try mine.sharedSecretFromKeyAgreement(with: theirs)
        let shared = Data(SHA256.hash(data: secret.withUnsafeBytes { Data($0) }))
        let pub = mine.publicKey.x963Representation
        let platform = CBOR.map([(.int(1), .int(2)), (.int(3), .int(-25)), (.int(-1), .int(1)),
                                 (.int(-2), .bytes(pub.subdata(in: 1..<33))), (.int(-3), .bytes(pub.subdata(in: 33..<65)))])
        return Session(sharedSecret: shared, platformKey: platform)
    }

    static func retries(_ device: CTAPDevice) async throws -> Int? {
        try await device.run(0x06, CBOR.map([(.int(1), .int(1)), (.int(2), .int(1))]))?[3]?.intValue
    }

    /// Trades the PIN for a pinToken (getPinToken). A wrong PIN costs one retry on the key: callers never repeat this on their own.
    static func token(_ device: CTAPDevice, pin: String) async throws -> Data {
        let session = try await agree(device)
        let pinHash = Data(SHA256.hash(data: Data(pin.precomposedStringWithCanonicalMapping.utf8))).prefix(16)
        let encrypted = try aes(Data(pinHash), key: session.sharedSecret, encrypt: true)
        let response = try await device.run(0x06, CBOR.map([(.int(1), .int(1)), (.int(2), .int(5)), (.int(3), session.platformKey), (.int(6), .bytes(encrypted))]))
        guard let tokenEnc = response?[2]?.dataValue else { throw CTAPError.transport("no pin token") }
        return try aes(tokenEnc, key: session.sharedSecret, encrypt: false)
    }
}
