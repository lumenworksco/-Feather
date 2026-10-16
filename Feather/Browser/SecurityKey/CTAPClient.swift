import Foundation

enum CTAPError: Error, Equatable {
    case status(UInt8)                 // an error code from the key (CTAP2 status byte)
    case noDevice, cancelled
    case transport(String)

    /// CTAP2 status codes we give special meaning to.
    static let noCredentials: UInt8 = 0x2E, credentialExcluded: UInt8 = 0x19, unsupportedAlgorithm: UInt8 = 0x26
    static let pinInvalid: UInt8 = 0x31, pinBlocked: UInt8 = 0x32, pinAuthInvalid: UInt8 = 0x33, pinAuthBlocked: UInt8 = 0x34
    static let pinNotSet: UInt8 = 0x35, pinRequired: UInt8 = 0x36, operationDenied: UInt8 = 0x27, userActionTimeout: UInt8 = 0x2F
    static let keepaliveCancel: UInt8 = 0x2D, uvBlocked: UInt8 = 0x3C
}

/// Sends CTAPHID messages over a `KeyTransport` and waits for the answers, one exchange at a time.
@MainActor final class CTAPClient {
    let transport: KeyTransport

    private struct Pending {
        let device: KeyDevice
        var reassembler: CTAPHID.Reassembler
        let nonce: Data?                                   // set while allocating a channel
        let keepalive: (UInt8) -> Void
        let finish: (Result<(UInt8, Data), CTAPError>) -> Void
    }
    private var pending: Pending?
    private var deviceWaiters: [(Result<Void, CTAPError>) -> Void] = []
    /// Called whenever a key is plugged in or removed (the sheet uses it to update its wording).
    var onDevicesChanged: (() -> Void)?

    init(transport: KeyTransport) {
        self.transport = transport
        transport.onReport = { [weak self] device, data in MainActor.assumeIsolated { self?.received(device, data) } }
        transport.onChange = { [weak self] in MainActor.assumeIsolated { self?.devicesChanged() } }
        transport.start()
    }

    func shutdown() { cancelAll(); transport.stop() }

    var devices: [KeyDevice] { transport.devices }

    // MARK: Waiting for a key

    func waitForDevice() async throws -> KeyDevice {
        while true {
            if let d = transport.devices.first { return d }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                deviceWaiters.append { c.resume(with: $0) }
            }
        }
    }

    /// Waits until the set of connected keys changes (used after "this key is not registered here").
    func waitForChange() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in deviceWaiters.append { c.resume(with: $0) } }
    }

    private func devicesChanged() {
        if let p = pending, !transport.devices.contains(p.device) { pending = nil; p.finish(.failure(.noDevice)) }
        let waiters = deviceWaiters; deviceWaiters = []
        waiters.forEach { $0(.success(())) }
        onDevicesChanged?()
    }

    // MARK: Exchanges

    /// Allocates a fresh channel (CTAPHID_INIT). A fresh channel per request also drops any stale answers from an earlier, cancelled one.
    func allocateChannel(on device: KeyDevice) async throws -> UInt32 {
        let nonce = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let (_, payload) = try await exchange(device, cid: CTAPHID.broadcastCID, command: .initialize, payload: nonce, nonce: nonce) { _ in }
        guard payload.count >= 17 else { throw CTAPError.transport("short INIT response") }
        return payload.dropFirst(8).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    /// Runs one CTAP2 command. Returns the decoded response map (nil when the key answers with no data).
    func ctap2(_ device: KeyDevice, cid: UInt32, command: UInt8, params: CBOR? = nil, onKeepAlive: @escaping (UInt8) -> Void = { _ in }) async throws -> CBOR? {
        var payload = Data([command])
        if let params { payload.append(params.encoded()) }
        let (_, response) = try await exchange(device, cid: cid, command: .cbor, payload: payload, nonce: nil, keepalive: onKeepAlive)
        guard let status = response.first else { throw CTAPError.transport("empty CBOR response") }
        guard status == 0 else { throw CTAPError.status(status) }
        if response.count == 1 { return nil }
        do { return try CBOR.decode(response.dropFirst()) } catch { throw CTAPError.transport("unreadable response") }
    }

    private func exchange(_ device: KeyDevice, cid: UInt32, command: CTAPHID.Command, payload: Data, nonce: Data?, keepalive: @escaping (UInt8) -> Void) async throws -> (UInt8, Data) {
        guard transport.devices.contains(device) else { throw CTAPError.noDevice }
        guard pending == nil else { throw CTAPError.transport("another request is in progress") }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<(UInt8, Data), Error>) in
            pending = Pending(device: device, reassembler: .init(cid: cid), nonce: nonce, keepalive: keepalive) { c.resume(with: $0) }
            for packet in CTAPHID.packets(cid: cid, command: command, payload: payload) {
                if !transport.send(packet, to: device) { pending = nil; c.resume(throwing: CTAPError.transport("could not write to the key")); return }
            }
        }
    }

    private func received(_ device: KeyDevice, _ data: Data) {
        guard var p = pending, p.device == device else { return }
        switch p.reassembler.feed(data) {
        case .ignored: return
        case .needMore: pending = p
        case .malformed(let why): pending = nil; p.finish(.failure(.transport(why)))
        case .message(let command, let payload):
            if command == CTAPHID.Command.keepalive.rawValue { pending = p; if let s = payload.first { p.keepalive(s) }; return }
            if let nonce = p.nonce, payload.prefix(8) != nonce { pending = p; return }      // someone else's INIT answer
            pending = nil
            if command == CTAPHID.Command.error.rawValue { p.finish(.failure(.transport("key reported CTAPHID error 0x" + String(payload.first ?? 0, radix: 16)))) }
            else { p.finish(.success((command, payload))) }
        }
    }

    /// Asks the key to stop waiting (CTAPHID_CANCEL has no answer) and fails whatever is being waited for.
    func cancelAll() {
        if let p = pending {
            pending = nil
            transport.send(CTAPHID.packets(cid: p.reassembler.cid, command: .cancel, payload: Data())[0], to: p.device)
            p.finish(.failure(.cancelled))
        }
        let waiters = deviceWaiters; deviceWaiters = []
        waiters.forEach { $0(.failure(.cancelled)) }
    }
}
