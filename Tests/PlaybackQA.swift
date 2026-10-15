import AppKit
import AVFoundation
import AVKit
import Foundation
import SwiftUI

enum PlaybackQAError: Error { case failed(String) }

@MainActor
final class WeakPlayerView {
    weak var value: AVPlayerView?
    init(_ view: AVPlayerView) { value = view }
}

func playbackCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PlaybackQAError.failed(message) }
}

@MainActor
func awaitPlaybackCondition(_ label: String, timeout: Double = 6,
                            condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { throw PlaybackQAError.failed("Timed out waiting for \(label)") }
        try await Task.sleep(nanoseconds: 30_000_000)
    }
}

@MainActor
func nativePlayer(in view: NSView?) -> AVPlayerView? {
    guard let view else { return nil }
    if let player = view as? AVPlayerView { return player }
    return view.subviews.lazy.compactMap { nativePlayer(in: $0) }.first
}

@MainActor
func runPlaybackQA(source: URL, resultFolder: URL) async throws {
    let sourceAsset = AVURLAsset(url: source)
    let sourceAudio = try await sourceAsset.loadTracks(withMediaType: .audio)
    try playbackCheck(sourceAudio.isEmpty, "Use a synthetic silent video so initial playback cannot emit audio")
    let libraryFolder = resultFolder.appendingPathComponent("playback-library-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
    let url = libraryFolder.appendingPathComponent("Synthetic playback regression.mp4")
    try FileManager.default.copyItem(at: source, to: url)
    let library = LibraryStore(directoryURL: libraryFolder)
    let controller = CaptureController()
    let cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
    let micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    let root = StudioView(controller: controller, library: library, onShowCamera: {}, onShowLauncher: {})
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1080, height: 760),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Relay device-free playback QA"
    window.contentView = NSHostingView(rootView: root)
    window.orderFrontRegardless()
    defer { window.contentView = nil; window.orderOut(nil) }
    window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 250_000_000)

    var cycles: [[String: Any]] = []
    for cycle in 0..<3 {
        // This is the production post-recording path: library refresh, page switch,
        // SwiftUI sheet construction, PlaybackView, and its native AVPlayerView.
        NotificationCenter.default.post(name: .relayRecordingFinished, object: url)
        try await awaitPlaybackCondition("production playback sheet") {
            autoreleasepool { nativePlayer(in: window.attachedSheet?.contentView) != nil }
        }
        let (player, weakView, viewType): (AVPlayer, WeakPlayerView, String) = try autoreleasepool {
            guard let view = nativePlayer(in: window.attachedSheet?.contentView), let player = view.player else {
                throw PlaybackQAError.failed("No real AVPlayerView in playback sheet")
            }
            try playbackCheck(view.controlsStyle == .inline, "Native playback controls missing")
            try playbackCheck(view.videoGravity == .resizeAspect, "Playback should preserve aspect ratio")
            return (player, WeakPlayerView(view), String(describing: type(of: view)))
        }
        player.isMuted = true
        try await awaitPlaybackCondition("playable AVPlayerItem") { player.currentItem?.status == .readyToPlay }
        try playbackCheck(player.currentItem?.error == nil, "Player item failed: \(String(describing: player.currentItem?.error))")
        let duration = player.currentItem!.duration.seconds
        try playbackCheck(duration.isFinite && duration > 1, "Playback duration is unusable: \(duration)")
        await player.seek(to: .zero)
        player.play()
        try await awaitPlaybackCondition("actual playback progress") { player.currentTime().seconds > 0.12 }
        player.pause()
        let target = CMTime(seconds: min(0.75, duration / 2), preferredTimescale: 600)
        let sought = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        try playbackCheck(sought && abs(player.currentTime().seconds - target.seconds) < 0.08,
                          "Native seek did not reach target")
        try playbackCheck(player.rate == 0, "Pause did not stop playback")
        player.play()
        try await awaitPlaybackCondition("playback resumed before dismissal") { player.rate > 0 }
        // The production new-recording navigation dismisses the sheet, exercising
        // PlaybackView.onDisappear plus RelayPlayerView.dismantleNSView.
        // Do not artificially retain the sheet/native view while asking AppKit
        // to destroy their SwiftUI hosting tree.
        NotificationCenter.default.post(name: .relayOpenRecorder, object: nil)
        do {
            try await awaitPlaybackCondition("native player teardown") {
                window.attachedSheet == nil && player.rate == 0
            }
        } catch {
            throw PlaybackQAError.failed("Teardown state: sheet=\(window.attachedSheet != nil), currentItem=\(player.currentItem != nil), nativePlayer=\(weakView.value?.player != nil), rate=\(player.rate)")
        }
        try playbackCheck(controller.phase == .idle && !controller.cameraSession.isRunning,
                          "Playback regression unexpectedly started capture")
        cycles.append(["cycle": cycle + 1, "duration": duration, "nativeView": viewType,
                       "playbackAdvanced": true, "seekPassed": true, "sheetDismissed": true,
                       "currentItemRetainedAfterDismiss": player.currentItem != nil,
                       "nativeViewRetainedAfterDismiss": weakView.value != nil,
                       "dismissedTimeControlStatus": player.timeControlStatus.rawValue, "dismissedRate": player.rate])
    }
    try playbackCheck(cameraAuthorization == AVCaptureDevice.authorizationStatus(for: .video),
                      "Camera authorization changed during playback-only test")
    try playbackCheck(micAuthorization == AVCaptureDevice.authorizationStatus(for: .audio),
                      "Microphone authorization changed during playback-only test")
    let report: [String: Any] = ["passed": true, "productionNotificationPath": true,
        "cycles": cycles, "devicesStarted": false, "source": source.path,
        "limitation": "SwiftUI may cache the dismissed sheet bridge and media item; immediate view deallocation/currentItem removal is not asserted. Dismissal must stop playback (rate0). Done-button interaction and physical audio output are not tested."]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: resultFolder.appendingPathComponent("playback-report.json"))
    print(String(decoding: data, as: UTF8.self))
}

@main
struct PlaybackQA {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            fputs("Usage: playback-qa synthetic-silent.mp4 [result-folder]\n", stderr); exit(2)
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let folder = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "work/native-qa/results")
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            Task { @MainActor in
                do { try await runPlaybackQA(source: source, resultFolder: folder); exit(0) }
                catch { fputs("PLAYBACK_QA_FAILURE: \(error)\n", stderr); exit(1) }
            }
        }
        application.run()
    }
}
