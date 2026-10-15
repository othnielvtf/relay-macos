import AppKit
import AVFoundation
import AVKit
import SwiftUI

private enum StudioPage: String, CaseIterable { case library, recorder }
private enum LibraryCollection: String, CaseIterable { case all = "All videos", recent = "Recent" }
private enum RecordingSort: String, CaseIterable { case newest = "Newest first", oldest = "Oldest first", title = "Title A–Z" }

@MainActor
struct StudioView: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var library: LibraryStore
    let onShowCamera: () -> Void
    let onShowLauncher: () -> Void

    @State private var page: StudioPage = .library
    @State private var collection: LibraryCollection = .all
    @State private var search = ""
    @State private var sort: RecordingSort = .newest
    @State private var showWelcome = true
    @State private var mode: CaptureMode = .screenAndCamera
    @State private var sourceID: String?
    @State private var microphone = true
    @State private var systemAudio = false
    @State private var cameraX = 0.13
    @State private var cameraY = 0.79
    @State private var showSources = false
    @State private var loadingSources = false
    @State private var starting = false
    @State private var playback: LocalRecording?
    @State private var renameTarget: LocalRecording?
    @State private var renameTitle = ""
    @State private var showRename = false
    @State private var trashTarget: LocalRecording?
    @State private var showTrash = false
    @State private var localError: String?
    @State private var toast: String?

    private let purple = Color(nsColor: RelayStyle.purple)
    private let ink = Color(red: 0.15, green: 0.14, blue: 0.22)
    private let muted = Color(red: 0.48, green: 0.46, blue: 0.56)
    private var source: CaptureSource? { controller.sources.first { $0.id == sourceID } }
    private var busy: Bool { controller.phase.isCapturing || starting }
    private var visibleRecordings: [LocalRecording] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let filtered = library.recordings.filter { recording in
            (collection != .recent || recording.date >= cutoff) && (search.isEmpty || recording.title.localizedCaseInsensitiveContains(search))
        }
        return filtered.sorted {
            switch sort {
            case .newest: return $0.date > $1.date
            case .oldest: return $0.date < $1.date
            case .title: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.black.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                topbar
                Divider()
                if page == .library { libraryPage } else { recorderPage }
            }
            .background(.white)
        }
        .frame(minWidth: 900, minHeight: 650)
        .foregroundStyle(ink)
        .tint(purple)
        .preferredColorScheme(.light)
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(ink, in: Capsule()).shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.bottom, 22).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showSources) { sourceChooser }
        .sheet(item: $playback) { recording in PlaybackView(recording: recording, onReveal: { library.reveal(recording) }) }
        .alert("Rename video", isPresented: $showRename) {
            TextField("Video title", text: $renameTitle)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { renameRecording() }
        } message: { Text("The file in your Relay folder will be renamed. Its video format stays the same.") }
        .alert("Move this video to Trash?", isPresented: $showTrash) {
            Button("Cancel", role: .cancel) { trashTarget = nil }
            Button("Move to Trash", role: .destructive) { trashRecording() }
        } message: { Text("You can restore the video from Trash in Finder.") }
        .alert("Couldn't complete that", isPresented: Binding(get: { localError != nil || controller.errorMessage != nil || library.errorMessage != nil }, set: { if !$0 { localError = nil; controller.errorMessage = nil; library.errorMessage = nil } })) {
            Button("OK", role: .cancel) { localError = nil; controller.errorMessage = nil; library.errorMessage = nil }
        } message: { Text(localError ?? controller.errorMessage ?? library.errorMessage ?? "Please try again.") }
        .onReceive(NotificationCenter.default.publisher(for: .relayOpenRecorder)) { _ in playback = nil; showSources = false; page = .recorder }
        .onReceive(NotificationCenter.default.publisher(for: .relayRecordingFinished)) { notification in
            library.refresh()
            page = .library
            if let url = notification.object as? URL, let recording = library.recording(for: url) { playback = recording }
            showToast("Saved to your library")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sun.max.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(purple)
                Text("Relay").font(.system(size: 27, weight: .bold, design: .rounded)).tracking(-0.8)
            }.padding(.horizontal, 10).padding(.top, 25).padding(.bottom, 28)
            Button { page = .recorder } label: {
                Label("Record a video", systemImage: "plus").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            .buttonStyle(.plain).foregroundStyle(.white).background(purple, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 24)
            navigationButton("My library", symbol: "folder", selected: page == .library && collection == .all, count: library.recordings.count) { page = .library; collection = .all }
            navigationButton("Recent videos", symbol: "clock", selected: page == .library && collection == .recent) { page = .library; collection = .recent }
            navigationButton("Recording studio", symbol: "video", selected: page == .recorder) { page = .recorder }
            Spacer(minLength: 24)
            Button {
                do { try library.openFolder() } catch { localError = error.localizedDescription }
            } label: {
                Label("Open recordings folder", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(muted).padding(.bottom, 16)
        }
        .padding(.horizontal, 15).frame(width: 220).background(Color(red: 0.985, green: 0.983, blue: 0.995))
    }

    private func navigationButton(_ title: String, symbol: String, selected: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if let count { Text("\(count)").font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 3).background(purple.opacity(0.11), in: RoundedRectangle(cornerRadius: 4)) }
                if title == "Recording studio" && controller.phase.isLive { Circle().fill(.red).frame(width: 6, height: 6) }
            }.padding(.horizontal, 12).padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(selected ? purple : muted)
        .background(selected ? purple.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 4)
    }

    private var topbar: some View {
        HStack(spacing: 10) {
            Text(page == .library ? "My library" : "Recording studio").fontWeight(.medium)
            Spacer()
            if controller.phase.isLive {
                HStack(spacing: 6) { Circle().fill(controller.phase == .paused ? .orange : .red).frame(width: 6, height: 6); Text(recordingTime(controller.elapsed)).monospacedDigit() }
                    .foregroundStyle(muted).padding(.horizontal, 9).padding(.vertical, 5).background(purple.opacity(0.05), in: Capsule())
            }
        }
        .font(.system(size: 11)).padding(.horizontal, 30).frame(height: 62)
    }

    private var libraryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("My library").font(.system(size: 28, weight: .semibold)).tracking(-0.7)
                        Text("Your videos. Your ideas. All in one place.").font(.system(size: 13)).foregroundStyle(muted)
                    }
                    Spacer()
                    Button { library.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(.bordered).controlSize(.regular)
                }
                if showWelcome { welcomeBanner }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 9) {
                        Text(collection == .all ? "All videos" : "Recent videos").font(.system(size: 17, weight: .semibold))
                        Text("\(visibleRecordings.count)").font(.system(size: 11)).foregroundStyle(muted).padding(.horizontal, 7).padding(.vertical, 3).background(purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        Spacer()
                        HStack(spacing: 6) { Image(systemName: "magnifyingglass"); TextField("Search your videos", text: $search).textFieldStyle(.plain) }
                            .font(.system(size: 12)).foregroundStyle(muted).padding(8).frame(width: 210).background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                    }
                    HStack {
                        Picker("Collection", selection: $collection) { ForEach(LibraryCollection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 192)
                        Spacer()
                        Picker("Sort videos", selection: $sort) { ForEach(RecordingSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 145)
                    }
                    Divider()
                    if visibleRecordings.isEmpty { emptyLibrary } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 17)], spacing: 19) {
                            ForEach(visibleRecordings) { recording in recordingCard(recording) }
                        }.padding(.vertical, 5)
                    }
                    Divider()
                    HStack {
                        Label("\(library.recordings.count) video\(library.recordings.count == 1 ? "" : "s") saved in Movies/Relay", systemImage: "lock")
                        Spacer()
                        Text("Made for clear conversations.")
                    }.font(.system(size: 10)).foregroundStyle(muted)
                }
            }.padding(30)
        }
    }

    private var welcomeBanner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Label("GOOD IDEAS DESERVE A VIDEO", systemImage: "sparkle").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(purple.opacity(0.65))
                Text("Show it. Say it. Send it.").font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-0.7)
                Text("Less typing. More understanding. Bring your ideas to life with a quick recording.").font(.system(size: 12)).foregroundStyle(muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                Button { page = .recorder } label: { Label("Record your first video", systemImage: "arrow.right").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent).controlSize(.regular).padding(.top, 4)
            }.frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .bottomLeading) {
                resourceImage("relay-screen-illustration", fallback: "display").scaledToFit().frame(width: 230, height: 160)
                resourceImage("relay-camera-illustration", fallback: "person.crop.circle.fill").scaledToFill().frame(width: 70, height: 70).background(purple.opacity(0.1)).clipShape(Circle()).overlay(Circle().stroke(.white, lineWidth: 3)).offset(x: 2, y: -2)
            }.frame(width: 230, height: 165)
        }
        .padding(24).background(purple.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) { Button { showWelcome = false } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(muted) }.buttonStyle(.plain).padding(12).help("Dismiss welcome banner") }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).stroke(purple.opacity(0.18), lineWidth: 1.5).frame(width: 88, height: 60).rotationEffect(.degrees(-10)).offset(x: -12, y: -5)
                RoundedRectangle(cornerRadius: 8).fill(.white).overlay(RoundedRectangle(cornerRadius: 8).stroke(purple.opacity(0.28), lineWidth: 1.5)).frame(width: 96, height: 68).rotationEffect(.degrees(6))
                Image(systemName: search.isEmpty ? "play.circle.fill" : "magnifyingglass").font(.system(size: 27)).foregroundStyle(purple.opacity(0.35))
            }.frame(height: 90).padding(.bottom, 5)
            Text(search.isEmpty ? (collection == .recent ? "Your next update belongs here" : "Your next great video starts here") : "No videos found")
                .font(.system(size: 18, weight: .semibold)).tracking(-0.4)
            Text(search.isEmpty ? "A walkthrough, a quick hello, a big idea.\nRecord your first video and make yourself understood." : "Try a different title or clear your search.")
                .font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center).lineSpacing(4)
            if search.isEmpty { Button { page = .recorder } label: { Label("Record a video", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 5) }
            else { Button("Clear search") { search = "" }.buttonStyle(.bordered).padding(.top, 5) }
        }.frame(maxWidth: .infinity).padding(.vertical, 31)
    }

    private func recordingCard(_ recording: LocalRecording) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { playback = recording } label: {
                ZStack(alignment: .bottomTrailing) {
                    GeometryReader { geometry in
                        if let image = recording.thumbnail { Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                        else { Rectangle().fill(purple.opacity(0.09)).overlay(Image(systemName: "video").font(.system(size: 31)).foregroundStyle(purple.opacity(0.3))) }
                    }
                    Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.95)).shadow(radius: 3).frame(maxWidth: .infinity, maxHeight: .infinity)
                    if recording.duration > 0 { Text(recordingTime(recording.duration)).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.white).padding(5).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4)).padding(8) }
                }.aspectRatio(16/9, contentMode: .fit).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Play \(recording.title)")
            VStack(alignment: .leading, spacing: 7) {
                Button(recording.title) { playback = recording }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(recording.title)
                HStack(spacing: 6) { Text(recording.date, style: .date); Text("·"); Text(ByteCountFormatter.string(fromByteCount: recording.size, countStyle: .file)) }.font(.system(size: 10)).foregroundStyle(muted)
                Divider().padding(.top, 4)
                HStack {
                    Label("On your Mac", systemImage: "lock").font(.system(size: 10)).foregroundStyle(muted)
                    Spacer()
                    recordingMenu(recording)
                }
            }.padding(13)
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.07)))
        .contextMenu { recordingActions(recording) }
    }

    private func recordingMenu(_ recording: LocalRecording) -> some View {
        Menu { recordingActions(recording) } label: { Image(systemName: "ellipsis").frame(width: 23, height: 20) }
            .menuStyle(.borderlessButton).fixedSize().help("Video actions")
    }

    @ViewBuilder private func recordingActions(_ recording: LocalRecording) -> some View {
        Button("Play video", systemImage: "play") { playback = recording }
        Button("Rename", systemImage: "pencil") { renameTarget = recording; renameTitle = recording.title; showRename = true }
        Button("Show in Finder", systemImage: "folder") { library.reveal(recording) }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { trashTarget = recording; showTrash = true }
    }

    private var recorderPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Record a video").font(.system(size: 28, weight: .semibold)).tracking(-0.7)
                        Text("Your screen. Your face. Your point of view.").font(.system(size: 13)).foregroundStyle(muted)
                    }
                    Spacer()
                    Label("Native resolution", systemImage: "viewfinder").font(.system(size: 11)).foregroundStyle(muted).padding(.vertical, 7).padding(.horizontal, 10).background(purple.opacity(0.06), in: Capsule())
                }
                capturePreview.frame(minHeight: 290, idealHeight: 340, maxHeight: 365)
                HStack(alignment: .top, spacing: 25) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Choose what to record").font(.system(size: 15, weight: .semibold))
                        HStack(spacing: 7) {
                            ForEach(CaptureMode.allCases) { value in
                                Button { mode = value } label: {
                                    VStack(spacing: 8) { Image(systemName: value.symbol).font(.system(size: 18)); Text(value.title).font(.system(size: 10, weight: .medium)).multilineTextAlignment(.center) }
                                        .frame(maxWidth: .infinity).frame(height: 65).contentShape(Rectangle())
                                }.buttonStyle(.plain).foregroundStyle(mode == value ? purple : muted)
                                    .background(mode == value ? purple.opacity(0.08) : .white, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(mode == value ? purple.opacity(0.35) : .black.opacity(0.08)))
                                    .disabled(busy).accessibilityAddTraits(mode == value ? .isSelected : [])
                            }
                        }
                        if mode.usesScreen {
                            Button { chooseSource() } label: {
                                HStack(spacing: 9) { Image(systemName: source?.kind == .window ? "macwindow" : "display"); VStack(alignment: .leading, spacing: 4) { Text(source?.title ?? "Choose what to share").font(.system(size: 12, weight: .medium)).lineLimit(1); Text(source.map { "\($0.pixelWidth) × \($0.pixelHeight) · Full source resolution" } ?? "A display or a single window").font(.system(size: 10)).foregroundStyle(muted) }; Spacer(); Image(systemName: "chevron.down").font(.system(size: 10)) }
                                    .padding(11).contentShape(Rectangle())
                            }.buttonStyle(.plain).background(Color.black.opacity(0.02), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.07))).disabled(busy)
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 15) {
                        Toggle(isOn: $microphone) { Label("Microphone", systemImage: "mic") }.toggleStyle(.switch).controlSize(.small).disabled(busy)
                        Toggle(isOn: $systemAudio) { Label("System audio", systemImage: "speaker.wave.2") }.toggleStyle(.switch).controlSize(.small).disabled(busy || !mode.usesScreen)
                        if mode == .screenAndCamera {
                            HStack { Text("Camera position").foregroundStyle(muted); Spacer(); Button("Left") { setCamera(x: 0.13, y: 0.79) }; Button("Right") { setCamera(x: 0.87, y: 0.79) } }.font(.system(size: 11)).disabled(controller.phase == .preparing || controller.phase == .finishing)
                            Text("Drag the camera in your preview to place it in the saved video.").font(.system(size: 10)).foregroundStyle(muted).lineSpacing(3)
                        }
                        recordActions
                    }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkle").foregroundStyle(purple.opacity(0.7))
                    Text("Float your camera and controls above other windows. The camera in your saved video stays where you place it in the preview.")
                        .foregroundStyle(muted).lineSpacing(3)
                }.font(.system(size: 11))
            }.padding(30)
        }
    }

    private var recordActions: some View {
        VStack(spacing: 9) {
            if controller.phase.isLive {
                HStack(spacing: 8) {
                    Button { controller.phase == .paused ? controller.resume() : controller.pause() } label: { Label(controller.phase == .paused ? "Resume" : "Pause", systemImage: controller.phase == .paused ? "play" : "pause").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
                    Button { controller.setMicrophoneMuted(!controller.microphoneMuted) } label: { Label(controller.microphoneMuted ? "Unmute" : "Mute", systemImage: controller.microphoneMuted ? "mic.slash" : "mic").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large).disabled(!microphone)
                }
                Button { Task { await controller.stop() } } label: { Label("Finish recording", systemImage: "stop.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            } else {
                Button { beginRecording() } label: {
                    HStack { if busy { ProgressView().controlSize(.small) } else { Image(systemName: "record.circle") }; Text(busy ? controller.phase.title : "Start recording") }.frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(busy || (mode.usesScreen && source == nil))
            }
            HStack(spacing: 8) {
                if mode.usesCamera { Button(action: onShowCamera) { Label(controller.phase.isLive ? "Float camera" : "Preview camera", systemImage: "pip").frame(maxWidth: .infinity) }.disabled(controller.phase == .preparing || controller.phase == .finishing) }
                Button(action: onShowLauncher) { Label("Show launcher", systemImage: "arrow.up.left").frame(maxWidth: .infinity) }
            }.buttonStyle(.bordered).controlSize(.regular)
            Text(mode.usesScreen && source == nil ? "Choose a display or window before you record." : "Saved directly to Movies/Relay on your Mac.")
                .font(.system(size: 10)).foregroundStyle(muted).multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
    }

    private var capturePreview: some View {
        GeometryReader { geometry in
            let size = previewOutputSize
            let fitted = aspectFit(size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(purple.opacity(0.055))
                if let image = controller.previewImage, controller.phase.isCapturing {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: geometry.size.width, height: geometry.size.height)
                } else if mode == .camera && controller.cameraReady {
                    CameraPreview(session: controller.cameraSession).frame(width: fitted.width, height: fitted.height).position(x: fitted.midX, y: fitted.midY)
                } else {
                    if mode.usesScreen { resourceImage("relay-screen-illustration", fallback: "display").scaledToFit().frame(width: geometry.size.width * 0.59, height: geometry.size.height * 0.8).position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.46) }
                    if mode == .camera { resourceImage("relay-camera-illustration", fallback: "person.crop.circle.fill").scaledToFill().frame(width: 135, height: 135).background(purple.opacity(0.08)).clipShape(Circle()).overlay(Circle().stroke(.white, lineWidth: 4)).position(x: geometry.size.width / 2, y: geometry.size.height / 2) }
                }
                if mode == .screenAndCamera && (controller.phase.isLive || controller.phase == .idle) { cameraPlacementView(in: fitted) }
                HStack {
                    HStack(spacing: 6) { Circle().fill(controller.phase.isLive ? (controller.phase == .paused ? .orange : .red) : Color.gray.opacity(0.45)).frame(width: 5, height: 5); Text(controller.phase.isLive ? "\(controller.phase.title) · \(recordingTime(controller.elapsed))" : controller.phase.title).monospacedDigit() }
                        .font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 6).background(.white.opacity(0.9), in: Capsule())
                    Spacer()
                    Text(controller.phase.isCapturing ? "\(Int(size.width)) × \(Int(size.height))" : "Native").font(.system(size: 11)).foregroundStyle(muted)
                }.padding(15)
                if controller.phase == .idle {
                    Text("Your preview will appear here").font(.system(size: 10)).foregroundStyle(muted.opacity(0.8)).frame(maxWidth: .infinity).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 15).allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(purple.opacity(0.1)))
            .coordinateSpace(name: "capturePreview")
        }
    }

    private func cameraPlacementView(in rect: CGRect) -> some View {
        let diameter = min(rect.width * 0.18, rect.height * 0.32)
        return ZStack {
            if controller.phase == .idle {
                if controller.cameraReady { CameraPreview(session: controller.cameraSession) }
                else { resourceImage("relay-camera-illustration", fallback: "person.crop.circle.fill").scaledToFill() }
            }
            Circle().stroke(.white.opacity(0.9), lineWidth: 3)
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).padding(7).background(.black.opacity(0.4), in: Circle()).opacity(controller.phase.isLive ? 0.85 : 0)
        }
        .frame(width: diameter, height: diameter).clipShape(Circle())
        .contentShape(Circle()).position(x: rect.minX + rect.width * cameraX, y: rect.minY + rect.height * cameraY)
        .focusable().accessibilityLabel("Move camera in your saved video").accessibilityHint("Drag, or use the arrow keys.")
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("capturePreview")).onChanged { value in
            let radiusX = diameter / (2 * rect.width), radiusY = diameter / (2 * rect.height)
            setCamera(x: min(1 - radiusX, max(radiusX, (value.location.x - rect.minX) / rect.width)),
                      y: min(1 - radiusY, max(radiusY, (value.location.y - rect.minY) / rect.height)))
        })
        .onMoveCommand { direction in
            let step = 0.015
            let radiusX = diameter / (2 * rect.width), radiusY = diameter / (2 * rect.height)
            switch direction {
            case .left: setCamera(x: max(radiusX, cameraX - step), y: cameraY)
            case .right: setCamera(x: min(1 - radiusX, cameraX + step), y: cameraY)
            case .up: setCamera(x: cameraX, y: max(radiusY, cameraY - step))
            case .down: setCamera(x: cameraX, y: min(1 - radiusY, cameraY + step))
            default: break
            }
        }
    }

    private var previewOutputSize: CGSize {
        if controller.phase.isCapturing, controller.outputSize.width > 0, controller.outputSize.height > 0 { return controller.outputSize }
        if let source, source.pixelWidth > 0, source.pixelHeight > 0 { return CGSize(width: source.pixelWidth, height: source.pixelHeight) }
        return CGSize(width: 1920, height: 1080)
    }

    private func aspectFit(_ source: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / max(1, source.width), container.height / max(1, source.height))
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    private var sourceChooser: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading, spacing: 7) { Text("Choose what to share").font(.system(size: 22, weight: .semibold)); Text("Record a display or keep your walkthrough to one window.").font(.system(size: 12)).foregroundStyle(muted) }; Spacer(); Button("Cancel") { showSources = false }.keyboardShortcut(.cancelAction) }
            Divider()
            if loadingSources { VStack(spacing: 12) { ProgressView(); Text("Finding displays and windows…").font(.system(size: 13)).foregroundStyle(muted) }.frame(maxWidth: .infinity, minHeight: 280) }
            else if controller.sources.isEmpty { VStack(spacing: 13) { Image(systemName: "display.trianglebadge.exclamationmark").font(.system(size: 32)).foregroundStyle(muted); Text("No sources available").font(.system(size: 16, weight: .medium)); Text("Allow Screen Recording in System Settings, then try again.").font(.system(size: 12)).foregroundStyle(muted); Button("Try again") { loadSources() } }.frame(maxWidth: .infinity, minHeight: 280) }
            else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(controller.sources) { source in
                            Button { sourceID = source.id; showSources = false } label: {
                                HStack(spacing: 13) { Image(systemName: source.kind == .display ? "display" : "macwindow").font(.system(size: 23)).foregroundStyle(purple).frame(width: 34); VStack(alignment: .leading, spacing: 5) { Text(source.title).font(.system(size: 13, weight: .medium)).lineLimit(2); Text("\(source.pixelWidth) × \(source.pixelHeight) · \(source.kind == .display ? "Display" : "Window")").font(.system(size: 11)).foregroundStyle(muted) }; Spacer(); if source.id == sourceID { Image(systemName: "checkmark.circle.fill").foregroundStyle(purple) } }.padding(13).contentShape(Rectangle())
                            }.buttonStyle(.plain).background(source.id == sourceID ? purple.opacity(0.07) : .black.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(minHeight: 280, maxHeight: 390)
            }
            Label("Your selection stays on this Mac.", systemImage: "lock").font(.system(size: 11)).foregroundStyle(muted)
        }.padding(26).frame(width: 590)
    }

    private func chooseSource() { showSources = true; loadSources() }
    private func loadSources() {
        guard !loadingSources, !busy else { return }
        loadingSources = true
        Task { await controller.loadSources(); loadingSources = false }
    }
    private func beginRecording() {
        guard !busy else { return }
        guard !mode.usesScreen || source != nil else { chooseSource(); return }
        starting = true
        do {
            let url = try library.allocateRecordingURL()
            let options = CaptureOptions(mode: mode, sourceID: sourceID, microphone: microphone, systemAudio: mode.usesScreen && systemAudio, cameraX: cameraX, cameraY: cameraY, cameraSize: 0.18, outputURL: url)
            Task { await controller.start(options: options); starting = false }
        } catch { starting = false; localError = error.localizedDescription }
    }
    private func setCamera(x: Double, y: Double) { cameraX = x; cameraY = y; controller.setCameraPosition(x: x, y: y) }
    private func renameRecording() {
        guard let recording = renameTarget else { return }
        do { try library.rename(recording, to: renameTitle); showToast("Video renamed") } catch { localError = error.localizedDescription }
        renameTarget = nil
    }
    private func trashRecording() {
        guard let recording = trashTarget else { return }
        do { try library.moveToTrash(recording); showToast("Video moved to Trash") } catch { localError = error.localizedDescription }
        trashTarget = nil
    }
    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = message }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if toast == message { withAnimation { toast = nil } } }
    }
    private func resourceImage(_ name: String, fallback: String) -> Image {
        if let image = NSImage(named: name) { return Image(nsImage: image).resizable() }
        return Image(systemName: fallback).resizable()
    }
}

