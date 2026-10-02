import Foundation
import Observation

/// Decides where finished videos are stored.
///
/// iOS apps cannot write anywhere they like. Two options are offered:
///  1. Default – the app's own folder, visible in the Files app as
///     "On My iPhone › YT Downloader › Video".
///  2. A folder the user picks once in the Files picker (for example "Downloads").
///     iOS then gives the app a permanent permission ("bookmark") for that folder,
///     and videos go into a "Video" subfolder inside it.
@Observable
@MainActor
final class StorageManager {

    static let shared = StorageManager()

    nonisolated static let videoSubfolderName = "Video"
    private let bookmarkKey = "destinationFolderBookmark"

    /// Bookmark of the folder the user picked, or nil when the app folder is used.
    private(set) var customFolderBookmark: Data?
    private(set) var customFolderName: String?

    /// Folders we have already unlocked with `startAccessingSecurityScopedResource`, keyed by bookmark.
    @ObservationIgnored private var openedFolders: [Data: URL] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey),
           let url = resolve(bookmark: data) {
            customFolderBookmark = data
            customFolderName = url.lastPathComponent
        }
    }

    // MARK: - Locations

    var locationDescription: String {
        if let customFolderName {
            return "\(customFolderName) › \(Self.videoSubfolderName)"
        }
        return "On My iPhone › YT Downloader › \(Self.videoSubfolderName)"
    }

    /// The app's own Documents/Video folder.
    nonisolated static var appVideoFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent(videoSubfolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Temporary working area for partial downloads (kept so that Retry can resume).
    nonisolated static func workFolder(for id: UUID) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("Work/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    nonisolated static var thumbnailFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The "Video" folder that belongs to a bookmark (nil bookmark = app folder).
    func videoFolder(for bookmark: Data?) -> URL? {
        guard let bookmark else { return Self.appVideoFolder }
        guard let parent = resolve(bookmark: bookmark) else { return nil }
        let folder = parent.appendingPathComponent(Self.videoSubfolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func fileURL(for item: DownloadItem) -> URL? {
        guard let name = item.fileName, let folder = videoFolder(for: item.folderBookmark) else { return nil }
        return folder.appendingPathComponent(name)
    }

    // MARK: - Choosing a folder

    func useCustomFolder(_ url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        customFolderBookmark = bookmark
        customFolderName = url.lastPathComponent
        _ = videoFolder(for: bookmark)   // creates the "Video" subfolder right away
    }

    func useAppFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        customFolderBookmark = nil
        customFolderName = nil
    }

    // MARK: - Bookmarks

    private func resolve(bookmark: Data) -> URL? {
        if let opened = openedFolders[bookmark] { return opened }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        // Access stays open for the life of the app so playback and deleting keep working.
        _ = url.startAccessingSecurityScopedResource()
        openedFolders[bookmark] = url
        return url
    }

    // MARK: - File names

    /// Turns a video title into a safe, unique file name inside `folder`.
    nonisolated static func uniqueFileName(title: String, height: Int, in folder: URL) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters)
        var base = title.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Video" }
        if base.count > 120 { base = String(base.prefix(120)) }
        base += " (\(height)p)"

        var name = base + ".mp4"
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) \(counter).mp4"
            counter += 1
        }
        return name
    }
}
