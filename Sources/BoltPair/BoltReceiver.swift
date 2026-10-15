import Foundation
import IOKit.hid

enum Hidpp {
    static let vendorID = 0x046D
    static let productID = 0xC548
    static let receiver: UInt8 = 0xFF
    static let short: UInt8 = 0x10
    static let long: UInt8 = 0x11

    static let setShort: UInt8 = 0x80
    static let setLong: UInt8 = 0x82
    static let getLong: UInt8 = 0x83
    static let error: UInt8 = 0x8F

    static let regNotifications: UInt8 = 0x00
    static let regDiscovery: UInt8 = 0xC0
    static let regPairing: UInt8 = 0xC1
    static let regReceiverInfo: UInt8 = 0xB5
    static let infoPairing: UInt8 = 0x50
    static let infoName: UInt8 = 0x60
    static let maxSlots: UInt8 = 6

    static let passkeyRequest: UInt8 = 0x4D
    static let passkeyPressed: UInt8 = 0x4E
    static let deviceDiscovered: UInt8 = 0x4F
    static let discoveryStatus: UInt8 = 0x53
    static let pairingStatus: UInt8 = 0x54

    static let kinds: [UInt8: String] = [
        1: "Keyboard", 2: "Mouse", 3: "Numpad", 4: "Presenter", 7: "Remote",
        8: "Trackball", 9: "Touchpad", 10: "Tablet", 11: "Gamepad", 12: "Joystick", 13: "Headset",
    ]
    static let errors: [UInt8: String] = [
        1: "invalid sub-id", 2: "invalid address", 3: "invalid value", 4: "connection failed",
        5: "too many devices", 6: "already exists", 7: "busy", 8: "unknown device",
        9: "resource error", 10: "request unavailable", 11: "invalid parameter", 12: "wrong pin code",
    ]
}

struct PairedDevice: Identifiable, Equatable {
    let slot: UInt8
    let name: String
    let kind: UInt8
    let wpid: String
    let serial: String
    var id: UInt8 { slot }
    var kindName: String { Hidpp.kinds[kind] ?? "Device" }
}

enum BoltError: LocalizedError {
    case notConnected
    case io(IOReturn)
    case hidpp(UInt8)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: "The Bolt receiver is not connected."
        case .io(let code): String(format: "I/O error 0x%08x", code)
        case .hidpp(let code): "Receiver error: \(Hidpp.errors[code] ?? String(format: "0x%02x", code))"
        case .timeout: "The receiver did not respond."
        }
    }
}

@MainActor
final class BoltReceiver {
    var onConnectionChange: (@MainActor (Bool) -> Void)?
    var onMessage: (@MainActor ([UInt8]) -> Void)?

    private struct Waiter {
        let sub: UInt8
        let address: UInt8
        let token: Int
        let continuation: CheckedContinuation<[UInt8], Error>
    }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private var waiter: Waiter?
    private var nextToken = 0

    func start() {
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: Hidpp.vendorID,
            kIOHIDProductIDKey: Hidpp.productID,
            kIOHIDPrimaryUsagePageKey: 0xFF00,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let me = Unmanaged<BoltReceiver>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { me.attach(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let me = Unmanaged<BoltReceiver>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { me.detach(device) }
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, _, _, reportID, report, length in
            let me = Unmanaged<BoltReceiver>.fromOpaque(context!).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            MainActor.assumeIsolated { me.receive(bytes, reportID: UInt8(truncatingIfNeeded: reportID)) }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ device: IOHIDDevice) {
        guard self.device == nil else { return }
        self.device = device
        onConnectionChange?(true)
    }

    private func detach(_ device: IOHIDDevice) {
        guard let current = self.device, CFEqual(current, device) else { return }
        self.device = nil
        if let w = waiter {
            waiter = nil
            w.continuation.resume(throwing: BoltError.notConnected)
        }
        onConnectionChange?(false)
    }

    private func receive(_ raw: [UInt8], reportID: UInt8) {
        let msg = raw.first == reportID ? raw : [reportID] + raw
        guard msg.count >= 7, msg[0] == Hidpp.short || msg[0] == Hidpp.long, msg[1] == Hidpp.receiver else { return }
        if let w = waiter {
            if msg[2] == Hidpp.error, msg[3] == w.sub, msg[4] == w.address {
                waiter = nil
                w.continuation.resume(throwing: BoltError.hidpp(msg[5]))
                return
            }
            if msg[2] == w.sub, msg[3] == w.address {
                waiter = nil
                w.continuation.resume(returning: Array(msg[4...]))
                return
            }
        }
        onMessage?(msg)
    }

    func request(_ sub: UInt8, _ address: UInt8, _ params: [UInt8] = [], long: Bool = false) async throws -> [UInt8] {
        while waiter != nil { try await Task.sleep(for: .milliseconds(20)) }
        guard let device else { throw BoltError.notConnected }

        let isLong = long || params.count > 3
        var msg: [UInt8] = [isLong ? Hidpp.long : Hidpp.short, Hidpp.receiver, sub, address] + params
        msg += [UInt8](repeating: 0, count: (isLong ? 20 : 7) - msg.count)
        nextToken += 1
        let token = nextToken

        return try await withCheckedThrowingContinuation { continuation in
            MainActor.assumeIsolated {
                waiter = Waiter(sub: sub, address: address, token: token, continuation: continuation)
                let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(msg[0]), msg, msg.count)
                if result != kIOReturnSuccess {
                    waiter = nil
                    continuation.resume(throwing: BoltError.io(result))
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, let w = self.waiter, w.token == token else { return }
                    self.waiter = nil
                    w.continuation.resume(throwing: BoltError.timeout)
                }
            }
        }
    }

    func pairedDevices() async throws -> [PairedDevice] {
        var found: [PairedDevice] = []
        for slot in 1...Hidpp.maxSlots {
            let info: [UInt8]
            do {
                info = try await request(Hidpp.getLong, Hidpp.regReceiverInfo, [Hidpp.infoPairing + slot])
            } catch BoltError.hidpp {
                continue
            }
            var name = "Unknown device"
            if let raw = try? await request(Hidpp.getLong, Hidpp.regReceiverInfo, [Hidpp.infoName + slot, 0x01]),
               raw.count > 3 {
                name = String(decoding: raw[3..<min(raw.count, 3 + Int(raw[2]))], as: UTF8.self)
            }
            found.append(PairedDevice(
                slot: slot,
                name: name,
                kind: info[1] & 0x0F,
                wpid: String(format: "%02X%02X", info[3], info[2]),
                serial: info[4..<8].map { String(format: "%02X", $0) }.joined()
            ))
        }
        return found
    }

    func enableNotifications() async throws {
        _ = try await request(Hidpp.setShort, Hidpp.regNotifications, [0x00, 0x09, 0x00])
    }

    func discover(timeout: UInt8, cancel: Bool = false) async throws {
        _ = try await request(Hidpp.setShort, Hidpp.regDiscovery, [timeout, cancel ? 0x02 : 0x01])
    }

    func pair(address: [UInt8], authentication: UInt8, entropy: UInt8) async throws {
        _ = try await request(Hidpp.setLong, Hidpp.regPairing, [0x01, 0x00] + address + [authentication, entropy], long: true)
    }

    func unpair(slot: UInt8) async throws {
        _ = try await request(Hidpp.setLong, Hidpp.regPairing, [0x03, slot] + [UInt8](repeating: 0, count: 6), long: true)
    }
}
