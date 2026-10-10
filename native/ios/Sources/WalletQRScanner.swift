#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit

struct WalletQRScanner: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack(alignment: .top) {
            CameraScanner(onScan: onScan).ignoresSafeArea()
            HStack {
                Text("Scan recipient address").font(.headline)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.plain)
            }.padding(20).background(.black.opacity(0.7))
        }.preferredColorScheme(.dark)
    }
}

private struct CameraScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan
        return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.zkool.qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private var active = true
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    if allowed { self?.configure() } else { self?.unavailable() }
                }
            }
        default: unavailable()
        }
    }
    private func configure() {
        guard active else { return }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), capture.canAddInput(input) else {
            unavailable(); return
        }
        capture.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard capture.canAddOutput(output) else { unavailable(); return }
        capture.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: capture)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
        preview.frame = view.bounds
        let session = capture
        queue.async { session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { active = false; let session = capture; queue.async { if session.isRunning { session.stopRunning() } } }
    private func unavailable() {
        let label = UILabel()
        label.text = "Camera unavailable. Enable camera access in Settings, or paste the address in the payment screen."
        label.numberOfLines = 0; label.textColor = .white; label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        delivered = true; stop(); onScan?(value)
    }
}
#endif
