import AppKit
import AVFoundation
import SwiftUI

final class RelayOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var circular = false
    func makeNSView(context: Context) -> CameraPreviewSurface { CameraPreviewSurface(session: session, circular: circular) }
    func updateNSView(_ nsView: CameraPreviewSurface, context: Context) {
        if nsView.previewLayer.session !== session { nsView.previewLayer.session = session }
        if nsView.circular != circular { nsView.circular = circular }
    }
}

final class CameraPreviewSurface: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    var circular: Bool { didSet { needsLayout = true } }
    init(session: AVCaptureSession, circular: Bool = false) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        self.circular = circular
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = circular ? min(bounds.width, bounds.height) / 2 : 0
        previewLayer.frame = bounds
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        CATransaction.commit()
    }
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class CameraOverlayInteraction: ObservableObject {
    @Published private(set) var pointerInside = false
    @Published private(set) var resizeFocused = false
    func setResizeFocused(_ focused: Bool) {
        if resizeFocused != focused { resizeFocused = focused }
    }
    func setPointerInside(_ inside: Bool) {
        if pointerInside != inside { pointerInside = inside }
    }
}

/// The transparent square corners pass mouse input to the app underneath.
/// Polling the pointer also detects entry while this window ignores mouse events.
final class CircularCameraHostingView: NSHostingView<AnyView> {
    let interaction: CameraOverlayInteraction
    private var pointerTimer: Timer?
    private var tracking: NSTrackingArea?
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    init(rootView: AnyView, interaction: CameraOverlayInteraction) {
        self.interaction = interaction
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    @MainActor required init(rootView: AnyView) { fatalError("Use init(rootView:interaction:)") }
    @MainActor required dynamic init?(coder: NSCoder) { nil }
    deinit { pointerTimer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointerTimer?.invalidate()
        pointerTimer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.refreshPointer() }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { refreshPointer() }
    override func mouseMoved(with event: NSEvent) { refreshPointer() }
    override func mouseExited(with event: NSEvent) { refreshPointer() }

    func containsCameraPoint(_ point: NSPoint) -> Bool {
        let radius = min(bounds.width, bounds.height) / 2
        guard radius > 0 else { return false }
        return hypot(point.x - bounds.midX, point.y - bounds.midY) <= radius
    }

    func updatePointer(at point: NSPoint, dragging: Bool = false) {
        let inside = containsCameraPoint(point)
        let continuingCameraDrag = dragging && interaction.pointerInside
        interaction.setPointerInside(inside || continuingCameraDrag)
        // Preserve AppKit's drag/resize capture until the mouse is released.
        if !dragging { window?.ignoresMouseEvents = !inside }
    }

    private func refreshPointer() {
        guard let window, window.isVisible else {
            interaction.setPointerInside(false)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updatePointer(at: point, dragging: NSEvent.pressedMouseButtons & 1 != 0)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard containsCameraPoint(local) else { return nil }
        // Give the visible native resize target mouse events directly while
        // leaving the remaining controls to SwiftUI's event routing.
        if interaction.pointerInside || interaction.resizeFocused,
           let grip = resizeGrip(in: self), !grip.isHiddenOrHasHiddenAncestor,
           grip.bounds.contains(grip.convert(local, from: self)) { return grip }
        return super.hitTest(point)
    }

    private func resizeGrip(in view: NSView) -> CameraResizeGripView? {
        if let grip = view as? CameraResizeGripView { return grip }
        for child in view.subviews {
            if let grip = resizeGrip(in: child) { return grip }
        }
        return nil
    }
}

struct FloatingCameraView: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var interaction: CameraOverlayInteraction
    let onOpen: () -> Void
    let onClose: () -> Void
    private enum Control: Hashable { case open, close, pause, mute, finish, enable, cameraOff }
    @FocusState private var focusedControl: Control?
    @AccessibilityFocusState private var accessibleControl: Control?
    private var controlsVisible: Bool { interaction.pointerInside || interaction.resizeFocused || focusedControl != nil || accessibleControl != nil }

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle().fill(Color(red: 0.93, green: 0.91, blue: 0.98))
                if controller.cameraReady {
                    CameraPreview(session: controller.cameraSession, circular: true)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash").font(.system(size: diameter * 0.12, weight: .light))
                        Text("Camera off").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color(nsColor: RelayStyle.purple))
                    .accessibilityElement(children: .combine)
                }
                controls(diameter: diameter)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
                    .animation(.easeInOut(duration: 0.15), value: controlsVisible)
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Floating camera")
        }
        .background(Color.clear)
    }

    private func controls(diameter: CGFloat) -> some View {
        ZStack {
            HStack(spacing: 5) {
                control(.open, symbol: "macwindow", label: "Open Relay", action: onOpen)
                Spacer(minLength: 2)
                if controller.phase.isLive {
                    HStack(spacing: 4) {
                        Circle().fill(controller.phase == .paused ? Color.orange : Color.red).frame(width: 5, height: 5)
                        Text(recordingTime(controller.elapsed)).monospacedDigit()
                    }
                    .font(.system(size: diameter < 220 ? 9 : 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(.black.opacity(0.7), in: Capsule())
                }
                Spacer(minLength: 2)
                control(.close, symbol: "xmark", label: "Hide floating camera", action: onClose)
            }
            .frame(width: diameter * 0.69)
            .position(x: diameter / 2, y: diameter * 0.19)

            Group {
                if controller.phase.isLive {
                    HStack(spacing: 6) {
                        control(.pause, symbol: controller.phase == .paused ? "play.fill" : "pause.fill", label: controller.phase == .paused ? "Resume recording" : "Pause recording") {
                            controller.phase == .paused ? controller.resume() : controller.pause()
                        }
                        control(.mute, symbol: controller.microphoneMuted ? "mic.slash.fill" : "mic.fill", label: controller.microphoneMuted ? "Unmute microphone" : "Mute microphone") {
                            controller.setMicrophoneMuted(!controller.microphoneMuted)
                        }
                        control(.finish, symbol: "stop.fill", label: "Finish recording", tint: .red) { Task { await controller.stop() } }
                    }
                    .padding(6).background(.black.opacity(0.7), in: Capsule())
                } else if controller.phase.isCapturing {
                    Text(controller.phase.title).font(.system(size: 10, weight: .medium))
                        .padding(8).background(.black.opacity(0.7), in: Capsule())
                } else if controller.cameraReady {
                    control(.cameraOff, symbol: "video.slash", label: "Turn camera off") { Task { await controller.stopCameraPreview() } }
                } else {
                    Button("Enable camera") {
                        Task {
                            do { try await controller.prepareCamera() }
                            catch { if !(error is CancellationError) { controller.errorMessage = error.localizedDescription } }
                        }
                    }
                    .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.black.opacity(0.75), in: Capsule())
                    .focused($focusedControl, equals: .enable)
                    .accessibilityFocused($accessibleControl, equals: .enable)
                }
            }
            .position(x: diameter / 2, y: diameter * 0.74)

            CameraResizeGrip(interaction: interaction)
                .frame(width: 28, height: 28)
                .position(x: diameter * 0.82, y: diameter * 0.62)
        }
        .foregroundStyle(.white)
    }

    private func control(_ id: Control, symbol: String, label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint).frame(width: 30, height: 30)
                .background(.black.opacity(0.65), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .focused($focusedControl, equals: id)
        .accessibilityFocused($accessibleControl, equals: id)
    }
}

