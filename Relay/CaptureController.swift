import AppKit
import AVFoundation
import Combine
import CoreImage
import ScreenCaptureKit

@MainActor
final class CaptureController: NSObject, ObservableObject {
    @Published var phase: CapturePhase = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var sources: [CaptureSource] = []
    @Published var errorMessage: String?
    @Published var previewImage: NSImage?
    @Published var cameraReady = false
    @Published var microphoneMuted = false
    @Published var outputSize: CGSize = .zero
    let cameraSession = AVCaptureSession()
    var onRecordingFinished: ((URL) -> Void)?

    private lazy var pipeline = CapturePipeline(session: cameraSession)
    private var activeID: UUID?
    private var stream: SCStream?
    private var cameraPreparation: Task<Void, Error>?
    private var cameraGeneration = UUID()
    private var stoppingTask: Task<Void, Never>?
    private var currentMode: CaptureMode = .screenAndCamera

    override init() {
        super.init()
        // Construction never starts capture or prompts for camera/screen access.
        pipeline.onPreview = { [weak self] id, image, duration in
            Task { @MainActor in
                guard let self, self.activeID == id else { return }
                self.previewImage = image; self.elapsed = duration
            }
        }
        pipeline.onFailure = { [weak self] id, error in
            Task { @MainActor in
                guard let self, self.activeID == id, self.phase != .finishing else { return }
                self.errorMessage = error.localizedDescription
                await self.stop()
            }
        }
    }

