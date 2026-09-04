import AVFoundation

/// Camera position for video capture.
public enum CameraPosition: Sendable {
    /// Front-facing camera, when available.
    case front
    /// Rear-facing camera, when available.
    case back

    var position: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }
}

/// Video capture orientation.
public enum VideoOrientation: Sendable {
    /// Portrait orientation with the device upright.
    case portrait
    /// Portrait orientation with the device upside down.
    case portraitUpsideDown
    /// Landscape with the device rotated to the right.
    case landscapeRight
    /// Landscape with the device rotated to the left.
    case landscapeLeft

    var avOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeRight: return .landscapeRight
        case .landscapeLeft: return .landscapeLeft
        }
    }

    var isLandscape: Bool {
        self == .landscapeRight || self == .landscapeLeft
    }
}

/// Camera device selection and preferred capture settings.
public struct Camera: Sendable {
    /// Which camera to use.
    public let position: CameraPosition
    /// Device types to try, in order; the first one available at `position` (and able to
    /// honour ``maxFrameRate`` when set) is used. Virtual devices such as
    /// `.builtInTripleCamera` are valid here and switch their constituent cameras across
    /// `videoZoomFactor` without any input change.
    public let deviceTypes: [AVCaptureDevice.DeviceType]
    /// Preferred coded frame width in pixels.
    public let width: Int32
    /// Preferred coded frame height in pixels.
    public let height: Int32
    /// Preferred orientation for captured frames.
    public let orientation: VideoOrientation
    /// When set, capture selects a format with exactly `width` × `height` whose frame-rate
    /// range contains this value, gives the session's preset up to that format, and fixes the
    /// frame duration. When nil, the session preset nearest the dimensions decides the format
    /// and the device decides the rate, as before.
    public let maxFrameRate: Double?

    /// Creates a camera configuration for ``CameraCapture``.
    public init(
        position: CameraPosition = .back,
        deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera],
        width: Int32 = 720,
        height: Int32 = 1280,
        orientation: VideoOrientation = .portrait,
        maxFrameRate: Double? = nil
    ) {
        self.position = position
        self.deviceTypes = deviceTypes.isEmpty ? [.builtInWideAngleCamera] : deviceTypes
        self.width = width
        self.height = height
        self.orientation = orientation
        self.maxFrameRate = maxFrameRate
    }
}

/// A capture format described without AVFoundation, so the selection rule is testable.
public struct CameraFormatCandidate: Equatable, Sendable {
    public let width: Int32
    public let height: Int32
    public let minFrameRate: Double
    public let maxFrameRate: Double

    public init(width: Int32, height: Int32, minFrameRate: Double, maxFrameRate: Double) {
        self.width = width
        self.height = height
        self.minFrameRate = minFrameRate
        self.maxFrameRate = maxFrameRate
    }
}

/// Exact dimensions are a constraint, not a preference: the encoder is configured for the
/// same width and height as capture, and a nearby format would silently mismatch it. Among
/// exact matches whose range contains the rate, the lowest ceiling is chosen so selection is
/// stable across camera models and never picks a high-speed format by accident.
public enum CameraFormatSelection {
    public static func index(
        of candidates: [CameraFormatCandidate],
        width: Int32,
        height: Int32,
        frameRate: Double
    ) -> Int? {
        guard frameRate.isFinite, frameRate > 0 else { return nil }
        return candidates.indices
            .filter { index in
                let candidate = candidates[index]
                return candidate.width == width
                    && candidate.height == height
                    && candidate.minFrameRate <= frameRate
                    && frameRate <= candidate.maxFrameRate
            }
            .min { candidates[$0].maxFrameRate < candidates[$1].maxFrameRate }
    }

    /// An exact rational, never seconds-and-truncate: 1/30 rounded through nanoseconds gives
    /// 30.0000003 fps and AVFoundation rejects it for exceeding a 30 fps range.
    public static func frameDuration(for frameRate: Double) -> CMTime {
        CMTime(value: 1000, timescale: CMTimeScale((frameRate * 1000).rounded()))
    }
}