@MainActor
struct PlaybackView: View {
    let recording: LocalRecording
    let onReveal: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(recording: LocalRecording, onReveal: @escaping () -> Void, player: AVPlayer? = nil) {
        self.recording = recording
        self.onReveal = onReveal
        _player = State(initialValue: player ?? AVPlayer(url: recording.url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 7) { Label("My library", systemImage: "folder").font(.system(size: 11)).foregroundStyle(.secondary); Text(recording.title).font(.system(size: 22, weight: .semibold)).lineLimit(2) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            RelayPlayerView(player: player, videoLabel: "Video playback for \(recording.title)").aspectRatio(16/9, contentMode: .fit).frame(minHeight: 330).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Label("Saved on this Mac", systemImage: "lock").foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(recording.date, style: .date).foregroundStyle(.secondary)
                Spacer()
                Button(action: onReveal) { Label("Show in Finder", systemImage: "folder") }.buttonStyle(.bordered)
            }.font(.system(size: 12))
        }.padding(26).frame(minWidth: 740, idealWidth: 900, minHeight: 480).background(.white).preferredColorScheme(.light)
        .onAppear { player.play() }
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
    }
}


/// Keeps playback on AppKit's AVPlayerView, without constructing the
/// AVKit SwiftUI VideoPlayer bridge. The caller owns playback and teardown.
@MainActor
struct RelayPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var videoLabel = "Video playback"

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(frame: .zero)
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        view.player = player
        updateAccessibility(view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        updateAccessibility(view)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }

    private func updateAccessibility(_ view: AVPlayerView) {
        view.setAccessibilityLabel(videoLabel)
        view.setAccessibilityHelp("Use the playback controls to play, pause, and seek through this video.")
    }
}
