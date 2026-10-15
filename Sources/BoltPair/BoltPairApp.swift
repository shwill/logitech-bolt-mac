import SwiftUI

@main
struct BoltPairApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = BoltModel()

    var body: some Scene {
        Window("Bolt Pair", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @ObservedObject var model: BoltModel
    @State private var pendingUnpair: PairedDevice?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.connected {
                deviceList
            } else {
                ContentUnavailableView("No Bolt Receiver", systemImage: "cable.connector.slash",
                                       description: Text("Plug in a Logi Bolt USB receiver."))
                    .frame(height: 200)
            }
            Divider()
            PairingPanel(model: model)
                .padding(16)
        }
        .frame(width: 380)
        .confirmationDialog("Unpair \(pendingUnpair?.name ?? "")?",
                            isPresented: Binding(get: { pendingUnpair != nil }, set: { if !$0 { pendingUnpair = nil } }),
                            presenting: pendingUnpair) { device in
            Button("Unpair", role: .destructive) { model.unpair(device) }
        } message: { _ in
            Text("The device will stop working with this receiver until you pair it again.")
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(model.connected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(model.connected ? "Logi Bolt Receiver" : "Not connected")
                .font(.headline)
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!model.connected)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var deviceList: some View {
        List {
            if model.devices.isEmpty {
                Text("No paired devices")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.devices) { device in
                HStack(spacing: 12) {
                    Image(systemName: icon(for: device.kind))
                        .font(.title2)
                        .frame(width: 32)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text("\(device.kindName) · Slot \(device.slot)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unpair") { pendingUnpair = device }
                        .disabled(model.phase != .idle)
                }
                .padding(.vertical, 4)
            }
        }
        .frame(height: 200)
    }

    private func icon(for kind: UInt8) -> String {
        switch kind {
        case 1, 3: "keyboard"
        case 2, 8: "computermouse"
        case 9: "rectangle.and.hand.point.up.left"
        default: "dot.radiowaves.left.and.right"
        }
    }
}

struct PairingPanel: View {
    @ObservedObject var model: BoltModel

    var body: some View {
        switch model.phase {
        case .idle:
            Button {
                model.startPairing()
            } label: {
                Label("Pair New Device", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.connected)

        case .searching:
            status(progress: true, "Searching…",
                   detail: "Hold an Easy-Switch or Connect button on the device for 3 seconds until it blinks fast.") {
                Button("Cancel") { model.cancelPairing() }
            }

        case .pairing(let name):
            status(progress: true, "Pairing \(name)…", detail: nil) { EmptyView() }

        case .passkey(let name, let code, let keyboard):
            VStack(spacing: 10) {
                if keyboard {
                    Text("Type this code on \(name), then press Return:")
                    Text(code)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("Click these buttons on \(name):")
                    HStack(spacing: 4) {
                        ForEach(Array(clicks(for: code).enumerated()), id: \.offset) { _, right in
                            Text(right ? "R" : "L")
                                .font(.system(.title3, design: .monospaced).weight(.semibold))
                                .frame(width: 26, height: 30)
                                .background(right ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    Text("then press left and right together.")
                }
            }
            .frame(maxWidth: .infinity)

        case .done(let name):
            status(icon: "checkmark.circle.fill", color: .green, "\(name) paired", detail: nil) {
                Button("Done") { model.dismissPairing() }
            }

        case .failed(let message):
            status(icon: "xmark.circle.fill", color: .red, message, detail: nil) {
                Button("Close") { model.dismissPairing() }
                Button("Try Again") { model.startPairing() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func clicks(for code: String) -> [Bool] {
        let binary = String(Int(code) ?? 0, radix: 2)
        let padded = String(repeating: "0", count: max(0, 10 - binary.count)) + binary
        return padded.map { $0 == "1" }
    }

    private func status<Actions: View>(progress: Bool = false, icon: String? = nil, color: Color = .primary,
                                       _ title: String, detail: String?,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if progress { ProgressView().controlSize(.small) }
                if let icon { Image(systemName: icon).foregroundStyle(color) }
                Text(title).font(.headline)
            }
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack { actions() }
        }
        .frame(maxWidth: .infinity)
    }
}
