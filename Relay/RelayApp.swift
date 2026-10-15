import AppKit
import AVFoundation
import Combine
import Darwin
import SwiftUI

@main
struct RelayMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-test") {
            guard CommandLine.arguments.indices.contains(flag + 1) else {
                fputs("Usage: Relay --smoke-test /absolute/path/test.mp4\n", stderr)
                exit(2)
            }
            let destination = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do {
                    let url = try await CaptureController.writeSyntheticSmoke(to: destination)
                    let asset = AVURLAsset(url: url)
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    guard let track = tracks.first else { throw RecordingFailure.message("The smoke video has no video track.") }
                    let size = try await track.load(.naturalSize)
                    let duration = try await asset.load(.duration).seconds
                    guard size == CGSize(width: 3200, height: 1800), abs(duration - 2) < 0.15 else {
                        throw RecordingFailure.message("Smoke verification failed: \(size), \(duration) seconds.")
                    }
                    print("PASS: native 3200×1800 composition, moving mirrored camera, and pause removal; duration \(duration)s. \(url.path)")
                    exit(0)
                } catch {
                    fputs("Smoke test failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            app.run()
            return
        }
        let delegate = RelayAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class RelayAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller = CaptureController()
    let library = LibraryStore()
    private var mainWindow: NSWindow?
    private var cameraPanel: RelayOverlayPanel?
    private var launcherPanel: RelayOverlayPanel?
    private var launcherView: LauncherHandleView?
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var lastPhase = CapturePhase.idle
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()
        controller.onRecordingFinished = { [weak self] url in
            guard let self else { return }
            self.library.refresh()
            self.cameraPanel?.orderOut(nil)
            self.rebuildStatusMenu()
            guard !self.terminating else { return }
            self.showMain()
            NotificationCenter.default.post(name: .relayRecordingFinished, object: url)
        }
        controller.$phase.combineLatest(controller.$elapsed, controller.$microphoneMuted)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, _, _ in self?.updateStatus(phase) }
            .store(in: &subscriptions)
        showMain()
        if UserDefaults.standard.object(forKey: "showQuickLauncher") as? Bool ?? true { showLauncher() }
    }

    private func buildMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Relay")
        appMenu.addItem(withTitle: "About Relay", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Open Relay", #selector(openRelay), "0"))
        appMenu.addItem(item("New Recording", #selector(openRecorder), "n"))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Relay", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Relay", #selector(quitRelay), "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(item("Floating Camera", #selector(toggleCamera), ""))
        windowMenu.addItem(item("Quick Launcher", #selector(toggleLauncher), ""))
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
        value.target = self
        return value
    }

    private func buildStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Relay recorder")
        status.button?.image?.isTemplate = true
        status.button?.toolTip = "Relay — screen and camera recorder"
        status.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem = status
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Open Relay", #selector(openRelay)))
        menu.addItem(item("Record a Video…", #selector(openRecorder)))
        menu.addItem(.separator())
        let camera = item("Floating Camera", #selector(toggleCamera))
        camera.state = cameraPanel?.isVisible == true ? .on : .off
        menu.addItem(camera)
        let launcher = item("Quick Launcher", #selector(toggleLauncher))
        launcher.state = launcherPanel?.isVisible == true ? .on : .off
        menu.addItem(launcher)
        menu.addItem(.separator())
        let pause = item(controller.phase == .paused ? "Resume Recording" : "Pause Recording", #selector(togglePause))
        pause.isEnabled = controller.phase.isLive
        menu.addItem(pause)
        let mute = item(controller.microphoneMuted ? "Unmute Microphone" : "Mute Microphone", #selector(toggleMute))
        mute.isEnabled = controller.phase.isLive
        menu.addItem(mute)
        let finish = item("Finish Recording", #selector(finishRecording))
        finish.isEnabled = controller.phase.isLive
        menu.addItem(finish)
        menu.addItem(.separator())
        menu.addItem(item("Show Recordings in Finder", #selector(showRecordings)))
        menu.addItem(item("Quit Relay", #selector(quitRelay)))
        statusItem?.menu = menu
    }

    private func updateStatus(_ phase: CapturePhase) {
        statusItem?.button?.title = phase.isLive ? " " + recordingTime(controller.elapsed) : ""
        statusItem?.button?.contentTintColor = phase.isCapturing ? .systemRed : nil
        statusItem?.button?.toolTip = phase.isCapturing ? "Relay — \(phase.title) \(recordingTime(controller.elapsed))" : "Relay — screen and camera recorder"
        launcherView?.updatePhase(phase)
        if phase != lastPhase {
            if phase == .recording && lastPhase == .preparing {
                mainWindow?.orderOut(nil)
                NSApp.setActivationPolicy(.accessory)
                if controller.cameraReady { showCamera() }
            }
            lastPhase = phase
            rebuildStatusMenu()
        }
    }

    func showMain(recorder: Bool = false) {
        if mainWindow == nil {
            let root = StudioView(controller: controller, library: library,
                onShowCamera: { [weak self] in self?.showCamera() },
                onShowLauncher: { [weak self] in self?.showLauncher() })
                .environment(\.colorScheme, .light)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Relay"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.contentView = NSHostingView(rootView: root)
            window.minSize = NSSize(width: 920, height: 680)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("RelayStudio")
            if !window.setFrameUsingName("RelayStudio") { window.center() }
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if recorder { NotificationCenter.default.post(name: .relayOpenRecorder, object: nil) }
    }

    func showCamera() {
        if cameraPanel == nil {
            let interaction = CameraOverlayInteraction()
            let view = FloatingCameraView(controller: controller, interaction: interaction,
                onOpen: { [weak self] in self?.showMain(recorder: true) },
                onClose: { [weak self] in self?.hideCamera() })
            let panel = makeOverlay(size: NSSize(width: 288, height: 288), name: "RelayCamera")
            panel.minSize = NSSize(width: 200, height: 200)
            panel.maxSize = NSSize(width: 480, height: 480)
            panel.contentAspectRatio = NSSize(width: 1, height: 1)
            panel.hasShadow = false
            panel.acceptsMouseMovedEvents = true
            // Migrate the saved rectangular panel to a circle without moving its center.
            let previous = panel.frame
            let diameter = min(480, max(200, min(previous.width, previous.height)))
            var frame = NSRect(x: previous.midX - diameter / 2, y: previous.midY - diameter / 2,
                width: diameter, height: diameter)
            if let screen = panel.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - diameter)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - diameter)
            }
            panel.setFrame(frame, display: false)
            panel.contentView = CircularCameraHostingView(rootView: AnyView(view.environment(\.colorScheme, .light)), interaction: interaction)
            cameraPanel = panel
        }
        cameraPanel?.orderFrontRegardless()
        rebuildStatusMenu()
    }

    private func hideCamera() {
        cameraPanel?.orderOut(nil)
        if !controller.phase.isCapturing { Task { await controller.stopCameraPreview() } }
        rebuildStatusMenu()
    }

    func showLauncher() {
        if launcherPanel == nil {
            let panel = makeOverlay(size: NSSize(width: 58, height: 58), name: "RelayLauncher", resizable: false)
            let view = LauncherHandleView(onOpen: { [weak self] in self?.showMain(recorder: true) }, onHide: { [weak self] in self?.hideLauncher() })
            panel.contentView = view
            launcherPanel = panel
            launcherView = view
        }
        launcherView?.updatePhase(controller.phase)
        launcherPanel?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: "showQuickLauncher")
        rebuildStatusMenu()
    }

    private func hideLauncher() {
        launcherPanel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "showQuickLauncher")
        rebuildStatusMenu()
    }

    private func makeOverlay(size: NSSize, name: String, resizable: Bool = true) -> RelayOverlayPanel {
        let panel = RelayOverlayPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: resizable ? [.borderless, .nonactivatingPanel, .resizable] : [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        // Nonactivating panels remain visible while another app owns the Space.
        panel.level = .screenSaver
        panel.title = name == "RelayLauncher" ? "Relay Quick Launcher" : "Relay Camera"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName(name)
        if !panel.setFrameUsingName(name), let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.maxX - size.width - 28, y: frame.minY + (name == "RelayLauncher" ? 30 : 110))
            panel.setFrameOrigin(origin)
        }
        return panel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === mainWindow && controller.phase == .preparing { Task { await controller.stop() } }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
        if !controller.phase.isCapturing && cameraPanel?.isVisible != true { Task { await controller.stopCameraPreview() } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        if controller.phase.isCapturing {
            let alert = NSAlert()
            alert.messageText = "Finish your recording before quitting?"
            alert.informativeText = "Relay will save your video on this Mac, then quit."
            alert.addButton(withTitle: "Finish and Quit")
            alert.addButton(withTitle: "Keep Relay Open")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        terminating = true
        Task { await controller.shutdown(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    @objc private func openRelay() { showMain() }
    @objc private func openRecorder() { showMain(recorder: true) }
    @objc private func toggleCamera() { cameraPanel?.isVisible == true ? hideCamera() : showCamera() }
    @objc private func toggleLauncher() { launcherPanel?.isVisible == true ? hideLauncher() : showLauncher() }
    @objc private func togglePause() { controller.phase == .paused ? controller.resume() : controller.pause() }
    @objc private func toggleMute() { controller.setMicrophoneMuted(!controller.microphoneMuted) }
    @objc private func finishRecording() { Task { await controller.stop() } }
    @objc private func showRecordings() {
        do { try library.openFolder() }
        catch { controller.errorMessage = error.localizedDescription; showMain() }
    }
    @objc private func quitRelay() { NSApp.terminate(nil) }
}
