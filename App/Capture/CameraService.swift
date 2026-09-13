import AVFoundation
import CoreMedia
import os

/// Owns the capture session and hands every frame to `onFrame` on its own serial queue.
final class CameraService: NSObject, @unchecked Sendable {
    struct Device: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
    }

    /// Called on the capture queue with the un-mirrored frame and its presentation time in seconds.
    var onFrame: (@Sendable (CVPixelBuffer, TimeInterval) -> Void)?

    let session = AVCaptureSession()
    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Camera")
    private static let frameRate: Double = 30
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "MotionController.camera", qos: .userInteractive)
    private var input: AVCaptureDeviceInput?
    /// Read and written only on `queue`.
    private var loggedFrameSize = false

    static func availableDevices() -> [Device] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// Starts (or switches to) `deviceID`; nil picks the built-in camera so Continuity Camera never grabs it by default.
    func start(deviceID: String?) {
        queue.async {
            let attached = self.configure(deviceID: deviceID)
            if !self.session.isRunning {
                self.session.startRunning()
            }
            // Only after starting: starting applies the session preset, which put the built-in camera back at 1920×1080.
            if let attached {
                self.selectFastFormat(for: attached)
            }
        }
    }

    func stop() {
        queue.async {
            self.session.stopRunning()
        }
    }

    /// Caps the frame rate, e.g. 10 fps while no hand is in view.
    func setMaximumFrameRate(_ fps: Double) {
        queue.async {
            guard let device = self.input?.device,
                  device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }),
                  (try? device.lockForConfiguration()) != nil
            else { return }
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.unlockForConfiguration()
        }
    }

    /// Returns the device when it was newly attached, so its format can be chosen once the session is committed.
    private func configure(deviceID: String?) -> AVCaptureDevice? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, input?.device.uniqueID != device.uniqueID else { return nil }

        if let input {
            session.removeInput(input)
            self.input = nil
        }
        guard let newInput = try? AVCaptureDeviceInput(device: device), session.canAddInput(newInput) else { return nil }
        session.addInput(newInput)
        input = newInput
        loggedFrameSize = false

        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
        }
        // Vision must see the raw image, otherwise chirality and palm/back signs silently flip.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        return device
    }

    /// Taps last a frame or two and motion blur drops the hand mid-gesture, so frame rate matters more than
    /// resolution: the widest 16:9 format no bigger than 1280×720 that runs at 30 fps, pinned at 30 fps so low light
    /// can't slow it. The session preset alone left the built-in camera at 1920×1080 and about 20 fps, and a format
    /// set before the session started came out at 1920×1080 anyway, so the output is told the size as well.
    private func selectFastFormat(for device: AVCaptureDevice) {
        let frameRate = Self.frameRate
        let candidates = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width > size.height && size.width >= 640 && size.width <= 1280
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= frameRate && frameRate <= $0.maxFrameRate }
        }
        func rank(_ format: AVCaptureDevice.Format) -> (Int, Int32) {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let widescreen = abs(Double(size.width) / Double(size.height) - 16.0 / 9.0) < 0.01
            return (widescreen ? 1 : 0, size.width)
        }
        guard let best = candidates.max(by: { rank($0) < rank($1) }) else {
            Self.logger.notice("No 30 fps format at or under 1280 wide; keeping \(device.activeFormat.description, privacy: .public)")
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            Self.logger.error("Camera format not set: \(error.localizedDescription, privacy: .public)")
            return
        }
        let size = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
        loggedFrameSize = false
        Self.logger.notice("Camera format \(size.width)x\(size.height) at \(Int(frameRate)) fps")
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !loggedFrameSize {
            loggedFrameSize = true
            Self.logger.notice("Camera frames \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }
}
