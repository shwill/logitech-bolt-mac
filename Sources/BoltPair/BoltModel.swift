import Foundation

enum PairingPhase: Equatable {
    case idle
    case searching
    case pairing(name: String)
    case passkey(name: String, code: String, keyboard: Bool)
    case done(name: String)
    case failed(String)
}

@MainActor
final class BoltModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var phase: PairingPhase = .idle
    @Published var errorMessage: String?

    private struct Candidate {
        var counter: Int?
        var kind: UInt8?
        var address: [UInt8]?
        var authentication: UInt8?
        var name: String?
        var pairing = false
    }

    private let receiver = BoltReceiver()
    private var candidate = Candidate()
    private let discoveryTimeout: UInt8 = 30

    init() {
        receiver.onConnectionChange = { [weak self] connected in self?.connectionChanged(connected) }
        receiver.onMessage = { [weak self] msg in self?.handle(msg) }
        receiver.start()
    }

    func refresh() async {
        do {
            devices = try await receiver.pairedDevices()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startPairing() {
        candidate = Candidate()
        phase = .searching
        Task {
            do {
                try await receiver.enableNotifications()
                try await receiver.discover(timeout: discoveryTimeout)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelPairing() {
        if phase == .searching {
            Task { try? await receiver.discover(timeout: discoveryTimeout, cancel: true) }
        }
        phase = .idle
    }

    func dismissPairing() {
        phase = .idle
    }

    func unpair(_ device: PairedDevice) {
        Task {
            do {
                try await receiver.unpair(slot: device.slot)
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    private func connectionChanged(_ connected: Bool) {
        self.connected = connected
        if connected {
            Task { await refresh() }
        } else {
            devices = []
            phase = .idle
        }
    }

    private func handle(_ msg: [UInt8]) {
        guard phase != .idle else { return }
        let sub = msg[2], address = msg[3]
        let data = Array(msg[4...])

        switch sub {
        case Hidpp.deviceDiscovered where phase == .searching && !candidate.pairing && data.count >= 15:
            let counter = Int(address) + Int(data[0]) * 256
            if candidate.counter == nil { candidate.counter = counter }
            guard candidate.counter == counter else { return }
            if data[1] == 0 {
                candidate.kind = data[3] & 0x0F
                candidate.address = Array(data[6..<12])
                candidate.authentication = data[14]
            } else if data[1] == 1 {
                candidate.name = String(decoding: data[3..<min(data.count, 3 + Int(data[2]))], as: UTF8.self)
            }
            if let kind = candidate.kind, let addr = candidate.address,
               let auth = candidate.authentication, let name = candidate.name {
                candidate.pairing = true
                phase = .pairing(name: name)
                Task {
                    do {
                        try await receiver.pair(address: addr, authentication: auth, entropy: kind == 1 ? 20 : 10)
                    } catch {
                        phase = .failed(error.localizedDescription)
                    }
                }
            }

        case Hidpp.discoveryStatus where address != 0 && phase == .searching:
            phase = .failed("No device in pairing mode was found.")

        case Hidpp.passkeyRequest where data.count >= 6:
            let code = String(decoding: data[0..<6], as: UTF8.self)
            phase = .passkey(name: candidate.name ?? "the device", code: code,
                             keyboard: (candidate.authentication ?? 0) & 0x01 != 0)

        case Hidpp.pairingStatus where address != 0 && candidate.pairing:
            let error = data[0]
            if error != 0 || address != 0x02 {
                phase = .failed(error == 1 ? "The device timed out." : "Pairing failed.")
            } else {
                phase = .done(name: candidate.name ?? "Device")
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await refresh()
                }
            }

        default:
            break
        }
    }
}
