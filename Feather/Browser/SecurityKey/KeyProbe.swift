#if DEBUG
import Foundation

/// `--keyprobe`: opens the first security key it sees, allocates a channel, and asks it for authenticatorGetInfo.
/// Needs no touch and changes nothing on the key. Prints "PROBE ..." lines so the result can be read from the log.
@MainActor final class KeyProbe {
    private let transport = HIDTransport()
    private var cid: UInt32 = CTAPHID.broadcastCID
    private var nonce = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
    private var reassembler = CTAPHID.Reassembler(cid: CTAPHID.broadcastCID)
    private var started = false

    static func run() {
        let probe = KeyProbe()
        keep = probe
        probe.begin()
    }
    private static var keep: KeyProbe?

    private func say(_ s: String) { print("PROBE " + s); fflush(stdout) }

    func begin() {
        transport.onChange = { [self] in
            say("devices: \(transport.devices.map(\.name))")
            if let d = transport.devices.first, !started { started = true; initialize(d) }
        }
        transport.onReport = { [self] dev, data in handle(dev, data) }
        transport.start()
        say("waiting for a security key (plug it in)...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [self] in say("timeout, no answer"); transport.stop(); exit(0) }
    }

    private func initialize(_ d: KeyDevice) {
        say("opened \(d.name); sending CTAPHID_INIT")
        for p in CTAPHID.packets(cid: CTAPHID.broadcastCID, command: .initialize, payload: nonce) { transport.send(p, to: d) }
    }

    private func handle(_ dev: KeyDevice, _ data: Data) {
        switch reassembler.feed(data) {
        case .needMore, .ignored: return
        case .malformed(let why): say("malformed: \(why)")
        case .message(let command, let payload):
            if cid == CTAPHID.broadcastCID, command == CTAPHID.Command.initialize.rawValue {
                guard payload.count >= 17, payload.prefix(8) == nonce else { return }
                cid = payload.dropFirst(8).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                say(String(format: "channel 0x%08X, protocol v%d, device %d.%d.%d, capabilities 0x%02X (bit 4 = no CTAP1, bit 2 = CBOR)",
                           cid, payload[12], payload[13], payload[14], payload[15], payload[16]))
                reassembler = CTAPHID.Reassembler(cid: cid)
                for p in CTAPHID.packets(cid: cid, command: .cbor, payload: Data([0x04])) { transport.send(p, to: dev) }   // authenticatorGetInfo
            } else if command == CTAPHID.Command.cbor.rawValue {
                guard let status = payload.first else { return }
                say("getInfo status 0x\(String(status, radix: 16))")
                if status == 0, let info = try? CBOR.decode(payload.dropFirst()) {
                    say("versions: \(info[1]?.arrayValue?.compactMap(\.textValue) ?? [])")
                    say("extensions: \(info[2]?.arrayValue?.compactMap(\.textValue) ?? [])")
                    if case .map(let opts)? = info[4] { say("options: " + opts.compactMap { e in e.key.textValue.map { "\($0)=\(e.value.boolValue.map(String.init) ?? "?")" } }.sorted().joined(separator: " ")) }
                    say("maxMsgSize: \(info[5]?.intValue.map(String.init) ?? "n/a")")
                    say("pinUvAuthProtocols: \(info[6]?.arrayValue?.compactMap(\.intValue) ?? [])")
                    say("maxCredentialCountInList: \(info[7]?.intValue.map(String.init) ?? "n/a")  maxCredentialIdLength: \(info[8]?.intValue.map(String.init) ?? "n/a")")
                    say("firmware: \(info[14]?.intValue.map(String.init) ?? "n/a")")
                }
                say("done"); transport.stop(); exit(0)
            } else if command == CTAPHID.Command.error.rawValue {
                say("device error 0x\(String(payload.first ?? 0, radix: 16))"); exit(1)
            }
        }
    }
}
#endif
