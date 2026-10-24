import RelayRemoteKit
import SwiftUI
import VisionKit

struct PairingView: View {
    let model: AppModel
    @State private var scanning = false
    @State private var pastedCode = ""

    var body: some View {
        Form {
            Section {
                Text("In Relay Runner on your Mac, open Settings, choose Relay Remote, then Pair a device. Scan the code it shows, or paste it if you copied it with Universal Clipboard.")
                    .font(.callout)
            }
            if let error = model.startupError {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            Section("Pairing code") {
                Button("Scan QR code", systemImage: "qrcode.viewfinder") { scanning = true }
                    .disabled(!QRScannerView.isAvailable || model.pairingState == .pairing)
                TextField("Paste pairing code", text: $pastedCode, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Pair with pasted code") { submit(pastedCode) }
                    .disabled(pastedCode.isEmpty || model.pairingState == .pairing)
            }
            switch model.pairingState {
            case .idle:
                EmptyView()
            case .pairing:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Confirm this iPhone on your Mac.")
                    }
                }
            case .failed(let message):
                Section { Label(message, systemImage: "xmark.octagon").foregroundStyle(.red) }
            }
            if let key = model.deviceKey {
                Section {
                    LabeledContent("Key", value: key.kind == .secureEnclaveP256 ? "Secure Enclave P-256" : "Keychain Ed25519")
                    Text(key.fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("This iPhone")
                } footer: {
                    Text("Your Mac shows this fingerprint before you allow the device.")
                }
            }
        }
        .navigationTitle("Pair Relay Remote")
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                scanning = false
                submit(code)
            }
            .ignoresSafeArea()
        }
    }

    private func submit(_ code: String) {
        Task {
            await model.pair(code: code)
            if model.paired != nil { pastedCode = "" }
        }
    }
}

/// VisionKit's QR scanner; the simulator and devices without it use paste.
struct QRScannerView: UIViewControllerRepresentable {
    /// Camera permission is requested when scanning starts, so only hardware support gates the button.
    static var isAvailable: Bool { DataScannerViewController.isSupported }

    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                guard !delivered, let code = barcode.payloadStringValue else { continue }
                delivered = true
                scanner.stopScanning()
                onCode(code)
            }
        }
    }
}