/// Built-in camera capture source for publishing video.
///
/// `CameraCapture` owns an `AVCaptureSession` and forwards frames into a publisher track.
/// You can also reuse its ``captureSession`` for a local preview UI. Your app must include
/// `NSCameraUsageDescription` and should call ``start()`` before expecting frames to reach
/// a publisher.
public final class CameraCapture: NSObject, FrameSource, @unchecked Sendable {
    /// The underlying capture session, exposed for preview UI or advanced camera setup.
    public let captureSession = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.swmansion.MoQKit.CameraCapture")
    /// Advanced frame callback used by ``Publisher``.
    public var onFrame: (@Sendable (CMSampleBuffer) -> Bool)?

    /// The currently configured camera settings.
    public private(set) var camera: Camera
    /// The device currently feeding the session, for zoom, focus and exposure control.
    public var captureDevice: AVCaptureDevice? { currentInput?.device }
    private var currentInput: AVCaptureDeviceInput?
    private var currentOutput: AVCaptureVideoDataOutput?
    private var isConfigured = false
    private var isRunning = false

    /// Creates a camera capture source with the requested device and format preferences.
    public init(camera: Camera = Camera()) {
        self.camera = camera
        super.init()
    }

    /// Starts the capture session.
    ///
    /// The session is configured on an internal queue. After this succeeds, frames begin
    /// arriving through ``FrameSource/onFrame`` when a publisher track is attached.
    public func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    if !isConfigured {
                        try configureSession()
                    }

                    if !isRunning {
                        captureSession.startRunning()
                        isRunning = true
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops camera capture and detaches any active frame consumer.
    public func stop() {
        onFrame = nil
        queue.async { [self] in
            if isRunning {
                captureSession.stopRunning()
                isRunning = false
            }
        }
    }

    /// Switches to a different camera device or capture configuration while running.
    ///
    /// Use this for front/back camera changes, a different device type, or resolution,
    /// orientation and frame-rate updates without recreating the capture source. The input,
    /// preset, format, frame duration and orientation change as one transaction; if the new
    /// device cannot be added the previous input is restored and the error thrown.
    public func `switch`(to newCamera: Camera) throws {
        try queue.sync {
            guard isConfigured else {
                camera = newCamera
                return
            }

            guard let oldInput = currentInput else {
                throw SessionError.invalidConfiguration("No current camera input")
            }
            let device = try resolveDevice(for: newCamera)
            let newInput = try AVCaptureDeviceInput(device: device)

            captureSession.beginConfiguration()
            captureSession.removeInput(oldInput)
            guard captureSession.canAddInput(newInput) else {
                if captureSession.canAddInput(oldInput) {
                    captureSession.addInput(oldInput)
                }
                captureSession.commitConfiguration()
                throw SessionError.invalidConfiguration("Cannot add new camera input")
            }
            captureSession.addInput(newInput)
            do {
                try applyPreset(for: newCamera, to: device)
            } catch {
                captureSession.removeInput(newInput)
                if captureSession.canAddInput(oldInput) {
                    captureSession.addInput(oldInput)
                }
                captureSession.commitConfiguration()
                throw error
            }
            currentInput = newInput
            camera = newCamera
            if let connection = currentOutput?.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = newCamera.orientation.avOrientation
            }
            captureSession.commitConfiguration()
        }
    }

    private func configureSession() throws {
        captureSession.beginConfiguration()
        do {
            let device = try resolveDevice(for: camera)
            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                throw SessionError.invalidConfiguration("Cannot add camera input")
            }
            captureSession.addInput(input)
            currentInput = input
            try applyPreset(for: camera, to: device)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)

            guard captureSession.canAddOutput(output) else {
                throw SessionError.invalidConfiguration("Cannot add video output")
            }
            captureSession.addOutput(output)
            currentOutput = output

