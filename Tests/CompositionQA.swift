import AppKit
import AVFoundation
import CoreMedia
import Foundation

enum CompositionQAError: Error { case failed(String) }

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CompositionQAError.failed(message) }
}

struct FramePixels {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width; height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = pixels
    }

    func rgb(_ x: Int, _ y: Int) -> [Double] {
        let offset = (y * width + x) * 4
        return (0..<3).map { Double(data[offset + $0]) / 255 }
    }
}

@main
struct CompositionQA {
    @MainActor
    static func main() async {
        do {
            let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "work/native-qa/results")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("composition-\(UUID().uuidString).mp4")
            _ = try await CaptureController.writeSyntheticSmoke(to: url)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            try check(tracks.count == 1, "Expected one video track")
            let size = try await tracks[0].load(.naturalSize)
            try check(size == CGSize(width: 3200, height: 1800), "Native3200x1800 dimensions were lost: \(size)")
            try check(abs(duration - 2) < 0.08, "Pause was not removed from compositor output: \(duration)")
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 15)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 15)
            var colors: [String: [Double]] = [:]
            for (index, time) in [0.5, 1.5].enumerated() {
                let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
                let pixels = try FramePixels(image)
                // Bitmap coordinates begin at the top; normalized cameraY also increases downward.
                let center = index == 0 ? (800, 1350) : (2400, 450)
                let other = index == 0 ? (2400, 450) : (800, 1350)
                let left = pixels.rgb(center.0 - 100, center.1)
                let right = pixels.rgb(center.0 + 100, center.1)
                let corner = pixels.rgb(center.0 + 250, center.1 + 250)
                let oldPosition = pixels.rgb(other.0, other.1)
                colors["frame\(index)-left"] = left; colors["frame\(index)-right"] = right
                colors["frame\(index)-corner"] = corner; colors["frame\(index)-otherPosition"] = oldPosition
                try check(left[0] > 0.8 && left[1] > 0.65 && left[2] < 0.3,
                          "Mirrored yellow camera half absent at frame\(index): \(left)")
                try check(right[0] > 0.8 && right[1] < 0.4 && right[2] < 0.35,
                          "Mirrored red camera half absent at frame\(index): \(right)")
                try check(corner[2] > corner[0] + 0.3,
                          "Camera mask did not retain transparent circular corners: \(corner)")
                try check(oldPosition[2] > oldPosition[0] + 0.3,
                          "Camera was not moved away from other position: \(oldPosition)")
                let imageURL = folder.appendingPathComponent("composition-frame\(index).png")
                let bitmap = NSBitmapImageRep(cgImage: image)
                try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
            }
            let report: [String: Any] = ["passed": true, "url": url.path,
                "duration": duration, "dimensions": [size.width, size.height], "colors": colors]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("composition-report.json"))
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("COMPOSITION_QA_FAILURE: \(error)\n", stderr)
            exit(1)
        }
    }
}
