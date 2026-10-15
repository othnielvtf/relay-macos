import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

enum QAError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { return message }; return "QA failure" }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw QAError.failed(message) }
}

func timestamp(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 60_000_000)
}

/// Independent, permission-free PCM source: a continuous tone, interleaved Float32.
func toneSample(time: Double, phaseTime: Double, frequency: Double, rate: Double,
                channels: Int, frames: Int) throws -> CMSampleBuffer {
    var values = [Float](repeating: 0, count: channels * frames)
    for frame in 0..<frames {
        let value = Float(0.2 * sin(2 * .pi * frequency * (phaseTime + Double(frame) / rate)))
        for channel in 0..<channels { values[frame * channels + channel] = value }
    }
    let byteCount = values.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
        let block else { throw QAError.failed("Could not create synthetic PCM block") }
    let copyStatus = values.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                     offsetIntoDestination: 0, dataLength: byteCount)
    }
    try require(copyStatus == noErr, "Could not fill synthetic PCM block")
    let bytesPerFrame = UInt32(channels * MemoryLayout<Float>.size)
    var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
        throw QAError.failed("Could not create synthetic PCM format")
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                   presentationTimeStamp: timestamp(time), decodeTimeStamp: .invalid)
    var sampleSize = Int(bytesPerFrame)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
        sampleBufferOut: &sample) == noErr, let sample else {
        throw QAError.failed("Could not create synthetic PCM sample")
    }
    return sample
}

func finish(_ writer: RecordingWriter, at time: Double) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
        writer.finish(at: timestamp(time)) { continuation.resume(with: $0) }
    }
}

func recordMixed(to url: URL) async throws -> URL {
    let writer = try RecordingWriter(url: url, width: 320, height: 180,
                                     microphone: true, systemAudio: true)
    let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.7))
        .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
    try writer.appendVideo(image, at: timestamp(10))
    for step in 0..<400 {
        let wall = Double(step) / 100
        if step == 100 { writer.pause(at: timestamp(11)) }
        if step == 200 { writer.resume(at: timestamp(12)) }
        let active = wall < 1 ? wall : wall - 1
        if step % 3 == 0 { try writer.appendVideo(image, at: timestamp(10 + wall)) }
        let mic = try toneSample(time: 1000 + wall, phaseTime: wall, frequency: 440,
                                 rate: 44_100, channels: 1, frames: 441)
        let system = try toneSample(time: 10 + wall, phaseTime: wall, frequency: 880,
                                    rate: 48_000, channels: 2, frames: 480)
        // Deliberately use a different mic sample clock, then supply its host time.
        try writer.appendAudio(mic, source: .microphone,
                               muted: active >= 1.4 && active < 1.9,
                               at: timestamp(10 + wall))
        try writer.appendAudio(system, source: .system, muted: false)
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    return try await finish(writer, at: 14)
}

func recordPreOriginPause(to url: URL) async throws -> URL {
    let writer = try RecordingWriter(url: url, width: 160, height: 90,
                                     microphone: false, systemAudio: false)
    writer.pause(at: timestamp(10)); writer.resume(at: timestamp(12))
    let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
    for frame in 0..<30 {
        try writer.appendVideo(image, at: timestamp(12 + Double(frame) / 30))
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    return try await finish(writer, at: 13)
}

func recordClockAheadFailure(to url: URL) async throws -> (URL, String) {
    let writer = try RecordingWriter(url: url, width: 160, height: 90,
                                     microphone: true, systemAudio: false)
    let image = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
    try writer.appendVideo(image, at: timestamp(10))
    for step in 0..<100 {
        let time = Double(step) / 100
        if step % 3 == 0 { try writer.appendVideo(image, at: timestamp(10 + time)) }
        let sample = try toneSample(time: 10 + time, phaseTime: time, frequency: 440,
                                    rate: 48_000, channels: 1, frames: 480)
        try writer.appendAudio(sample, source: .microphone, muted: false)
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    let future = try toneSample(time: 200, phaseTime: 0, frequency: 440,
                                rate: 48_000, channels: 1, frames: 480)
    var rejection: String?
    do { try writer.appendAudio(future, source: .microphone, muted: false, at: timestamp(200)) }
    catch { rejection = error.localizedDescription }
    try require(rejection?.contains("unexpected timestamp") == true,
                "Expected friendly clock-ahead rejection; got \(String(describing: rejection))")
    return (try await finish(writer, at: 11), rejection!)
}

func decodeAudio(_ asset: AVAsset) async throws -> [Float] {
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    try require(tracks.count == 1, "Expected one mixed audio track, got \(tracks.count)")
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
    ])
    reader.add(output)
    try require(reader.startReading(), "Audio reader failed: \(String(describing: reader.error))")
    var mono: [Float] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        let count = CMBlockBufferGetDataLength(block)
        var data = [Float](repeating: 0, count: count / MemoryLayout<Float>.size)
        let status = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
        }
        try require(status == noErr, "Decoded PCM copy failed")
        let firstFrame = Int((sample.presentationTimeStamp.seconds * 48_000).rounded())
        let frames = data.count / 2
        if mono.count < firstFrame + frames {
            mono.append(contentsOf: repeatElement(Float.zero, count: firstFrame + frames - mono.count))
        }
        for frame in 0..<frames where firstFrame + frame >= 0 {
            mono[firstFrame + frame] = (data[frame * 2] + data[frame * 2 + 1]) / 2
        }
    }
    try require(reader.status == .completed, "Audio decoding failed: \(String(describing: reader.error))")
    return mono
}