            if let connection = output.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = camera.orientation.avOrientation
            }

            captureSession.commitConfiguration()
            isConfigured = true
        } catch {
            captureSession.commitConfiguration()
            resetSession()
            throw error
        }
    }

    /// The first requested device type present at the position that can also honour the
    /// requested frame rate, so a virtual camera without a matching format falls through to
    /// the next type rather than failing the whole start.
    private func resolveDevice(for camera: Camera) throws -> AVCaptureDevice {
        var rejected: [String] = []
        for deviceType in camera.deviceTypes {
            guard let device = AVCaptureDevice.default(
                deviceType, for: .video, position: camera.position.position
            ) else {
                rejected.append("\(deviceType.rawValue): absent")
                continue
            }
            if let maxFrameRate = camera.maxFrameRate,
               Self.format(for: camera, at: maxFrameRate, on: device) == nil {
                rejected.append(
                    "\(deviceType.rawValue): no \(camera.width)x\(camera.height) format at \(maxFrameRate) fps"
                )
                continue
            }
            return device
        }
        throw SessionError.invalidConfiguration(
            "No camera available for position \(camera.position.position): "
                + rejected.joined(separator: "; ")
        )
    }

    /// Either the nearest session preset (no frame rate requested) or an exact format with a
    /// fixed frame duration under `.inputPriority`. Runs inside the session transaction.
    private func applyPreset(for camera: Camera, to device: AVCaptureDevice) throws {
        guard let maxFrameRate = camera.maxFrameRate else {
            let preset = sessionPreset(for: camera.width, height: camera.height)
            if captureSession.canSetSessionPreset(preset) {
                captureSession.sessionPreset = preset
            }
            return
        }
        guard let format = Self.format(for: camera, at: maxFrameRate, on: device) else {
            throw SessionError.invalidConfiguration(
                "No \(camera.width)x\(camera.height) format supports \(maxFrameRate) fps on \(device.localizedName)"
            )
        }
        guard captureSession.canSetSessionPreset(.inputPriority) else {
            throw SessionError.invalidConfiguration("The session cannot yield its preset to a device format")
        }
        captureSession.sessionPreset = .inputPriority
        let duration = CameraFormatSelection.frameDuration(for: maxFrameRate)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private static func format(
        for camera: Camera,
        at frameRate: Double,
        on device: AVCaptureDevice
    ) -> AVCaptureDevice.Format? {
        let formats = device.formats
        let candidates = formats.map { format -> CameraFormatCandidate in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            // A maximum alone cannot show a high-speed range whose minimum is above the
            // target, so only ranges containing the target describe the candidate.
            let containing = format.videoSupportedFrameRateRanges.filter {
                $0.minFrameRate <= frameRate && frameRate <= $0.maxFrameRate
            }
            return CameraFormatCandidate(
                width: dimensions.width,
                height: dimensions.height,
                minFrameRate: containing.map(\.minFrameRate).min() ?? .infinity,
                maxFrameRate: containing.map(\.maxFrameRate).max() ?? -.infinity
            )
        }
        return CameraFormatSelection.index(
            of: candidates, width: camera.width, height: camera.height, frameRate: frameRate
        ).map { formats[$0] }
    }

    private func resetSession() {
        guard currentInput != nil || currentOutput != nil else { return }

        if isRunning {
            captureSession.stopRunning()
            isRunning = false
        }

        captureSession.beginConfiguration()
        if let output = currentOutput {
            output.setSampleBufferDelegate(nil, queue: nil)
            captureSession.removeOutput(output)
        }
        if let input = currentInput {
            captureSession.removeInput(input)
        }
        captureSession.commitConfiguration()
        currentInput = nil
        currentOutput = nil
        isConfigured = false
    }

    private func sessionPreset(for width: Int32, height: Int32) -> AVCaptureSession.Preset {
        let pixels = Int(width) * Int(height)
        if pixels <= 640 * 480 { return .vga640x480 }
        if pixels <= 1280 * 720 { return .hd1280x720 }
        if pixels <= 1920 * 1080 { return .hd1920x1080 }
        return .hd4K3840x2160
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// AVFoundation delegate callback used internally to forward captured frames.
    ///
    /// Apps normally do not call this directly.
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let onFrame, !onFrame(sampleBuffer) {
            self.onFrame = nil
        }
    }
}
