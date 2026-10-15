import AppKit
import AVFoundation
import Foundation
import SwiftUI

enum OverlayQAError: Error { case failed(String) }

func overlayCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw OverlayQAError.failed(message) }
}

@MainActor
func snapshot(_ host: NSView, to url: URL) throws -> NSBitmapImageRep {
    host.needsLayout = true
    host.layoutSubtreeIfNeeded()
    host.needsDisplay = true
    host.displayIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw OverlayQAError.failed("Actual hosting view did not provide a bitmap")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw OverlayQAError.failed("Could not encode actual overlay pixels")
    }
    try png.write(to: url)
    return bitmap
}

func alpha(_ image: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
    image.colorAt(x: x, y: y)?.alphaComponent ?? -1
}

func difference(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> Int {
    var changed = 0
    for y in stride(from: 0, to: min(first.pixelsHigh, second.pixelsHigh), by: 2) {
        for x in stride(from: 0, to: min(first.pixelsWide, second.pixelsWide), by: 2) {
            guard let a = first.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  let b = second.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent) > 0.15 { changed += 1 }
        }
    }
    return changed
}

@MainActor
func setPointer(_ host: CircularCameraHostingView, _ point: NSPoint, dragging: Bool = false) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) { host.updatePointer(at: point, dragging: dragging) }
    host.needsLayout = true
    host.layoutSubtreeIfNeeded()
}

@MainActor
func findResizeGrip(in view: NSView) -> CameraResizeGripView? {
    if let grip = view as? CameraResizeGripView { return grip }
    return view.subviews.lazy.compactMap { findResizeGrip(in: $0) }.first
}