func amplitude(_ values: [Float], frequency: Double, start: Double, end: Double) -> Double {
    let low = max(0, Int(start * 48_000)), high = min(values.count, Int(end * 48_000))
    guard high > low else { return 0 }
    var sine = 0.0, cosine = 0.0
    for index in low..<high {
        let phase = 2 * .pi * frequency * Double(index) / 48_000
        sine += Double(values[index]) * sin(phase)
        cosine += Double(values[index]) * cos(phase)
    }
    return 2 * hypot(sine, cosine) / Double(high - low)
}

@main
struct WriterQA {
    static func main() async {
        do {
            let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "work/native-qa/results")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let runID = UUID().uuidString
            let mixedURL = try await recordMixed(to: folder.appendingPathComponent("mixed-\(runID).mp4"))
            let asset = AVURLAsset(url: mixedURL)
            let duration = try await asset.load(.duration).seconds
            let video = try await asset.loadTracks(withMediaType: .video)
            try require(video.count == 1, "Expected one video track")
            let size = try await video[0].load(.naturalSize)
            try require(size == CGSize(width: 320, height: 180), "Wrong encoded dimensions: \(size)")
            try require(abs(duration - 3) < 0.08, "Pause was not removed: duration=\(duration)")
            let decoded = try await decodeAudio(asset)
            let windows: [(String, Double, Double)] = [("beforeMute", 0.3, 0.8), ("muted", 1.5, 1.8), ("afterMute", 2.2, 2.7)]
            var signals: [String: [String: Double]] = [:]
            for (name, start, end) in windows {
                let mic = amplitude(decoded, frequency: 440, start: start, end: end)
                let system = amplitude(decoded, frequency: 880, start: start, end: end)
                signals[name] = ["microphone440Hz": mic, "system880Hz": system]
                try require(system > 0.07, "System audio absent in \(name): amplitude=\(system)")
                if name == "muted" { try require(mic < 0.015, "Microphone still audible while muted: \(mic)") }
                else { try require(mic > 0.07, "44.1k microphone absent in \(name): amplitude=\(mic)") }
            }
            let pausedURL = try await recordPreOriginPause(to: folder.appendingPathComponent("pre-origin-pause-\(runID).mp4"))
            let pausedDuration = try await AVURLAsset(url: pausedURL).load(.duration).seconds
            try require(abs(pausedDuration - 1) < 0.08, "Pre-origin pause consumed first take: \(pausedDuration)")
            let (partialURL, rejection) = try await recordClockAheadFailure(to: folder.appendingPathComponent("clock-ahead-partial-\(runID).mp4"))
            let partial = AVURLAsset(url: partialURL)
            let partialDuration = try await partial.load(.duration).seconds
            try require(abs(partialDuration - 1) < 0.08, "Bad timestamp extended partial file: \(partialDuration)")
            let partialAudio = try await decodeAudio(partial)
            let partialAmplitude = amplitude(partialAudio, frequency: 440, start: 0.2, end: 0.8)
            try require(partialAmplitude > 0.12, "Saved partial lost its valid audio: \(partialAmplitude)")
            let generator = AVAssetImageGenerator(asset: partial)
            let decodedFrame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            try require(decodedFrame.width == 160 && decodedFrame.height == 90,
                        "Saved partial video could not be decoded at expected dimensions")
            let report: [String: Any] = ["passed": true, "mixedURL": mixedURL.path,
                "duration": duration, "dimensions": [size.width, size.height],
                "decodedFrames": decoded.count, "signals": signals,
                "preOriginPauseURL": pausedURL.path, "preOriginPauseDuration": pausedDuration,
                "clockAheadRejection": rejection, "partialURL": partialURL.path,
                "partialDuration": partialDuration, "partialMicrophoneAmplitude": partialAmplitude]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("writer-report.json"))
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("WRITER_QA_FAILURE: \(error)\n", stderr)
            exit(1)
        }
    }
}