    /// Call from the user's source-selection action, not application launch.
    func loadSources() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            sources = makeSources(content)
        } catch {
            errorMessage = "Allow Relay in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. \(error.localizedDescription)"
        }
    }

    func prepareCamera() async throws {
        if cameraReady && cameraSession.isRunning { return }
        if let cameraPreparation { return try await cameraPreparation.value }
        errorMessage = nil
        let generation = cameraGeneration
        let preparation = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            guard await Self.authorize(.video) else { throw RecordingFailure.message("Allow camera access in System Settings → Privacy & Security → Camera to enable your camera.") }
            try Task.checkCancellation()
            guard self.cameraGeneration == generation else { throw CancellationError() }
            try await self.pipeline.prepareCamera()
            guard !Task.isCancelled, self.cameraGeneration == generation else {
                await self.pipeline.stopCamera()
                throw CancellationError()
            }
            self.cameraReady = true
        }
        cameraPreparation = preparation
        do { try await preparation.value; cameraPreparation = nil }
        catch {
            cameraPreparation = nil; cameraReady = false
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            throw error
        }
    }

    func stopCameraPreview() async {
        if phase.isLive && currentMode.usesCamera { return }
        cameraGeneration = UUID()
        cameraPreparation?.cancel()
        cameraPreparation = nil
        await pipeline.stopCamera()
        cameraReady = false
    }

    func start(options: CaptureOptions) async {
        guard phase == .idle, stoppingTask == nil else { return }
        let id = UUID()
        activeID = id; currentMode = options.mode
        phase = .preparing; errorMessage = nil; elapsed = 0; previewImage = nil
        microphoneMuted = false
        do {
            if options.microphone {
                guard await Self.authorize(.audio) else { throw RecordingFailure.message("Allow microphone access in System Settings → Privacy & Security → Microphone, or turn the microphone off.") }
            }
            try ensureActive(id)
            if options.mode.usesCamera { try await prepareCamera() }
            else { await pipeline.stopCamera(); cameraReady = false }
            try ensureActive(id)
            if options.mode == .camera { try await pipeline.prepareMicrophone(enabled: options.microphone) }
            try ensureActive(id)

            var filter: SCContentFilter?
            var size: CGSize
            if options.mode.usesScreen {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try ensureActive(id)
                sources = makeSources(content)
                let selected: CaptureSource?
                if let sourceID = options.sourceID {
                    guard let existing = sources.first(where: { $0.id == sourceID }) else {
                        throw RecordingFailure.message("The selected window or display is no longer available. Choose another source.")
                    }
                    selected = existing
                } else { selected = sources.first { $0.kind == .display } }
                guard let selected else { throw RecordingFailure.message("No capture sources are available. Allow screen recording and choose a source.") }
                if let windowID = selected.windowID, let window = content.windows.first(where: { $0.windowID == windowID }) {
                    filter = SCContentFilter(desktopIndependentWindow: window)
                } else if let displayID = selected.displayID, let display = content.displays.first(where: { $0.displayID == displayID }) {
                    let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                    filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                } else { throw RecordingFailure.message("The selected window or display is no longer available. Choose another source.") }
                guard let filter else { throw RecordingFailure.message("The capture source could not be prepared.") }
                size = Self.pixelSize(filter)
            } else {
                size = try await pipeline.cameraSize()
            }
            // Even dimensions preserve every native pixel and only add at most
            // a one-pixel black edge for odd-sized windows required by codecs.
            size = CGSize(width: ceil(size.width / 2) * 2, height: ceil(size.height / 2) * 2)
            outputSize = size
            try ensureActive(id)
            try await pipeline.begin(id: id, options: options, size: size)
            try ensureActive(id)
            if let filter {
                let configuration = SCStreamConfiguration()
                configuration.width = Int(size.width); configuration.height = Int(size.height)
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                configuration.queueDepth = 5
                configuration.showsCursor = true
                configuration.captureResolution = .best
                configuration.scalesToFit = false
                configuration.preservesAspectRatio = true
                configuration.ignoreShadowsSingleWindow = true
                configuration.capturesAudio = options.systemAudio
                configuration.excludesCurrentProcessAudio = true
                configuration.captureMicrophone = options.microphone
                configuration.sampleRate = 48_000; configuration.channelCount = 2
                let newStream = SCStream(filter: filter, configuration: configuration, delegate: pipeline)
                try newStream.addStreamOutput(pipeline, type: .screen, sampleHandlerQueue: pipeline.queue)
                if options.systemAudio { try newStream.addStreamOutput(pipeline, type: .audio, sampleHandlerQueue: pipeline.queue) }
                if options.microphone { try newStream.addStreamOutput(pipeline, type: .microphone, sampleHandlerQueue: pipeline.queue) }
                stream = newStream
                await pipeline.attach(stream: newStream)
                try await newStream.startCapture()
                if activeID != id {
                    // A cancellation can finish before the asynchronous native
                    // start completes. Stop that late stream explicitly.
                    try? await newStream.stopCapture()
                    throw CancellationError()
                }
                try ensureActive(id)
            }
            await pipeline.startTimer(id: id)
            try ensureActive(id)
            phase = .recording
        } catch {
            guard activeID == id else { return }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            await stop()
        }
    }

    func pause() {
        guard phase == .recording else { return }
        phase = .paused
        pipeline.queue.async { [pipeline] in pipeline.pause() }
    }
    func resume() {
        guard phase == .paused else { return }
        phase = .recording
        pipeline.queue.async { [pipeline] in pipeline.resume() }
    }

    func stop() async {
        if let stoppingTask { await stoppingTask.value; return }
        guard let id = activeID else { return }
        let wasPreparing = phase == .preparing
        activeID = nil
        phase = .finishing
        let oldStream = stream; stream = nil
        cameraGeneration = UUID(); cameraPreparation?.cancel(); cameraPreparation = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let stopStream = Task { try? await oldStream?.stopCapture() }
            let result = await self.pipeline.finish(id: id)
            await self.pipeline.stopCamera()
            _ = await stopStream.value
            self.cameraReady = false
            if case .success(let url) = result { self.onRecordingFinished?(url) }
            else if case .failure(let error) = result, !wasPreparing, self.errorMessage == nil { self.errorMessage = error.localizedDescription }
        }
        stoppingTask = task
        await task.value
        stoppingTask = nil
        phase = .idle
    }

    func setMicrophoneMuted(_ muted: Bool) {
        microphoneMuted = muted
        pipeline.queue.async { [pipeline] in pipeline.microphoneMuted = muted }
    }

    func setCameraPosition(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        pipeline.queue.async { [pipeline] in pipeline.setCameraPosition(x: x, y: y) }
    }

    func shutdown() async { await stop(); await stopCameraPreview() }

    /// Full-resolution compositing/pause verification without screen or camera access.
    static func writeSyntheticSmoke(to url: URL) async throws -> URL {
        try await CapturePipeline.writeSyntheticSmoke(to: url)
    }

    private func ensureActive(_ id: UUID) throws { if activeID != id { throw CancellationError() } }
    private static func authorize(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
    private static func pixelSize(_ filter: SCContentFilter) -> CGSize {
        let scale = CGFloat(filter.pointPixelScale)
        return CGSize(width: ceil(filter.contentRect.width * scale), height: ceil(filter.contentRect.height * scale))
    }
    private func makeSources(_ content: SCShareableContent) -> [CaptureSource] {
        let displays = content.displays.enumerated().map { index, display -> CaptureSource in
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let size = Self.pixelSize(filter)
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?.localizedName ?? "Display \(index + 1)"
            return CaptureSource(id: "display-\(display.displayID)", title: name, kind: .display, displayID: display.displayID, windowID: nil, pixelWidth: Int(size.width), pixelHeight: Int(size.height))
        }
        let windows = content.windows.filter { window in
            window.isOnScreen && window.frame.width > 80 && window.frame.height > 60 && window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && !(window.title ?? "").isEmpty
        }.map { window -> CaptureSource in
            let size = Self.pixelSize(SCContentFilter(desktopIndependentWindow: window))
            return CaptureSource(id: "window-\(window.windowID)", title: "\(window.owningApplication?.applicationName ?? "App") — \(window.title ?? "Window")", kind: .window, displayID: nil, windowID: window.windowID, pixelWidth: Int(size.width), pixelHeight: Int(size.height))
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return displays + windows
    }
}

/// Screen, camera, composition, writer mutation, and timing share one queue.
private final class CapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "studio.relay.capture", qos: .userInitiated)
    let session: AVCaptureSession
    var onPreview: ((UUID, NSImage, TimeInterval) -> Void)?
    var onFailure: ((UUID, Error) -> Void)?
    var microphoneMuted = false
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var cameraDevice: AVCaptureDevice?
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var microphoneInput: AVCaptureDeviceInput?
    private var microphoneOutput: AVCaptureAudioDataOutput?
    private var latestCamera: CVPixelBuffer?
    private var latestScreen: CVPixelBuffer?
    private var currentStream: SCStream?
    private var id: UUID?
    private var options: CaptureOptions?
    private var writer: RecordingWriter?
    private var timer: DispatchSourceTimer?
    private var lastPreview = CMTime.zero
    private var startedAt = CMTime.zero
    private var lastCameraFrameTime = CMTime.invalid
    private var cameraGraceStart = CMTime.zero
    private var paused = false
    private var failureSent = false

    init(session: AVCaptureSession) { self.session = session; super.init() }

    func prepareCamera() async throws {
        try await perform {
            if self.session.isRunning { return }
            if self.cameraOutput == nil {
                guard let device = AVCaptureDevice.default(for: .video) else { throw RecordingFailure.message("No camera was found. Connect a camera and try again.") }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.queue)
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else { self.session.commitConfiguration(); throw RecordingFailure.message("The camera could not be configured.") }
                self.session.addInput(input); self.session.addOutput(output)
                self.session.commitConfiguration()
                let formats = device.formats.filter { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 && $0.minFrameRate <= 30 } }
                do {
                    if let largest = formats.max(by: { a, b in
                        let x = CMVideoFormatDescriptionGetDimensions(a.formatDescription), y = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                        return Int64(x.width) * Int64(x.height) < Int64(y.width) * Int64(y.height)
                    }) {
                        try device.lockForConfiguration()
                        device.activeFormat = largest
                        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                        device.unlockForConfiguration()
                    }
                } catch {
                    self.session.beginConfiguration()
                    self.session.removeOutput(output); self.session.removeInput(input)
                    self.session.commitConfiguration()
                    output.setSampleBufferDelegate(nil, queue: nil)
                    throw error
                }
                self.cameraDevice = device; self.cameraOutput = output
            }
            self.session.startRunning()
            guard self.session.isRunning else { throw RecordingFailure.message("The camera did not start. Check whether another app is using it.") }
        }
    }

    func stopCamera() async {
        await performIgnoringErrors {
            if self.session.isRunning { self.session.stopRunning() }
            self.removeMicrophone()
            self.latestCamera = nil
            self.lastCameraFrameTime = .invalid
        }
    }
    func cameraSize() async throws -> CGSize {
        try await perform {
            guard let device = self.cameraDevice else { throw RecordingFailure.message("Enable the camera before recording.") }
            let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            return CGSize(width: Int(size.width), height: Int(size.height))
        }
    }
    func prepareMicrophone(enabled: Bool) async throws {
        try await perform {
            self.removeMicrophone()
            guard enabled else { return }
            guard let device = AVCaptureDevice.default(for: .audio) else { throw RecordingFailure.message("No microphone was found.") }
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: self.queue)
            self.session.beginConfiguration()
            guard self.session.canAddInput(input), self.session.canAddOutput(output) else { self.session.commitConfiguration(); throw RecordingFailure.message("The microphone could not be configured.") }
            self.session.addInput(input); self.session.addOutput(output); self.session.commitConfiguration()
            self.microphoneInput = input; self.microphoneOutput = output
        }
    }
    func begin(id: UUID, options: CaptureOptions, size: CGSize) async throws {
        try await perform {
            self.id = id; self.options = options; self.latestScreen = nil; self.microphoneMuted = false; self.failureSent = false
            self.lastPreview = .zero; self.startedAt = Self.now()
            self.cameraGraceStart = self.startedAt; self.paused = false
            if options.mode != .camera { self.removeMicrophone() }
            self.writer = try RecordingWriter(url: options.outputURL, width: Int(size.width), height: Int(size.height), microphone: options.microphone, systemAudio: options.mode.usesScreen && options.systemAudio, context: self.context)
        }
    }
    func attach(stream: SCStream) async { await performIgnoringErrors { self.currentStream = stream } }
    func startTimer(id: UUID) async {
        await performIgnoringErrors {
            guard self.id == id else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(2))
            timer.setEventHandler { [weak owner = self] in owner?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    func pause() { paused = true; writer?.pause(at: Self.now()) }
    func resume() {
        paused = false
        cameraGraceStart = Self.now()
        writer?.resume(at: cameraGraceStart)
    }
    func setCameraPosition(x: Double, y: Double) { options?.cameraX = max(0, min(1, x)); options?.cameraY = max(0, min(1, y)); tick() }

    func finish(id: UUID) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.id == id else { continuation.resume(returning: .failure(CancellationError())); return }
                self.tick()
                self.timer?.setEventHandler {}; self.timer?.cancel(); self.timer = nil
                let writer = self.writer; self.writer = nil; self.id = nil; self.currentStream = nil
                if self.session.isRunning { self.session.stopRunning() }
                self.removeMicrophone()
                self.latestCamera = nil; self.latestScreen = nil; self.options = nil
                guard let writer else { continuation.resume(returning: .failure(CancellationError())); return }
                writer.finish(at: Self.now()) { continuation.resume(returning: $0) }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === currentStream, CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let status = attachments.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
            latestScreen = CMSampleBufferGetImageBuffer(sampleBuffer)
        case .audio, .microphone:
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let hostTime = stream.synchronizationClock.map { CMSyncConvertTime(timestamp, from: $0, to: CMClockGetHostTimeClock()) } ?? timestamp
            appendAudio(sampleBuffer, source: type == .audio ? .system : .microphone, hostTime: hostTime)
        @unknown default: break
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { if stream === self.currentStream { self.fail(error) } }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === cameraOutput {
            if let frame = CMSampleBufferGetImageBuffer(sampleBuffer) {
                latestCamera = frame; lastCameraFrameTime = Self.now()
            }
        }
        else if output === microphoneOutput {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let hostTime = session.synchronizationClock.map { CMSyncConvertTime(timestamp, from: $0, to: CMClockGetHostTimeClock()) } ?? timestamp
            appendAudio(sampleBuffer, source: .microphone, hostTime: hostTime)
        }
    }

    private func appendAudio(_ sample: CMSampleBuffer, source: RecordingWriter.AudioSource, hostTime: CMTime? = nil) {
        do { try writer?.appendAudio(sample, source: source, muted: microphoneMuted, at: hostTime) }
        catch { fail(error) }
    }
    private func tick() {
        guard let id, let options, let writer else { return }
        let now = Self.now()
        if options.mode.usesCamera && !paused {
            let reference = lastCameraFrameTime.isValid && lastCameraFrameTime > cameraGraceStart ? lastCameraFrameTime : cameraGraceStart
            if CMTimeSubtract(now, reference).seconds > 10 {
                fail(RecordingFailure.message("The camera stopped sending video. Relay is saving your recording. Check the camera connection before starting again."))
                return
            }
        }
        guard let source = options.mode.usesScreen ? latestScreen : latestCamera else {
            if !paused && CMTimeSubtract(now, max(startedAt, cameraGraceStart)).seconds > 10 { fail(RecordingFailure.message("The source did not deliver video. Check its permissions and select another source.")) }
            return
        }
        let size = writer.size
        let rect = CGRect(origin: .zero, size: size)
        var image = Self.fit(CIImage(cvPixelBuffer: source), in: rect)
        if options.mode == .camera { image = Self.mirrored(image, in: rect) }
        if options.mode == .screenAndCamera, let camera = latestCamera {
            image = Self.composite(screen: image, camera: CIImage(cvPixelBuffer: camera), size: size, x: options.cameraX, y: options.cameraY, fraction: options.cameraSize)
        }
        do { try writer.appendVideo(image, at: now) } catch { fail(error); return }
        if CMTimeSubtract(now, lastPreview).seconds >= 0.2 {
            lastPreview = now
            let factor = min(1, 720 / size.width)
            let preview = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            if let cgImage = context.createCGImage(preview, from: CGRect(x: 0, y: 0, width: size.width * factor, height: size.height * factor)) {
                onPreview?(id, NSImage(cgImage: cgImage, size: CGSize(width: size.width * factor, height: size.height * factor)), writer.duration)
            }
        }
    }

    static func composite(screen: CIImage, camera: CIImage, size: CGSize, x: Double, y: Double, fraction: Double) -> CIImage {
        let diameter = max(16, min(size.width * max(0.05, min(0.6, fraction)), size.height * 0.32))
        let radius = diameter / 2
        let margin = min(size.width, size.height) * 0.02
        let centerX = max(radius + margin, min(size.width - radius - margin, x * size.width))
        let centerY = max(radius + margin, min(size.height - radius - margin, (1 - y) * size.height))
        let target = CGRect(x: centerX - radius, y: centerY - radius, width: diameter, height: diameter)
        var normalized = camera.transformed(by: CGAffineTransform(translationX: -camera.extent.minX, y: -camera.extent.minY))
        let scale = max(diameter / normalized.extent.width, diameter / normalized.extent.height)
        normalized = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        normalized = normalized.transformed(by: CGAffineTransform(translationX: target.midX - normalized.extent.midX, y: target.midY - normalized.extent.midY))
        normalized = mirrored(normalized, in: target).cropped(to: target)
        let mask = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: centerX, y: centerY), "inputRadius0": max(0, radius - 0.8), "inputRadius1": radius, "inputColor0": CIColor.white, "inputColor1": CIColor.clear])!.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
        return normalized.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: screen, kCIInputMaskImageKey: mask]).cropped(to: CGRect(origin: .zero, size: size))
    }
    private static func fit(_ image: CIImage, in rect: CGRect) -> CIImage {
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(rect.width / image.extent.width, rect.height / image.extent.height)
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: (rect.width - scaled.extent.width) / 2, y: (rect.height - scaled.extent.height) / 2))
        return positioned.composited(over: CIImage(color: .black).cropped(to: rect))
    }
    private static func mirrored(_ image: CIImage, in rect: CGRect) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -rect.midX, y: 0)).transformed(by: CGAffineTransform(scaleX: -1, y: 1)).transformed(by: CGAffineTransform(translationX: rect.midX, y: 0))
    }
    private func fail(_ error: Error) {
        guard !failureSent, let id else { return }
        failureSent = true; onFailure?(id, error)
    }
    private func removeMicrophone() {
        guard microphoneInput != nil || microphoneOutput != nil else { return }
        session.beginConfiguration()
        if let microphoneInput { session.removeInput(microphoneInput) }
        if let microphoneOutput { session.removeOutput(microphoneOutput) }
        microphoneInput = nil; microphoneOutput = nil
        session.commitConfiguration()
    }
    private static func now() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
    static func writeSyntheticSmoke(to url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "studio.relay.compositor.smoke").async {
                do {
                    let size = CGSize(width: 3200, height: 1800)
                    let writer = try RecordingWriter(url: url, width: 3200, height: 1800, microphone: false, systemAudio: false)
                    let camera = CIImage(color: CIColor(red: 1, green: 0.2, blue: 0.15)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 480))
                        .composited(over: CIImage(color: CIColor(red: 1, green: 0.9, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)))
                    for frame in 0..<60 {
                        if frame == 30 {
                            writer.pause(at: CMTime(seconds: 101, preferredTimescale: 60_000))
                            writer.resume(at: CMTime(seconds: 103, preferredTimescale: 60_000))
                        }
                        let screen = CIImage(color: CIColor(red: 0.08, green: CGFloat(frame) / 120 + 0.15, blue: 0.65)).cropped(to: CGRect(origin: .zero, size: size))
                        let image = composite(screen: screen, camera: camera, size: size, x: frame < 30 ? 0.25 : 0.75, y: frame < 30 ? 0.75 : 0.25, fraction: 0.18)
                        let host = 100 + Double(frame) / 30 + (frame >= 30 ? 2 : 0)
                        try writer.appendVideo(image, at: CMTime(seconds: host, preferredTimescale: 60_000))
                        Thread.sleep(forTimeInterval: 0.012)
                    }
                    writer.finish(at: CMTime(seconds: 104, preferredTimescale: 60_000)) { continuation.resume(with: $0) }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func perform<T>(_ action: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async { do { continuation.resume(returning: try action()) } catch { continuation.resume(throwing: error) } } }
    }
    private func performIgnoringErrors(_ action: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in queue.async { action(); continuation.resume() } }
    }
}
