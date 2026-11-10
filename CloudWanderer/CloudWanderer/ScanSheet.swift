// Apache 2 license - developer@infinitecontext.com

import AVFoundation
import CloudCore
import SwiftUI
import Vision
import VisionKit

/// Reads the setup code a Mac shows. Nothing connects from here: a scanned code is untrusted,
/// so it goes back to the form, where the person sees the server before entering a password.
struct ScanSheet: View {
    let onScanned: (ConnectionSetup) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    private var cameraIsRefused: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    ContentUnavailableView(
                        "Can't Scan Here", systemImage: "camera",
                        description: Text("This device can't scan codes, so enter the drive's details by hand."))
                } else if cameraIsRefused {
                    ContentUnavailableView(
                        "Camera Is Off", systemImage: "camera",
                        description: Text("Allow the camera for CloudWanderer in Settings, or enter the drive's details by hand."))
                } else {
                    CodeScanner(onFound: read)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let problem {
                    Text(problem)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func read(_ text: String) {
        do {
            onScanned(try ConnectionSetup(scanned: text))
            dismiss()
        } catch ConnectionSetup.SetupError.newerFormat {
            problem = "This code needs a newer CloudWanderer."
        } catch {
            problem = "That isn't a CloudAccess setup code."
        }
    }
}

private struct CodeScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFound: onFound)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (String) -> Void

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for case .barcode(let code) in addedItems {
                if let text = code.payloadStringValue {
                    onFound(text)
                    return
                }
            }
        }
    }
}
