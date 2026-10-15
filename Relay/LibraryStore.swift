import AppKit
import AVFoundation
import Combine
import Foundation

struct LocalRecording: Identifiable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
    var title: String
    let date: Date
    var duration: TimeInterval
    var thumbnail: NSImage?
    let size: Int64
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var recordings: [LocalRecording] = []
    @Published var errorMessage: String?
    let directoryURL: URL

    private let fileManager: FileManager
    private var metadataTask: Task<Void, Never>?
    private var generation = UUID()
    private let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    var directoryExists: Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let movies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        self.directoryURL = (directoryURL ?? movies.appendingPathComponent("Relay", isDirectory: true)).standardizedFileURL
        refresh()
    }

    /// Reading the library never creates a folder or asks for capture permissions.
    func refresh() {
        metadataTask?.cancel()
        generation = UUID()
        guard directoryExists else { recordings = []; return }
        let oldRecords = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
        do {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
            let urls = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            recordings = urls.compactMap { url in
                guard videoExtensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 0 else { return nil }
                let date = values.creationDate ?? values.contentModificationDate ?? .distantPast
                let previous = oldRecords[url.standardizedFileURL.path]
                return LocalRecording(url: url, title: url.deletingPathExtension().lastPathComponent,
                                      date: date, duration: previous?.size == Int64(size) ? previous?.duration ?? 0 : 0,
                                      thumbnail: previous?.size == Int64(size) ? previous?.thumbnail : nil, size: Int64(size))
            }.sorted { $0.date > $1.date }
            errorMessage = nil
            loadMetadata(for: recordings, generation: generation)
        } catch {
            errorMessage = "Relay couldn't read your recordings folder. \(error.localizedDescription)"
        }
    }

    /// Called only in response to an explicit recording action.
    func allocateRecordingURL() throws -> URL {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Recording \(formatter.string(from: Date())) \(UUID().uuidString.prefix(4).lowercased()).mp4"
        return directoryURL.appendingPathComponent(name)
    }

    func recording(for url: URL) -> LocalRecording? {
        recordings.first { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    func reveal(_ recording: LocalRecording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
    }

    func openFolder() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard NSWorkspace.shared.open(directoryURL) else { throw LibraryError("Relay couldn't open the recordings folder in Finder.") }
    }

    func rename(_ recording: LocalRecording, to proposedTitle: String) throws {
        try validateLocation(recording.url)
        var title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = recording.url.pathExtension
        if title.lowercased().hasSuffix(".\(ext.lowercased())") { title = String(title.dropLast(ext.count + 1)) }
        let invalid = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        guard !title.isEmpty, !title.hasPrefix("."), title.rangeOfCharacter(from: invalid) == nil,
              title.utf8.count + ext.utf8.count + 1 <= 240 else {
            throw LibraryError("Use a short title without slashes, colons, or a leading dot.")
        }
        let destination = directoryURL.appendingPathComponent(title).appendingPathExtension(ext)
        guard destination != recording.url else { return }
        guard !fileManager.fileExists(atPath: destination.path) else { throw LibraryError("A video with that title already exists. Try another name.") }
        try fileManager.moveItem(at: recording.url, to: destination)
        refresh()
    }

    /// Uses macOS Trash so deleting a video remains recoverable in Finder.
    func moveToTrash(_ recording: LocalRecording) throws {
        try validateLocation(recording.url)
        var trashedURL: NSURL?
        try fileManager.trashItem(at: recording.url, resultingItemURL: &trashedURL)
        refresh()
    }

    private func validateLocation(_ url: URL) throws {
        guard url.standardizedFileURL.deletingLastPathComponent() == directoryURL,
              videoExtensions.contains(url.pathExtension.lowercased()),
              fileManager.fileExists(atPath: url.path) else {
            throw LibraryError("This video is no longer in your Relay folder. Refresh your library and try again.")
        }
    }

    private func loadMetadata(for snapshot: [LocalRecording], generation expectedGeneration: UUID) {
        metadataTask = Task { [weak self] in
            for recording in snapshot where recording.thumbnail == nil || recording.duration == 0 {
                guard !Task.isCancelled else { return }
                let asset = AVURLAsset(url: recording.url)
                let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
                guard !Task.isCancelled else { return }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 360)
                let moment = CMTime(seconds: duration.isFinite ? min(1, max(0, duration / 3)) : 0, preferredTimescale: 600)
                let image = try? await generator.image(at: moment).image
                guard !Task.isCancelled, let self, self.generation == expectedGeneration,
                      let index = self.recordings.firstIndex(where: { $0.id == recording.id }) else { return }
                self.recordings[index].duration = duration.isFinite ? max(0, duration) : 0
                if let image {
                    self.recordings[index].thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                }
            }
        }
    }
}

private struct LibraryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
