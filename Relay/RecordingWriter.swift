import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

enum RecordingFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// All methods except the asynchronous completion run on the capture queue.
/// Audio is converted into one stereo PCM timeline before AAC encoding, so
/// ordinary players hear both microphone and system audio without track selection.
final class RecordingWriter {
    enum AudioSource: Hashable { case microphone, system }
    let url: URL
    let size: CGSize
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context: CIContext
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    private let audioSources: Int
    private var origin: CMTime?
    private var pauseStart: CMTime?
    private var pauseOffset = CMTime.zero
    private var lastVideo = CMTime.invalid
    private var audioBlocks: [Int: [Float]] = [:]
    private var converters: [AudioSource: AVAudioConverter] = [:]
    private var nextAudioFrame = 0
    private var finishing = false
    private var frameCount = 0
    private var videoStalled = false
    private(set) var duration: TimeInterval = 0
    private let blockFrames = 1024

    init(url: URL, width: Int, height: Int, microphone: Bool, systemAudio: Bool, context: CIContext = CIContext()) throws {
        guard width > 0, height > 0 else { throw RecordingFailure.message("The capture source did not provide a usable resolution.") }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingFailure.message("A file already exists at the recording destination. Choose a new recording name.")
        }
        self.url = url
        self.size = CGSize(width: width, height: height)
        self.context = context
        self.audioSources = (microphone ? 1 : 0) + (systemAudio ? 1 : 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        let compression: [String: Any] = [AVVideoAverageBitRateKey: max(6_000_000, width * height * 4), AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 60]
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression]
        if !writer.canApply(outputSettings: settings, forMediaType: .video) { settings[AVVideoCodecKey] = AVVideoCodecType.h264 }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw RecordingFailure.message("This Mac cannot encode the source at \(width) × \(height). Select a smaller source window.")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        guard writer.canAdd(video) else { throw RecordingFailure.message("The video encoder could not be prepared.") }
        writer.add(video)
        if audioSources > 0 {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingFailure.message("The audio encoder could not be prepared.") }
            writer.add(input)
            audio = input
        } else { audio = nil }
        guard writer.startWriting() else { throw writer.error ?? RecordingFailure.message("The recording file could not be opened.") }
        writer.startSession(atSourceTime: .zero)
    }

    func pause(at hostTime: CMTime) {
        if pauseStart == nil && !finishing {
            if let time = mapped(hostTime) { duration = max(duration, time.seconds) }
            pauseStart = hostTime
        }
    }
    func resume(at hostTime: CMTime) {
        if let start = pauseStart {
            if origin != nil { pauseOffset = CMTimeAdd(pauseOffset, CMTimeSubtract(hostTime, start)) }
            pauseStart = nil
        }
    }

    private func mapped(_ hostTime: CMTime) -> CMTime? {
        guard let origin, pauseStart == nil, !finishing else { return nil }
        let time = CMTimeSubtract(CMTimeSubtract(hostTime, origin), pauseOffset)
        return time.isNumeric && time >= .zero ? time : nil
    }

    func appendVideo(_ image: CIImage, at hostTime: CMTime) throws {
        guard !finishing, !videoStalled, pauseStart == nil else { return }
        if origin == nil { origin = hostTime }
        guard let time = mapped(hostTime), !lastVideo.isValid || time > lastVideo else { return }
        try checkStatus()
        duration = max(duration, time.seconds)
        guard video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            let lastSuccess = lastVideo.isValid ? lastVideo.seconds : 0
            if time.seconds - lastSuccess > 10 {
                videoStalled = true
                duration = max(1.0 / 30, lastSuccess + 1.0 / 30)
                throw RecordingFailure.message("The video encoder could not keep up. Relay is saving the frames it recorded; try a smaller capture window for your next take.")
            }
            return
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return }
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        guard adaptor.append(output, withPresentationTime: time) else { throw writer.error ?? RecordingFailure.message("The video encoder stopped accepting frames.") }
        lastVideo = time
        frameCount += 1
        try flushAudio(through: max(0, Int((time.seconds - 0.18) * 48_000)))
    }

    func appendAudio(_ sample: CMSampleBuffer, source: AudioSource, muted: Bool, at hostTime: CMTime? = nil) throws {
        guard audio != nil, let time = mapped(hostTime ?? CMSampleBufferGetPresentationTimeStamp(sample)),
              let description = CMSampleBufferGetFormatDescription(sample) else { return }
        guard time.seconds <= duration + 2 else {
            throw RecordingFailure.message("An audio device delivered an unexpected timestamp. Relay is stopping safely; reconnect the device and try again.")
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        input.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr else { return }
        if converters[source]?.inputFormat != inputFormat {
            converters[source] = AVAudioConverter(from: inputFormat, to: audioFormat)
            converters[source]?.primeMethod = .none
        }
        guard let converter = converters[source] else { return }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * 48_000 / inputFormat.sampleRate)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return input
        }
        guard status != .error, conversionError == nil, let channels = converted.floatChannelData else { return }
        let offset = max(0, Int((time.seconds * 48_000).rounded()))
        // Three seconds of stereo Float PCM is about 1.2 MB. This limit is
        // independent of capture length and also rejects sparse far-future data.
        let maximumQueuedFrames = 3 * 48_000
        guard offset + Int(converted.frameLength) <= nextAudioFrame + maximumQueuedFrames else {
            throw RecordingFailure.message("Audio encoding stopped keeping up. Relay is saving the video it recorded; try again with fewer audio sources.")
        }
        let gain: Float = source == .microphone && muted ? 0 : audioSources > 1 ? 0.7 : 1
        for frame in 0..<Int(converted.frameLength) {
            let index = offset + frame
            if index < nextAudioFrame { continue }
            let key = index / blockFrames
            if audioBlocks[key] == nil { audioBlocks[key] = [Float](repeating: 0, count: blockFrames * 2) }
            let local = (index % blockFrames) * 2
            audioBlocks[key]![local] += channels[0][frame] * gain
            audioBlocks[key]![local + 1] += channels[1][frame] * gain
        }
        try checkStatus()
    }

    private func flushAudio(through endFrame: Int, final: Bool = false) throws {
        guard let audio else { return }
        while nextAudioFrame < endFrame && audio.isReadyForMoreMediaData {
            let count = min(blockFrames, endFrame - nextAudioFrame)
            if !final && count < blockFrames { break }
            let key = nextAudioFrame / blockFrames
            var samples = audioBlocks.removeValue(forKey: key) ?? [Float](repeating: 0, count: blockFrames * 2)
            samples = Array(samples.prefix(count * 2)).map { max(-1, min(1, $0)) }
            let sample = try Self.pcmSample(samples, startFrame: nextAudioFrame)
            guard audio.append(sample) else { throw writer.error ?? RecordingFailure.message("The audio encoder stopped accepting samples.") }
            nextAudioFrame += count
        }
    }

    private static func pcmSample(_ samples: [Float], startFrame: Int) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw RecordingFailure.message("Audio buffering failed.") }
        status = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard status == noErr, CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw RecordingFailure.message("Audio format preparation failed.") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: Int64(startFrame), timescale: 48_000), decodeTimeStamp: .invalid)
        var sampleSize = 8
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: samples.count / 2, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &output) == noErr, let output else { throw RecordingFailure.message("Audio sample preparation failed.") }
        return output
    }

    private func checkStatus() throws {
        if writer.status == .failed || writer.status == .cancelled { throw writer.error ?? RecordingFailure.message("The recording encoder stopped unexpectedly.") }
    }

    func finish(at hostTime: CMTime, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !finishing else { return }
        if !videoStalled, let time = mapped(hostTime) { duration = max(duration, time.seconds) }
        finishing = true
        guard frameCount > 0 else {
            writer.cancelWriting()
            completion(.failure(RecordingFailure.message("No video frames arrived. Check the selected source and try again.")))
            return
        }
        // Wait briefly for encoder backpressure without blocking the capture queue.
        let finishQueue = DispatchQueue(label: "studio.relay.writer.finish")
        finishQueue.async { [self] in
            do {
                let deadline = Date().addingTimeInterval(8)
                let endFrame = max(nextAudioFrame, Int(ceil(duration * 48_000)))
                while audio != nil && nextAudioFrame < endFrame && Date() < deadline {
                    try flushAudio(through: endFrame, final: true)
                    if nextAudioFrame < endFrame { Thread.sleep(forTimeInterval: 0.005) }
                }
                if audio != nil && nextAudioFrame < endFrame { throw RecordingFailure.message("The audio encoder could not finish. The partial recording remains on disk.") }
                writer.endSession(atSourceTime: CMTime(seconds: max(duration, 1.0 / 30), preferredTimescale: 60_000))
                video.markAsFinished(); audio?.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed { completion(.success(url)) }
                    else { completion(.failure(writer.error ?? RecordingFailure.message("The recording could not be finalized. Its partial file remains on disk."))) }
                }
            } catch { writer.cancelWriting(); completion(.failure(error)) }
        }
    }

    func cancel() { finishing = true; writer.cancelWriting() }

    /// Device-free verification seam. Root can call this from a small command-line harness.
    static func writeSyntheticSmoke(to url: URL, width: Int = 3200, height: Int = 1800) async throws -> URL {
        let queue = DispatchQueue(label: "studio.relay.writer.smoke")
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let recorder = try RecordingWriter(url: url, width: width, height: height, microphone: false, systemAudio: false)
                    for frame in 0..<30 {
                        let image = CIImage(color: CIColor(red: CGFloat(frame) / 30, green: 0.3, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
                        try recorder.appendVideo(image, at: CMTime(value: Int64(frame), timescale: 30))
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    recorder.finish(at: CMTime(value: 30, timescale: 30)) { continuation.resume(with: $0) }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