/// An in-circle resize target keeps transparent window corners click-through.
struct CameraResizeGrip: NSViewRepresentable {
    let interaction: CameraOverlayInteraction
    func makeNSView(context: Context) -> CameraResizeGripView { CameraResizeGripView(interaction: interaction) }
    func updateNSView(_ view: CameraResizeGripView, context: Context) {}
}

final class CameraResizeGripView: NSView {
    let interaction: CameraOverlayInteraction
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(interaction: CameraOverlayInteraction) {
        self.interaction = interaction
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        toolTip = "Drag to resize camera. Arrow keys make it smaller or larger."
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Resize floating camera")
        setAccessibilityHelp("Drag to resize. Use arrow keys, or the smaller and larger actions.")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Make camera smaller", target: self, selector: #selector(makeSmaller)),
            NSAccessibilityCustomAction(name: "Make camera larger", target: self, selector: #selector(makeLarger))
        ])
    }
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool { interaction.setResizeFocused(true); needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { interaction.setResizeFocused(false); needsDisplay = true; return true }
    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        interaction.setResizeFocused(focused)
        if focused, window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        let grip = NSBezierPath()
        grip.lineWidth = 1.5
        grip.lineCapStyle = .round
        for offset: CGFloat in [0, 5, 10] {
            grip.move(to: NSPoint(x: 8 + offset, y: 8))
            grip.line(to: NSPoint(x: 20, y: 20 - offset))
        }
        NSColor.white.withAlphaComponent(0.9).setStroke()
        grip.stroke()
        if window?.firstResponder === self {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = NSEvent.mouseLocation
        let original = window.frame
        // AppKit retains drag capture while the pointer leaves the visible circle.
        window.ignoresMouseEvents = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            let dx = current.x - start.x, dy = start.y - current.y
            let delta = abs(dx) >= abs(dy) ? dx : dy
            resizeCamera(to: original.width + delta, anchoredAt: NSPoint(x: original.minX, y: original.maxY))
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125, 27: _ = resizeCamera(by: -20)
        case 124, 126, 24: _ = resizeCamera(by: 20)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformIncrement() -> Bool { resizeCamera(by: 20) }
    override func accessibilityPerformDecrement() -> Bool { resizeCamera(by: -20) }
    @objc func makeSmaller() -> Bool { resizeCamera(by: -20) }
    @objc func makeLarger() -> Bool { resizeCamera(by: 20) }

    @discardableResult
    func resizeCamera(by delta: CGFloat) -> Bool {
        guard let window else { return false }
        let frame = window.frame
        return resizeCamera(to: frame.width + delta, anchoredAt: NSPoint(x: frame.minX, y: frame.maxY))
    }
    @discardableResult
    func resizeCamera(to requested: CGFloat, anchoredAt anchor: NSPoint) -> Bool {
        guard let window else { return false }
        let diameter = min(480, max(200, requested))
        window.setFrame(NSRect(x: anchor.x, y: anchor.y - diameter, width: diameter, height: diameter), display: true)
        setAccessibilityValue("\(Int(diameter)) points")
        return true
    }
}

final class LauncherHandleView: NSView {
    private let onOpen: () -> Void
    private let onHide: () -> Void
    private let imageView = NSImageView()
    private let dot = NSView()

    init(onOpen: @escaping () -> Void, onHide: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onHide = onHide
        super.init(frame: NSRect(x: 0, y: 0, width: 58, height: 58))
        wantsLayer = true
        layer?.backgroundColor = RelayStyle.purple.cgColor
        layer?.cornerRadius = 19
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        imageView.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
        imageView.contentTintColor = .white
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 17, y: 17, width: 24, height: 24)
        addSubview(imageView)
        dot.frame = NSRect(x: 42, y: 42, width: 10, height: 10)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.layer?.borderWidth = 2
        dot.layer?.borderColor = NSColor.white.cgColor
        addSubview(dot)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open Relay")
        setAccessibilityHelp("Click to open the recording studio. Drag to reposition this launcher. Right-click to hide it.")
        imageView.setAccessibilityElement(false)
        dot.setAccessibilityElement(false)
        updatePhase(.idle)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func accessibilityPerformPress() -> Bool { onOpen(); return true }

    func updatePhase(_ phase: CapturePhase) {
        dot.isHidden = !phase.isCapturing
        dot.layer?.backgroundColor = (phase == .paused ? NSColor.systemOrange : NSColor.systemRed).cgColor
        toolTip = "Open Relay · Drag to move · Right-click to hide"
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = NSEvent.mouseLocation
        let origin = window.frame.origin
        var moved = false
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { if !moved { onOpen() }; break }
            let current = NSEvent.mouseLocation
            let dx = current.x - point.x, dy = current.y - point.y
            if hypot(dx, dy) > 3 { moved = true }
            if moved { window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy)) }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Relay", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let hide = NSMenuItem(title: "Hide Launcher", action: #selector(hideFromMenu), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func openFromMenu() { onOpen() }
    @objc private func hideFromMenu() { onHide() }
}
