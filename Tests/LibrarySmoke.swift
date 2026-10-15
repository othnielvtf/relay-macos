import AppKit
import Foundation

@main struct LibrarySmoke {
    @MainActor static func main() throws {
        let manager = FileManager.default
        let container = manager.temporaryDirectory.appendingPathComponent("relay-library-smoke-\(UUID().uuidString)", isDirectory: true)
        let folder = container.appendingPathComponent("Relay", isDirectory: true)
        defer { try? manager.removeItem(at: container) }
        let library = LibraryStore(directoryURL: folder)
        precondition(!manager.fileExists(atPath: folder.path), "Library init must not create a folder")
        library.refresh()
        precondition(!manager.fileExists(atPath: folder.path), "Refresh must not create a folder")
        let recordingURL = try library.allocateRecordingURL()
        precondition(manager.fileExists(atPath: folder.path) && recordingURL.pathExtension == "mp4")
        try Data("synthetic test bytes".utf8).write(to: recordingURL)
        library.refresh()
        precondition(library.recordings.count == 1)
        let original = library.recordings[0]
        var rejected = false
        do { try library.rename(original, to: "../outside") } catch { rejected = true }
        precondition(rejected && manager.fileExists(atPath: recordingURL.path), "Unsafe rename must be rejected")
        try library.rename(original, to: "A clearer walkthrough")
        let renamed = library.recordings[0]
        precondition(renamed.title == "A clearer walkthrough" && renamed.url.pathExtension == "mp4")
        let occupied = folder.appendingPathComponent("Already used.mp4")
        try Data("keep these bytes".utf8).write(to: occupied)
        rejected = false
        do { try library.rename(renamed, to: "Already used") } catch { rejected = true }
        let retainedBytes = try Data(contentsOf: occupied)
        precondition(rejected && retainedBytes == Data("keep these bytes".utf8), "Rename must not overwrite another video")
        print("Library smoke passed: no startup folder creation, explicit MP4 allocation, scan, safe rename, extension preservation, collision protection. No devices or capture permissions used.")
    }
}
