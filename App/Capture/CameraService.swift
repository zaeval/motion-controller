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
    /// Mean luma of the frame, 0–1. Called on the capture queue with every frame.
    var onLight: (@Sendable (Double, TimeInterval) -> Void)?

    let session = AVCaptureSession()
    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Camera")
    private static let frameRate: Double = 30
    /// `MC_CAMERA_MAX_WIDTH`: the widest format to pick, for measuring what resolution costs Vision. 1280 by default.
    private static let maxWidth = ProcessInfo.processInfo.environment["MC_CAMERA_MAX_WIDTH"].flatMap { Int32($0) } ?? 1280
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "MotionController.camera", qos: .userInteractive)
    private var input: AVCaptureDeviceInput?
    /// Read and written only on `queue`.
    private var loggedFrameSize = false
    private var lastLightLog = -TimeInterval.infinity
    /// Frames logged since the session started, so the camera's exposure warm-up is visible on every launch.
    private var lightLogs = 0

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
    ///
    /// 1920×1080 at 30 fps does exist on this camera and was tried (2026-09-14), to put more pixels on a small hand:
    /// Vision went from 20 ms a frame to 79 ms, which is 14 fps. Resolution is not the way to find a small hand.
    private func selectFastFormat(for device: AVCaptureDevice) {
        let frameRate = Self.frameRate
        let candidates = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width > size.height && size.width >= 320 && size.width <= Self.maxWidth
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
        lightLogs = 0
        Self.logger.notice("Camera format \(size.width)x\(size.height) at \(Int(frameRate)) fps")
    }
}

extension CameraService {
    /// Mean luma of the frame, 0–1, from the Y plane of the 420 buffer the session is configured for. Every eighth
    /// pixel of every eighth row is enough — this runs on the capture queue at 30 fps — and returns nil for a
    /// buffer that isn't planar, so a format change can't report a black room.
    static func meanLuma(of buffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPlaneCount(buffer) > 0,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0, stride >= width else { return nil }
        let step = 8
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var counted = 0
        for y in Swift.stride(from: 0, to: height, by: step) {
            let row = pixels + y * stride
            for x in Swift.stride(from: 0, to: width, by: step) {
                total += Int(row[x])
                counted += 1
            }
        }
        guard counted > 0 else { return nil }
        // The session asks for full-range 420, so luma uses the whole 0–255.
        return Double(total) / Double(counted) / 255
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !loggedFrameSize {
            loggedFrameSize = true
            Self.logger.notice("Camera frames \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if let luma = Self.meanLuma(of: pixelBuffer) {
            if time - lastLightLog >= 5 || lightLogs < 8 {
                lastLightLog = time
                lightLogs += 1
                Self.logger.notice("Light luma \(luma, format: .fixed(precision: 3), privacy: .public)")
            }
            onLight?(luma, time)
        }
        onFrame?(pixelBuffer, time)
    }
}
