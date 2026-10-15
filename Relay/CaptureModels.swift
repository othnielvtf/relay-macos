import AppKit
import AVFoundation
import Combine
import CoreGraphics

enum CaptureMode: String, CaseIterable, Identifiable {
    case screenAndCamera, screen, camera
    var id: String { rawValue }
    var title: String {
        switch self { case .screenAndCamera: return "Screen + camera"; case .screen: return "Screen only"; case .camera: return "Camera only" }
    }
    var symbol: String {
        switch self { case .screenAndCamera: return "rectangle.inset.filled.and.person.filled"; case .screen: return "display"; case .camera: return "video" }
    }
    var usesScreen: Bool { self != .camera }
    var usesCamera: Bool { self != .screen }
}

enum CapturePhase: String {
    case idle, preparing, recording, paused, finishing
    var isCapturing: Bool { self != .idle }
    var isLive: Bool { self == .recording || self == .paused }
    var title: String {
        switch self { case .idle: return "Ready when you are"; case .preparing: return "Preparing…"; case .recording: return "Recording"; case .paused: return "Paused"; case .finishing: return "Saving video…" }
    }
}

struct CaptureSource: Identifiable, Hashable {
    enum Kind: String { case display, window }
    let id: String
    let title: String
    let kind: Kind
    let displayID: CGDirectDisplayID?
    let windowID: CGWindowID?
    let pixelWidth: Int
    let pixelHeight: Int
}

struct CaptureOptions {
    var mode: CaptureMode = .screenAndCamera
    var sourceID: String?
    var microphone = true
    var systemAudio = false
    /// Camera center, normalized to the output image. Y increases downward.
    var cameraX = 0.13
    var cameraY = 0.79
    var cameraSize = 0.18
    var outputURL: URL
}

func recordingTime(_ duration: TimeInterval) -> String {
    let total = max(0, Int(duration))
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
    return String(format: "%02d:%02d", total / 60, total % 60)
}

enum RelayStyle {
    static let purple = NSColor(srgbRed: 0.39, green: 0.36, blue: 0.96, alpha: 1)
    static let bundleID = "studio.relay.mac"
}

extension Notification.Name {
    static let relayOpenRecorder = Notification.Name("RelayOpenRecorder")
    static let relayRecordingFinished = Notification.Name("RelayRecordingFinished")
}
