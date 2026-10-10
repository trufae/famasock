import SwiftUI
import AVFoundation

struct ScannerView: UIViewControllerRepresentable {
    let result: (Result<String, Error>) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(result: result) }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}
final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "famasock.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private let result: (Result<String, Error>) -> Void
    init(result: @escaping (Result<String, Error>) -> Void) { self.result = result; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let preview = AVCaptureVideoPreviewLayer(session: capture)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview); self.preview = preview
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else { DispatchQueue.main.async { self.finish(.failure(FamasockError(message: "Camera access denied. Paste an invitation or enable Camera in Settings."))) }; return }
            self.queue.async { self.configure() }
        }
    }
    private func configure() {
        do {
            guard let device = AVCaptureDevice.default(for: .video) else { throw FamasockError(message: "No camera available. Paste the invitation instead.") }
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureMetadataOutput()
            guard capture.canAddInput(input), capture.canAddOutput(output) else { throw FamasockError(message: "Cannot start QR scanner") }
            capture.addInput(input); capture.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            capture.startRunning()
        } catch { DispatchQueue.main.async { self.finish(.failure(error)) } }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); queue.async { self.capture.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let object = objects.first as? AVMetadataMachineReadableCodeObject, let text = object.stringValue,
              text.hasPrefix("famasock://pair?data=") else { return }
        finish(.success(text))
    }
    private func finish(_ value: Result<String, Error>) {
        guard !delivered else { return }; delivered = true
        queue.async { self.capture.stopRunning() }; result(value)
    }
}
