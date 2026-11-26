import SwiftUI
import VisionKit

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
