/// The QR scanner.
///
/// Deliberately dumb: it reads codes and hands the string up. Deciding whether a
/// string is a valid pairing link belongs to the caller, which is also what lets
/// the scanner keep running after a bad read instead of tearing the camera down
/// and back up.

import AVFoundation
import SwiftUI

struct ScannerView: View {
    /// Return true to stop scanning; false to keep looking.
    let onCode: (String) -> Bool
    let onCancel: () -> Void

    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        ZStack {
            switch authorization {
            case .authorized:
                CameraLayer(onCode: onCode)
                    .ignoresSafeArea()
                Reticle()
            case .notDetermined:
                Placeholder(
                    icon: "camera",
                    title: "Point at the code",
                    detail: "Rowel needs the camera to read the pairing code on your Mac."
                ) {
                    // App Review (5.1.1(iv)) refuses a pre-permission button that
                    // asks for the grant; it has to read as moving on.
                    Button("Continue") {
                        AVCaptureDevice.requestAccess(for: .video) { granted in
                            Task { @MainActor in
                                authorization = granted ? .authorized : .denied
                            }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, Metrics.gutter)
                }
            default:
                Placeholder(
                    icon: "camera.fill",
                    title: "Camera is off for Rowel",
                    detail: "Turn it on in Settings, or type the code instead."
                ) {
                    Button("Open Settings") {
                        #if canImport(UIKit)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                        #endif
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.horizontal, Metrics.gutter)
                }
            }
        }
        .background(.black)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back", action: onCancel)
            }
        }
    }
}

/// The framing guide. A plain rounded square: anything more decorative competes
/// with the thing being scanned.
private struct Reticle: View {
    @State private var found = false

    var body: some View {
        VStack(spacing: Metrics.gutter) {
            Spacer()
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.9), lineWidth: 3)
                .frame(width: 240, height: 240)
                .shadow(color: .black.opacity(0.3), radius: 8)
            Text("Point at the QR code on your Mac")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .shadow(radius: 4)
            Spacer()
            Spacer()
        }
        .allowsHitTesting(false)
        .opacity(found ? 0 : 1)
    }
}

// MARK: - Camera

#if canImport(UIKit)
private struct CameraLayer: UIViewControllerRepresentable {
    let onCode: (String) -> Bool

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Bool)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    /// Set once a code has been accepted, so a code still in frame is not read
    /// a second time while the view is dismissing.
    private var stopped = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        stopped = false
        guard !session.isRunning else { return }
        // Starting a capture session blocks; doing it on the main thread stalls
        // the presentation animation for a visible beat.
        Task.detached(priority: .userInitiated) { [session] in
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard session.isRunning else { return }
        Task.detached(priority: .userInitiated) { [session] in
            session.stopRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !stopped,
              let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        guard onCode?(value) == true else { return }
        stopped = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task.detached(priority: .userInitiated) { [session] in
            session.stopRunning()
        }
    }
}
#else
private struct CameraLayer: View {
    let onCode: (String) -> Bool
    var body: some View { Color.black }
}
#endif
