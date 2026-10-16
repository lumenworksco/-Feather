import Foundation

/// CTAPHID framing (FIDO CTAP 2.1, "USB HID" transport): a message is split into 64-byte HID reports.
///   initialization packet: CID(4) | CMD|0x80 (1) | length (2, big endian) | up to 57 data bytes
///   continuation packet:   CID(4) | SEQ (1, 0...127)                       | up to 59 data bytes
enum CTAPHID {
    static let packetSize = 64
    static let broadcastCID: UInt32 = 0xFFFF_FFFF
    static let maxPayload = (packetSize - 7) + 128 * (packetSize - 5)       // 7609

    enum Command: UInt8 {
        case ping = 0x01, msg = 0x03, lock = 0x04, initialize = 0x06, wink = 0x08, cbor = 0x10, cancel = 0x11
        case keepalive = 0x3B, error = 0x3F
    }

    /// Splits a message into packets, each exactly `packetSize` bytes (zero padded).
    static func packets(cid: UInt32, command: Command, payload: Data) -> [Data] {
        precondition(payload.count <= maxPayload)
        var result: [Data] = []
        var first = Data()
        first.append(contentsOf: cid.bigEndianBytes)
        first.append(command.rawValue | 0x80)
        first.append(UInt8(payload.count >> 8)); first.append(UInt8(payload.count & 0xFF))
        let head = payload.prefix(packetSize - 7)
        first.append(head)
        result.append(pad(first))
        var offset = head.count, seq: UInt8 = 0
        while offset < payload.count {
            var cont = Data(cid.bigEndianBytes)
            cont.append(seq)
            let chunk = payload.dropFirst(offset).prefix(packetSize - 5)
            cont.append(chunk)
            result.append(pad(cont))
            offset += chunk.count; seq += 1
        }
        return result
    }

    private static func pad(_ d: Data) -> Data { d + Data(count: packetSize - d.count) }

    /// Reassembles one message from incoming packets (for one channel). Feed packets in; a result comes out when complete.
    struct Reassembler {
        let cid: UInt32
        private var command: UInt8?
        private var expected = 0
        private var buffer = Data()
        private var nextSeq: UInt8 = 0

        init(cid: UInt32) { self.cid = cid }

        enum Result: Equatable {
            case needMore
            case message(command: UInt8, payload: Data)      // command byte without the 0x80 bit
            case ignored                                      // a packet for another channel
            case malformed(String)
        }

        mutating func feed(_ packet: Data) -> Result {
            let p = Data(packet)
            guard p.count >= 5 else { return .malformed("short packet") }
            let packetCID = p.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard packetCID == cid else { return .ignored }
            let marker = p[4]
            if marker & 0x80 != 0 {                           // initialization packet
                guard p.count >= 7 else { return .malformed("short init packet") }
                command = marker & 0x7F
                expected = Int(p[5]) << 8 | Int(p[6])
                guard expected <= CTAPHID.maxPayload else { return .malformed("declared length too large") }
                buffer = p.dropFirst(7).prefix(expected)
                nextSeq = 0
            } else {
                guard command != nil else { return .malformed("continuation without initialization") }
                guard marker == nextSeq else { return .malformed("sequence error") }
                nextSeq += 1
                buffer.append(p.dropFirst(5).prefix(expected - buffer.count))
            }
            if buffer.count >= expected, let c = command {
                defer { command = nil; buffer = Data() }
                return .message(command: c, payload: Data(buffer))
            }
            return .needMore
        }
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)] }
}
