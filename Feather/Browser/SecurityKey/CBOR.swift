import Foundation

/// A small CBOR (RFC 8949) value type: just what FIDO2 / WebAuthn needs, with strict limits on untrusted input.
/// Requests are encoded in the canonical form CTAP2 requires (shortest integers/lengths, map keys sorted by encoded
/// length then bytes, definite lengths only, no tags).
enum CBOR: Equatable {
    struct Entry: Equatable { var key: CBOR; var value: CBOR }

    case unsigned(UInt64)
    case negative(Int64)            // the actual (negative) value
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([Entry])
    case bool(Bool)
    case null
    case float(Double)

    static func int(_ v: Int) -> CBOR { v >= 0 ? .unsigned(UInt64(v)) : .negative(Int64(v)) }
    static func map(_ pairs: [(CBOR, CBOR)]) -> CBOR { .map(pairs.map { Entry(key: $0.0, value: $0.1) }) }

    // MARK: Lookup helpers for decoded maps

    subscript(key: Int) -> CBOR? { entry(.int(key)) }
    subscript(key: String) -> CBOR? { entry(.text(key)) }
    private func entry(_ key: CBOR) -> CBOR? {
        guard case .map(let entries) = self else { return nil }
        return entries.first { $0.key == key }?.value
    }
    var intValue: Int? {
        switch self { case .unsigned(let v): return v <= UInt64(Int.max) ? Int(v) : nil; case .negative(let v): return Int(v); default: return nil }
    }
    var dataValue: Data? { if case .bytes(let d) = self { return d }; return nil }
    var textValue: String? { if case .text(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [CBOR]? { if case .array(let a) = self { return a }; return nil }

    // MARK: Encoding

    func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    private static func head(_ major: UInt8, _ value: UInt64, into out: inout Data) {
        let m = major << 5
        switch value {
        case 0..<24: out.append(m | UInt8(value))
        case 24..<0x100: out.append(m | 24); out.append(UInt8(value))
        case 0x100..<0x10000: out.append(m | 25); out.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
        case 0x10000..<0x1_0000_0000:
            out.append(m | 26); for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
        default:
            out.append(m | 27); for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
        }
    }

    private func encode(into out: inout Data) {
        switch self {
        case .unsigned(let v): Self.head(0, v, into: &out)
        case .negative(let v): Self.head(1, UInt64(-1 - v), into: &out)
        case .bytes(let d): Self.head(2, UInt64(d.count), into: &out); out.append(d)
        case .text(let s): let d = Data(s.utf8); Self.head(3, UInt64(d.count), into: &out); out.append(d)
        case .array(let items): Self.head(4, UInt64(items.count), into: &out); items.forEach { $0.encode(into: &out) }
        case .map(let entries):
            Self.head(5, UInt64(entries.count), into: &out)
            let encoded = entries.map { (key: $0.key.encoded(), value: $0.value.encoded()) }
            // Canonical order: shorter encoded keys first, then bytewise.
            for e in encoded.sorted(by: { $0.key.count != $1.key.count ? $0.key.count < $1.key.count : $0.key.lexicographicallyPrecedes($1.key) }) {
                out.append(e.key); out.append(e.value)
            }
        case .bool(let b): out.append(b ? 0xF5 : 0xF4)
        case .null: out.append(0xF6)
        case .float(let d): out.append(0xFB); var bits = d.bitPattern.bigEndian; withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        }
    }

    // MARK: Decoding

    enum DecodeError: Error { case truncated, unsupported, tooDeep, tooLarge, trailingBytes }

    /// Decodes exactly one value. Input comes from a device, so depth and sizes are bounded.
    static func decode(_ data: Data) throws -> CBOR {
        var reader = Reader(data: data)
        let value = try reader.read(depth: 0)
        guard reader.offset == data.count else { throw DecodeError.trailingBytes }
        return value
    }

    private struct Reader {
        let data: Data
        var offset = 0
        init(data: Data) { self.data = Data(data) }          // re-base indices at 0

        mutating func byte() throws -> UInt8 {
            guard offset < data.count else { throw DecodeError.truncated }
            defer { offset += 1 }
            return data[offset]
        }
        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, offset + n <= data.count else { throw DecodeError.truncated }
            defer { offset += n }
            return data.subdata(in: offset..<offset + n)
        }
        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24: return UInt64(info)
            case 24: return UInt64(try byte())
            case 25: return try bytes(2).reduce(0) { $0 << 8 | UInt64($1) }
            case 26: return try bytes(4).reduce(0) { $0 << 8 | UInt64($1) }
            case 27: return try bytes(8).reduce(0) { $0 << 8 | UInt64($1) }
            default: throw DecodeError.unsupported            // indefinite lengths and reserved values
            }
        }
        mutating func read(depth: Int) throws -> CBOR {
            guard depth < 16 else { throw DecodeError.tooDeep }
            let initial = try byte()
            let major = initial >> 5, info = initial & 0x1F
            switch major {
            case 0: return .unsigned(try argument(info))
            case 1:
                let n = try argument(info)
                guard n <= UInt64(Int64.max) else { throw DecodeError.unsupported }
                return .negative(-1 - Int64(n))
            case 2, 3:
                let n = try argument(info)
                guard n <= 1_000_000 else { throw DecodeError.tooLarge }
                let d = try bytes(Int(n))
                if major == 2 { return .bytes(d) }
                guard let s = String(data: d, encoding: .utf8) else { throw DecodeError.unsupported }
                return .text(s)
            case 4:
                let n = try argument(info)
                guard n <= 10_000 else { throw DecodeError.tooLarge }
                return .array(try (0..<Int(n)).map { _ in try read(depth: depth + 1) })
            case 5:
                let n = try argument(info)
                guard n <= 10_000 else { throw DecodeError.tooLarge }
                var entries: [Entry] = []
                for _ in 0..<Int(n) { entries.append(Entry(key: try read(depth: depth + 1), value: try read(depth: depth + 1))) }
                return .map(entries)
            case 7:
                switch info {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22, 23: return .null
                case 25:                                         // half float
                    let b = try bytes(2); let h = UInt16(b[0]) << 8 | UInt16(b[1])
                    return .float(Double(Float16(bitPattern: h)))
                case 26: let b = try bytes(4); return .float(Double(Float(bitPattern: b.reduce(0) { $0 << 8 | UInt32($1) })))
                case 27: let b = try bytes(8); return .float(Double(bitPattern: b.reduce(0) { $0 << 8 | UInt64($1) }))
                default: throw DecodeError.unsupported
                }
            default: throw DecodeError.unsupported               // tags
            }
        }
    }
}
