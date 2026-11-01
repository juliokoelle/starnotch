import AVFoundation
import AppKit
import NotchCore
import Observation
import SwiftUI

/// The camera for Check camera: the front camera into a mirrored preview layer and nothing else.
/// The session has no output, so no frame is ever recorded, saved or sent. Start and stop run on
/// a queue of their own (AVCaptureSession blocks while it does); a stop also takes the camera's
/// input away, so the camera light goes out at once. Previews and the test mode show a drawn
/// picture instead (`simulated`), and macOS is never asked.
@MainActor
@Observable
final class CameraMirror {
    enum Status: Equatable { case off, starting, running, noCamera }

    private(set) var status = Status.off
    @ObservationIgnored var simulated = false
    @ObservationIgnored private let capture = Capture()
    /// Shown by `CameraPreview`; it only holds the session.
    @ObservationIgnored private(set) lazy var layer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: capture.session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()
    /// A stop clicked before the camera came up wins over the start's late answer.
    @ObservationIgnored private var round = 0

    var access: CameraCheck.Access {
        simulated ? .allowed : CameraCheck.Access(status: AVCaptureDevice.authorizationStatus(for: .video).rawValue)
    }

    /// macOS's dialog, the first time only; answers on the main actor.
    func requestAccess(_ done: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in done(granted) }
        }
    }

    func start() {
        round += 1
        guard !simulated else { status = .running; return }
        let round = round
        status = .starting
        capture.start { [weak self] running in
            Task { @MainActor in
                guard let self, self.round == round else { return }
                self.status = running ? .running : .noCamera
                // The front camera as in a mirror, the way people know themselves.
                if running, let connection = self.layer.connection, connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
        }
    }

    func stop() {
        round += 1
        status = .off
        guard !simulated else { return }
        capture.stop()
    }

    /// The session, touched only on its own queue (the preview layer merely holds it).
    private final class Capture: @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "app.starnotch.camera-check")

        func start(_ done: @escaping @Sendable (Bool) -> Void) {
            queue.async { [self] in
                if session.inputs.isEmpty {
                    guard let device = Self.frontCamera(), let input = try? AVCaptureDeviceInput(device: device),
                          session.canAddInput(input) else { done(false); return }
                    session.beginConfiguration()
                    // Enough for a small preview, and lighter than the camera's full size.
                    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                    session.addInput(input)
                    session.commitConfiguration()
                }
                if !session.isRunning { session.startRunning() }
                done(session.isRunning)
            }
        }

        func stop() {
            queue.async { [self] in
                session.stopRunning()
                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                session.commitConfiguration()
                Log.app.debug("Camera check stopped: running \(self.session.isRunning, privacy: .public), inputs \(self.session.inputs.count, privacy: .public)")
            }
        }

        /// The Mac's own camera facing the user, else the one macOS prefers (Continuity Camera,
        /// an external one).
        private static func frontCamera() -> AVCaptureDevice? {
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.systemPreferredCamera
                ?? AVCaptureDevice.default(for: .video)
        }
    }
}

/// The live, mirrored picture; a drawn stand-in in previews.
struct CameraPreview: View {
    let mirror: CameraMirror

    var body: some View {
        ZStack {
            Color.white.opacity(0.04)
            if mirror.simulated {
                SimulatedCamera()
            } else {
                CameraLayerView(layer: mirror.layer)
            }
            switch mirror.status {
            case .starting:
                ProgressView().controlSize(.small).tint(Theme.textSecondary)
            case .noCamera:
                Label("No camera found", systemImage: "video.slash")
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
            case .off, .running:
                EmptyView()
            }
        }
    }
}

private struct CameraLayerView: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView { Host(preview: layer) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Host: NSView {
        private let preview: AVCaptureVideoPreviewLayer

        init(preview: AVCaptureVideoPreviewLayer) {
            self.preview = preview
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(preview)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }
    }
}

/// A person in front of a soft window light, drawn in code: no one's face in a screenshot.
private struct SimulatedCamera: View {
    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            ZStack {
                LinearGradient(colors: [Color(hex: 0x3B4250), Color(hex: 0x1D2129)], startPoint: .topTrailing, endPoint: .bottomLeading)
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xC9D6E8).opacity(0.22))
                    .frame(width: h * 0.55, height: h * 0.7)
                    .blur(radius: 6)
                    .offset(x: proxy.size.width * 0.3, y: -h * 0.12)
                Ellipse().fill(Color(hex: 0x6C7686))
                    .frame(width: h * 0.95, height: h * 0.62)
                    .offset(y: h * 0.47)
                Circle().fill(Color(hex: 0xA48C7C))
                    .frame(width: h * 0.42)
                    .offset(y: -h * 0.04)
            }
            .frame(width: proxy.size.width, height: h)
        }
    }
}
