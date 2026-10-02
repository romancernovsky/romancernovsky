import Foundation

/// One video in the download list / library. Persisted to disk as JSON.
struct DownloadItem: Identifiable, Codable, Hashable {

    enum Status: Codable, Hashable {
        case queued
        case preparing                  // asking YouTube for the stream addresses
        case downloading                // see `progress`
        case merging                    // joining separate video + audio tracks
        case completed
        case failed(message: String)
    }

    let id: UUID
    let videoID: String
    var title: String
    /// Resolution the user asked for.
    let requestedHeight: Int
    /// Resolution actually downloaded (can be lower if the video does not offer the requested one).
    var actualHeight: Int?

    var status: Status = .queued
    /// 0...1 while downloading.
    var progress: Double = 0
    var bytesWritten: Int64 = 0
    var totalBytes: Int64 = 0

    /// Final file name inside the destination folder, e.g. "My video (1080p).mp4".
    var fileName: String?
    /// Security-scoped bookmark of the destination folder, or nil for the app's own "Video" folder.
    var folderBookmark: Data?
    var thumbnailFileName: String?

    let createdAt: Date
    var completedAt: Date?

    init(video: VideoInfo, requestedHeight: Int, folderBookmark: Data?) {
        self.id = UUID()
        self.videoID = video.id
        self.title = video.title
        self.requestedHeight = requestedHeight
        self.folderBookmark = folderBookmark
        self.createdAt = Date()
    }

    var isActive: Bool {
        switch status {
        case .queued, .preparing, .downloading, .merging: return true
        case .completed, .failed: return false
        }
    }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}