@MainActor
func runOverlayQA(in folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let controller = CaptureController()
    let cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
    let micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    let interaction = CameraOverlayInteraction()
    var openCount = 0, closeCount = 0
    let view = FloatingCameraView(controller: controller, interaction: interaction,
                                  onOpen: { openCount += 1 }, onClose: { closeCount += 1 })
    let host = CircularCameraHostingView(rootView: AnyView(view.environment(\.colorScheme, .light)),
                                         interaction: interaction)
    let panel = RelayOverlayPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 280, height: 280),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
    panel.contentView = host
    panel.orderFrontRegardless()
    defer { panel.contentView = nil; panel.orderOut(nil) }
    try await Task.sleep(nanoseconds: 250_000_000)
    var sizes: [[String: Any]] = []
    for diameter in [200, 280, 420] {
        let size = CGFloat(diameter)
        panel.setContentSize(NSSize(width: size, height: size))
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        host.layoutSubtreeIfNeeded()
        let center = NSPoint(x: size / 2, y: size / 2)
        let corner = NSPoint(x: 2, y: 2)
        try overlayCheck(host.containsCameraPoint(center), "Circle excludes center at \(diameter)")
        try overlayCheck(!host.containsCameraPoint(corner), "Circle includes transparent corner at \(diameter)")
        try overlayCheck(host.hitTest(corner) == nil, "Transparent corner accepts hit at \(diameter)")
        try overlayCheck(host.hitTest(center) != nil, "Circle center is not interactive at \(diameter)")
        setPointer(host, corner)
        try overlayCheck(!interaction.pointerInside && panel.ignoresMouseEvents, "Corner did not pass through at \(diameter)")
        setPointer(host, corner, dragging: true)
        try overlayCheck(!interaction.pointerInside, "An outside drag revealed controls at \(diameter)")
        let before = try snapshot(host, to: folder.appendingPathComponent("camera-off-\(diameter).png"))
        setPointer(host, center)
        try overlayCheck(interaction.pointerInside && !panel.ignoresMouseEvents, "Center did not enable controls at \(diameter)")
        let hover = try snapshot(host, to: folder.appendingPathComponent("camera-hover-\(diameter).png"))
        let changed = difference(before, hover)
        try overlayCheck(changed > 80, "Hover controls did not change actual native pixels at \(diameter): \(changed)")
        for (name, bitmap) in [("idle", before), ("hover", hover)] {
            let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
            for point in [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)] {
                try overlayCheck(alpha(bitmap, x: point.0, y: point.1) < 0.02,
                                 "\(name) corner is not transparent at \(diameter)")
            }
            try overlayCheck(alpha(bitmap, x: w / 2, y: h / 2) > 0.95,
                             "\(name) circle center is missing at \(diameter)")
        }
        setPointer(host, corner, dragging: true)
        try overlayCheck(interaction.pointerInside && !panel.ignoresMouseEvents,
                         "Own drag lost controls/mouse capture outside circle at \(diameter)")
        setPointer(host, corner)
        try overlayCheck(!interaction.pointerInside && panel.ignoresMouseEvents,
                         "Drag release outside did not restore pass-through at \(diameter)")
        let after = try snapshot(host, to: folder.appendingPathComponent("camera-after-hover-\(diameter).png"))
        try overlayCheck(difference(before, after) < 20, "Controls did not disappear after hover at \(diameter)")
        sizes.append(["diameter": diameter, "pixelWidth": before.pixelsWide,
                      "transparentCorners": true, "circleHitTest": true,
                      "hoverChangedSampledPixels": changed, "passThroughRestored": true])
    }
    var liveStates: [[String: Any]] = []
    for diameter in [200, 288] {
        let size = CGFloat(diameter)
        panel.setContentSize(NSSize(width: size, height: size))
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        controller.phase = .recording; controller.elapsed = 65; controller.microphoneMuted = false
        setPointer(host, NSPoint(x: 2, y: 2))
        let hidden = try snapshot(host, to: folder.appendingPathComponent("camera-recording-\(diameter).png"))
        setPointer(host, NSPoint(x: size / 2, y: size / 2))
        let recording = try snapshot(host, to: folder.appendingPathComponent("camera-recording-hover-\(diameter).png"))
        try overlayCheck(difference(hidden, recording) > 100, "Recording controls absent at \(diameter)")
        guard let grip = findResizeGrip(in: host) else { throw OverlayQAError.failed("Actual native resize grip missing") }
        let gripPoint = host.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), from: grip)
        let gripHitPoint = grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: host.superview)
        try overlayCheck(host.containsCameraPoint(gripPoint), "Resize grip is outside circle at \(diameter)")
        let gripHit = host.hitTest(gripHitPoint)
        try overlayCheck(gripHit === grip, "Visible native grip was not the hit target at \(diameter)")
        controller.phase = .paused; controller.microphoneMuted = true
        let paused = try snapshot(host, to: folder.appendingPathComponent("camera-paused-hover-\(diameter).png"))
        try overlayCheck(difference(recording, paused) > 20, "Pause/mute state did not change real controls at \(diameter)")
        setPointer(host, NSPoint(x: 2, y: 2))
        let hiddenPaused = try snapshot(host, to: folder.appendingPathComponent("camera-paused-\(diameter).png"))
        try overlayCheck(difference(hidden, hiddenPaused) < 20, "Live controls remain visible after pointer exit at \(diameter)")
        try overlayCheck(host.hitTest(gripHitPoint) !== grip, "Hidden resize grip still receives mouse hits at \(diameter)")
        liveStates.append(["diameter": diameter, "timer": "01:05", "recordingPauseMuteVisible": true,
                           "resumeUnmuteVisible": true, "hoverExitHidesControls": true, "resizeGripInsideCircle": true,
                           "gripHitTarget": gripHit.map { String(describing: type(of: $0)) } ?? "none"])
    }
    controller.phase = .idle; controller.microphoneMuted = false
    panel.setContentSize(NSSize(width: 280, height: 280)); host.frame = NSRect(x: 0, y: 0, width: 280, height: 280)
    setPointer(host, NSPoint(x: 140, y: 140))
    guard let grip = findResizeGrip(in: host) else { throw OverlayQAError.failed("No production resize grip") }
    let original = panel.frame
    try overlayCheck(grip.accessibilityPerformIncrement() && panel.frame.width == 300 && panel.frame.height == 300,
                     "Native increment did not resize actual panel to300 square")
    try overlayCheck(abs(panel.frame.minX - original.minX) < 0.1 && abs(panel.frame.maxY - original.maxY) < 0.1,
                     "Native resize moved the top-left anchor")
    try overlayCheck(grip.accessibilityPerformDecrement() && panel.frame.width == 280,
                     "Native decrement did not return to280")
    let anchor = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    try overlayCheck(grip.resizeCamera(to: 10_000, anchoredAt: anchor) && panel.frame.size == NSSize(width: 480, height: 480),
                     "Resize maximum480 clamp failed")
    try overlayCheck(grip.resizeCamera(to: 10, anchoredAt: anchor) && panel.frame.size == NSSize(width: 200, height: 200),
                     "Resize minimum200 clamp failed")
    _ = grip.resizeCamera(to: 280, anchoredAt: anchor)
    try overlayCheck(panel.makeFirstResponder(grip) && interaction.resizeFocused,
                     "Native keyboard focus did not reveal resize controls")
    setPointer(host, NSPoint(x: 2, y: 2))
    try overlayCheck(interaction.resizeFocused, "Pointer exit discarded keyboard resize focus")
    _ = try snapshot(host, to: folder.appendingPathComponent("camera-keyboard-focus-280.png"))
    _ = panel.makeFirstResponder(nil)
    try overlayCheck(!interaction.resizeFocused, "Native blur did not clear resize focus")
    // Exercise the production native preview-layer mask without opening a device.
    let preview = CameraPreviewSurface(session: controller.cameraSession, circular: true)
    preview.frame = NSRect(x: 0, y: 0, width: 280, height: 280)
    preview.needsLayout = true; preview.layoutSubtreeIfNeeded()
    try overlayCheck(preview.layer?.cornerRadius == 140 && preview.layer?.masksToBounds == true,
                     "Actual AVCaptureVideoPreviewLayer surface lacks circular native clipping")
    try overlayCheck(!controller.cameraSession.isRunning && controller.phase == .idle,
                     "Overlay QA unexpectedly started capture")
    try overlayCheck(openCount == 0 && closeCount == 0, "Rendering invoked an overlay action")
    try overlayCheck(cameraAuthorization == AVCaptureDevice.authorizationStatus(for: .video)
                     && micAuthorization == AVCaptureDevice.authorizationStatus(for: .audio),
                     "Overlay test changed media authorization")
    let report: [String: Any] = ["passed": true, "actualHostingView": String(describing: type(of: host)),
        "sizes": sizes, "liveStates": liveStates, "nativeResizeBounds": [200, 480],
        "nativeResizeFocus": true, "nativeResizeAnchor": "top-left",
        "nativePreviewCircleRadius": 140, "devicesStarted": false,
        "physicalPointerMoved": false,
        "limitation": "Native resize methods and focus are exercised offscreen. Physical drag-event routing is not tested; NSHostingView may serve as the native hit target for representable controls."]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: folder.appendingPathComponent("overlay-report.json"))
    print(String(decoding: data, as: UTF8.self))
}

@main
struct OverlayQA {
    @MainActor
    static func main() {
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "work/native-qa/overlay-results")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            Task { @MainActor in
                do { try await runOverlayQA(in: folder); exit(0) }
                catch { fputs("OVERLAY_QA_FAILURE: \(error)\n", stderr); exit(1) }
            }
        }
        app.run()
    }
}
