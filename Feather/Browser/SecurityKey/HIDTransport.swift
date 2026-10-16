import Foundation
import IOKit.hid

/// Talks to FIDO security keys over USB HID. Matches only the FIDO usage page (0xF1D0), so the key's keyboard
/// interface (used for one-time codes) is never opened and no Input Monitoring permission is involved.
struct KeyDevice: Equatable { let id: Int; let name: String }

/// What the CTAP layer needs from a transport, so tests can swap in a software authenticator.
protocol KeyTransport: AnyObject {
    var devices: [KeyDevice] { get }
    var onReport: ((KeyDevice, Data) -> Void)? { get set }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
    @discardableResult func send(_ packet: Data, to device: KeyDevice) -> Bool
}

final class HIDTransport: KeyTransport {
    typealias Device = KeyDevice
    private var refs: [Int: IOHIDDevice] = [:]
    private var nextID = 1

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private(set) var devices: [KeyDevice] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    /// Called on the main thread for each 64-byte report, with the device it came from.
    var onReport: ((KeyDevice, Data) -> Void)?
    var onChange: (() -> Void)?

    func start() {
        let match: [String: Any] = [kIOHIDPrimaryUsagePageKey: 0xF1D0, kIOHIDPrimaryUsageKey: 0x01]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().added(device)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().removed(device)
        }, me)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if status != kIOReturnSuccess { Self.note("IOHIDManagerOpen failed: 0x\(String(UInt32(bitPattern: status), radix: 16))") }
    }

    func stop() {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        buffers.forEach { $0.deallocate() }; buffers = []; devices = []; refs = [:]
    }

    private func added(_ ref: IOHIDDevice) {
        let name = (IOHIDDeviceGetProperty(ref, kIOHIDProductKey as CFString) as? String) ?? "security key"
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: CTAPHID.packetSize)
        buffers.append(buffer)
        let device = KeyDevice(id: nextID, name: name)
        nextID += 1
        refs[device.id] = ref
        devices.append(device)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(ref, buffer, CTAPHID.packetSize, { ctx, _, sender, _, _, report, length in
            let t = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
            guard let sender, let dev = t.devices.first(where: { t.refs[$0.id].map { Unmanaged.passUnretained($0).toOpaque() == sender } ?? false }) else { return }
            t.onReport?(dev, Data(bytes: report, count: length))
        }, me)
        onChange?()
    }

    private func removed(_ ref: IOHIDDevice) {
        if let id = refs.first(where: { $0.value === ref })?.key { refs[id] = nil; devices.removeAll { $0.id == id } }
        onChange?()
    }

    @discardableResult
    func send(_ packet: Data, to device: KeyDevice) -> Bool {
        precondition(packet.count == CTAPHID.packetSize)
        guard let ref = refs[device.id] else { return false }
        let r = packet.withUnsafeBytes { IOHIDDeviceSetReport(ref, kIOHIDReportTypeOutput, 0, $0.bindMemory(to: UInt8.self).baseAddress!, packet.count) }
        if r != kIOReturnSuccess { Self.note("send failed: 0x\(String(UInt32(bitPattern: r), radix: 16))") }
        return r == kIOReturnSuccess
    }

    static func note(_ s: String) { FileHandle.standardError.write(Data(("KEY " + s + "\n").utf8)) }
}
